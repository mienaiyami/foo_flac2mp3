<#
  FLAC -> MP3 converter (WinForms UI, no installs needed).
  Uses flac.exe and lame.exe from PATH. Copies every Vorbis comment and embedded
  picture into an ID3v2.4 tag, using foobar2000's Vorbis -> ID3 field mapping.

  GUI:  FlacToMp3.ps1 [-MainDir <dir>]
  CLI:  FlacToMp3.ps1 -NoGui -MainDir <dir> -Files "a.flac|b.flac" -Delimiter "|" [-Quality CBR320|V0|V1|V2]
                      [-NoOverwrite] [-DeleteFlac] [-UpdatePlaylists]
#>
param(
    [string]$MainDir,
    [switch]$NoGui,
    [string]$Files,
    [string]$Delimiter = '\n',
    [ValidateSet('CBR320', 'V0', 'V1', 'V2')][string]$Quality = 'CBR320',
    [switch]$NoOverwrite,
    [switch]$DeleteFlac,
    [switch]$UpdatePlaylists
)

$ErrorActionPreference = 'Stop'

# The GUI is launched with a hidden console, so surface fatal errors in a dialog.
trap {
    if (-not $NoGui) {
        Add-Type -AssemblyName System.Windows.Forms
        [void][Windows.Forms.MessageBox]::Show("$($_.Exception.Message)`n`n$($_.InvocationInfo.PositionMessage)", 'FLAC to MP3 - error', 'OK', 'Error')
    }
    break
}

if (-not $MainDir) { $MainDir = (Get-Location).ProviderPath }
$MainDir = [IO.Path]::GetFullPath($MainDir).TrimEnd('\')
if ($MainDir.Length -eq 2) { $MainDir += '\' }   # "G:" -> "G:\"

$QualityArgs = [ordered]@{ 'CBR320' = '-b 320'; 'V0' = '-V 0'; 'V1' = '-V 1'; 'V2' = '-V 2' }

function Find-Tool([string]$name) {
    $c = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { $c.Source } else { $null }
}

# True if $path is $root itself or lies below it.
function Test-UnderDir([string]$path, [string]$root) {
    $r = $root.TrimEnd('\') + '\'
    $path.StartsWith($r, [StringComparison]::OrdinalIgnoreCase)
}

# Turns "\n", "\t", "\r" typed in the delimiter box into real characters.
function ConvertFrom-Delimiter([string]$d) {
    if ([string]::IsNullOrEmpty($d)) { return "`n" }
    $d = $d.Replace('\r\n', "`n").Replace('\n', "`n").Replace('\t', "`t").Replace('\r', "`n")
    $d
}

# Splits pasted text into FLAC paths confined to the main folder.
function Resolve-InputList([string]$text, [string]$delimiter, [string]$root) {
    $valid = New-Object System.Collections.Generic.List[string]
    $rejected = New-Object System.Collections.Generic.List[string]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $d = ConvertFrom-Delimiter $delimiter
    $text = $text.Replace("`r`n", "`n").Replace("`r", "`n")
    foreach ($raw in $text.Split([string[]]@($d), [StringSplitOptions]::None)) {
        $p = $raw.Trim().Trim('"').Trim()
        if (-not $p) { continue }
        try {
            if (-not [IO.Path]::IsPathRooted($p)) { $p = [IO.Path]::Combine($root, $p) }
            $full = [IO.Path]::GetFullPath($p)
        } catch { $rejected.Add("SKIP  invalid path: $raw"); continue }
        if (-not (Test-UnderDir $full $root)) { $rejected.Add("SKIP  outside main folder: $full"); continue }
        if ([IO.Path]::GetExtension($full) -ne '.flac') { $rejected.Add("SKIP  not a .flac file: $full"); continue }
        if (-not [IO.File]::Exists($full)) { $rejected.Add("SKIP  file not found: $full"); continue }
        if ($seen.Add($full)) { $valid.Add($full) }
    }
    @{ Valid = $valid; Rejected = $rejected }
}

# ---------------------------------------------------------------------------
# Worker: runs in a background runspace (GUI) or inline (CLI). Self-contained.
# ---------------------------------------------------------------------------
$Worker = {
    param($Sync, $Opt)
    $ErrorActionPreference = 'Stop'
    Add-Type -AssemblyName Microsoft.VisualBasic

    $utf8 = New-Object Text.UTF8Encoding $false
    $latin1 = [Text.Encoding]::GetEncoding(28591)

    function Log([string]$m) {
        $Sync.Log.Enqueue($m)
        if ($Sync.Echo) { [Console]::Out.WriteLine($m) }
    }
    function Rel([string]$p) {
        $r = $Opt.MainDir.TrimEnd('\') + '\'
        if ($p.StartsWith($r, [StringComparison]::OrdinalIgnoreCase)) { $p.Substring($r.Length) } else { $p }
    }

    # ---- FLAC metadata reader ------------------------------------------------
    function ReadBE32([byte[]]$b, [int]$o) {
        ([uint32]$b[$o] -shl 24) -bor ([uint32]$b[$o + 1] -shl 16) -bor ([uint32]$b[$o + 2] -shl 8) -bor [uint32]$b[$o + 3]
    }

    # Returns @{ Tags = OrderedDictionary(name -> @{Name;Values}); Pictures = list }
    function Read-FlacMeta([string]$path) {
        $tags = New-Object System.Collections.Specialized.OrderedDictionary ([StringComparer]::OrdinalIgnoreCase)
        $pics = New-Object System.Collections.Generic.List[object]
        $fs = [IO.File]::OpenRead($path)
        try {
            $br = New-Object IO.BinaryReader $fs
            $h = $br.ReadBytes(10)
            if ($latin1.GetString($h, 0, 3) -eq 'ID3') {
                # Some rippers prepend an ID3v2 tag to FLAC; skip it.
                $size = ([int]$h[6] -shl 21) -bor ([int]$h[7] -shl 14) -bor ([int]$h[8] -shl 7) -bor [int]$h[9]
                $skip = 10 + $size; if ($h[5] -band 0x10) { $skip += 10 }
                [void]$fs.Seek($skip, 'Begin')
            } else { [void]$fs.Seek(0, 'Begin') }
            if ($latin1.GetString($br.ReadBytes(4)) -ne 'fLaC') { throw 'not a FLAC file' }

            do {
                $bh = $br.ReadBytes(4)
                $last = ($bh[0] -band 0x80) -ne 0
                $type = $bh[0] -band 0x7F
                $len = ([int]$bh[1] -shl 16) -bor ([int]$bh[2] -shl 8) -bor [int]$bh[3]
                if ($type -eq 4) {
                    $d = $br.ReadBytes($len)
                    $o = 4 + [BitConverter]::ToUInt32($d, 0)          # skip vendor string
                    $n = [BitConverter]::ToUInt32($d, $o); $o += 4
                    for ($i = 0; $i -lt $n; $i++) {
                        $l = [int][BitConverter]::ToUInt32($d, $o); $o += 4
                        $kv = $utf8.GetString($d, $o, $l); $o += $l
                        $eq = $kv.IndexOf('=')
                        if ($eq -lt 1) { continue }
                        $k = $kv.Substring(0, $eq); $v = $kv.Substring($eq + 1)
                        if (-not $tags.Contains($k)) { $tags[$k] = @{ Name = $k; Values = (New-Object System.Collections.Generic.List[string]) } }
                        $tags[$k].Values.Add($v)
                    }
                } elseif ($type -eq 6) {
                    $d = $br.ReadBytes($len)
                    $o = 0
                    $ptype = ReadBE32 $d $o; $o += 4
                    $ml = [int](ReadBE32 $d $o); $o += 4
                    $mime = $latin1.GetString($d, $o, $ml); $o += $ml
                    $dl = [int](ReadBE32 $d $o); $o += 4
                    $desc = $utf8.GetString($d, $o, $dl); $o += $dl
                    $o += 16                                            # width, height, depth, colors
                    $pl = [int](ReadBE32 $d $o); $o += 4
                    $data = New-Object byte[] $pl
                    [Array]::Copy($d, $o, $data, 0, $pl)
                    $pics.Add(@{ Type = [byte]$ptype; Mime = $mime; Desc = $desc; Data = $data })
                } else {
                    [void]$fs.Seek($len, 'Current')
                }
            } while (-not $last)
        } finally { $fs.Dispose() }
        @{ Tags = $tags; Pictures = $pics }
    }

    # ---- ID3v2.4 writer --------------------------------------------------------
    # Vorbis field -> ID3v2.4 text frame, following foobar2000's mapping.
    $TextMap = @{
        'TITLE' = 'TIT2'; 'ARTIST' = 'TPE1'; 'ALBUM' = 'TALB'; 'ALBUM ARTIST' = 'TPE2'; 'ALBUMARTIST' = 'TPE2'
        'DATE' = 'TDRC'; 'GENRE' = 'TCON'; 'COMPOSER' = 'TCOM'; 'CONDUCTOR' = 'TPE3'; 'REMIXER' = 'TPE4'
        'LYRICIST' = 'TEXT'; 'ORIGINAL ARTIST' = 'TOPE'; 'ORIGINALARTIST' = 'TOPE'
        'ORIGINAL ALBUM' = 'TOAL'; 'ORIGINALALBUM' = 'TOAL'
        'ORIGINAL RELEASE DATE' = 'TDOR'; 'ORIGINALDATE' = 'TDOR'
        'PUBLISHER' = 'TPUB'; 'COPYRIGHT' = 'TCOP'; 'ISRC' = 'TSRC'; 'BPM' = 'TBPM'
        'KEY' = 'TKEY'; 'INITIALKEY' = 'TKEY'; 'MOOD' = 'TMOO'; 'SUBTITLE' = 'TIT3'
        'CONTENT GROUP' = 'TIT1'; 'GROUPING' = 'TIT1'; 'MEDIA' = 'TMED'; 'LANGUAGE' = 'TLAN'
        'ENCODED BY' = 'TENC'; 'ENCODEDBY' = 'TENC'
        'ALBUMSORTORDER' = 'TSOA'; 'ALBUMSORT' = 'TSOA'; 'ARTISTSORTORDER' = 'TSOP'; 'ARTISTSORT' = 'TSOP'
        'TITLESORTORDER' = 'TSOT'; 'TITLESORT' = 'TSOT'; 'ALBUMARTISTSORTORDER' = 'TSO2'; 'ALBUMARTISTSORT' = 'TSO2'
    }
    # Vorbis field -> TXXX description that foobar2000 / Picard read back under the same field name.
    $TxxxMap = @{
        'MUSICBRAINZ_ALBUMID' = 'MusicBrainz Album Id'; 'MUSICBRAINZ_ARTISTID' = 'MusicBrainz Artist Id'
        'MUSICBRAINZ_ALBUMARTISTID' = 'MusicBrainz Album Artist Id'; 'MUSICBRAINZ_RELEASEGROUPID' = 'MusicBrainz Release Group Id'
        'MUSICBRAINZ_RELEASETRACKID' = 'MusicBrainz Release Track Id'; 'MUSICBRAINZ_WORKID' = 'MusicBrainz Work Id'
        'MUSICBRAINZ_DISCID' = 'MusicBrainz Disc Id'; 'MUSICBRAINZ_TRMID' = 'MusicBrainz TRM Id'
        'MUSICBRAINZ_ALBUMTYPE' = 'MusicBrainz Album Type'; 'RELEASETYPE' = 'MusicBrainz Album Type'
        'MUSICBRAINZ_ALBUMSTATUS' = 'MusicBrainz Album Status'; 'RELEASESTATUS' = 'MusicBrainz Album Status'
        'RELEASECOUNTRY' = 'MusicBrainz Album Release Country'
        'ACOUSTID_ID' = 'Acoustid Id'; 'ACOUSTID_FINGERPRINT' = 'Acoustid Fingerprint'; 'MUSICIP_PUID' = 'MusicIP PUID'
    }

    function W([IO.MemoryStream]$ms, [byte[]]$b) { $ms.Write($b, 0, $b.Length) }
    function SyncSafe([int]$n) { [byte[]]@((($n -shr 21) -band 0x7F), (($n -shr 14) -band 0x7F), (($n -shr 7) -band 0x7F), ($n -band 0x7F)) }

    function Frame([string]$id, [IO.MemoryStream]$body) {
        $ms = New-Object IO.MemoryStream
        W $ms $latin1.GetBytes($id); W $ms (SyncSafe ([int]$body.Length)); W $ms ([byte[]](0, 0))
        $body.WriteTo($ms)
        , $ms.ToArray()
    }
    function TextFrame([string]$id, $values) {
        $b = New-Object IO.MemoryStream; $b.WriteByte(3)
        W $b $utf8.GetBytes(($values -join [char]0))          # v2.4 multi-value = NUL separated
        Frame $id $b
    }
    function TxxxFrame([string]$desc, $values) {
        $b = New-Object IO.MemoryStream; $b.WriteByte(3)
        W $b $utf8.GetBytes($desc); $b.WriteByte(0)
        W $b $utf8.GetBytes(($values -join [char]0))
        Frame 'TXXX' $b
    }
    function LangFrame([string]$id, [string]$text) {             # COMM / USLT
        $b = New-Object IO.MemoryStream; $b.WriteByte(3)
        W $b $latin1.GetBytes('eng'); $b.WriteByte(0)             # empty description
        W $b $utf8.GetBytes($text)
        Frame $id $b
    }
    function UfidFrame([string]$owner, [string]$id) {
        $b = New-Object IO.MemoryStream
        W $b $latin1.GetBytes($owner); $b.WriteByte(0); W $b $latin1.GetBytes($id)
        Frame 'UFID' $b
    }
    function ApicFrame($pic) {
        $b = New-Object IO.MemoryStream; $b.WriteByte(3)
        $mime = $pic.Mime; if (-not $mime) { $mime = 'image/jpeg' }
        W $b $latin1.GetBytes($mime); $b.WriteByte(0)
        $b.WriteByte($pic.Type)
        W $b $utf8.GetBytes($pic.Desc); $b.WriteByte(0)
        W $b $pic.Data
        Frame 'APIC' $b
    }

    # Builds the full ID3v2.4 tag; returns @{ Bytes; Fields }.
    function Build-Id3($meta) {
        $tags = $meta.Tags
        $frames = New-Object System.Collections.Generic.List[byte[]]
        $done = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        $usedIds = New-Object 'System.Collections.Generic.HashSet[string]'
        function First([string[]]$names) { foreach ($n in $names) { if ($tags.Contains($n)) { return $n } } $null }

        # TRCK / TPOS: number plus optional total, as "n/N".
        foreach ($pair in @(@('TRCK', 'TRACKNUMBER', @('TOTALTRACKS', 'TRACKTOTAL')), @('TPOS', 'DISCNUMBER', @('TOTALDISCS', 'DISCTOTAL')))) {
            $numKey = First @($pair[1])
            if (-not $numKey) { continue }
            $v = $tags[$numKey].Values[0]
            $totKey = First $pair[2]
            if ($totKey -and $v -notmatch '/') { $v = "$v/$($tags[$totKey].Values[0])"; [void]$done.Add($totKey) }
            $frames.Add((TextFrame $pair[0] @($v))); [void]$done.Add($numKey); [void]$usedIds.Add($pair[0])
        }
        $k = First @('COMMENT')
        if ($k) { $frames.Add((LangFrame 'COMM' ($tags[$k].Values -join "`r`n"))); [void]$done.Add($k) }
        $k = First @('LYRICS', 'UNSYNCEDLYRICS', 'UNSYNCED LYRICS')
        if ($k) { $frames.Add((LangFrame 'USLT' ($tags[$k].Values -join "`r`n"))); [void]$done.Add($k) }
        $k = First @('MUSICBRAINZ_TRACKID')
        if ($k) { $frames.Add((UfidFrame 'http://musicbrainz.org' $tags[$k].Values[0])); [void]$done.Add($k) }

        foreach ($key in @($tags.Keys)) {
            if ($done.Contains($key)) { continue }
            $t = $tags[$key]
            $id = $TextMap[$key]
            if ($id -and $usedIds.Add($id)) { $frames.Add((TextFrame $id $t.Values)) }
            elseif ($TxxxMap.ContainsKey($key)) { $frames.Add((TxxxFrame $TxxxMap[$key] $t.Values)) }
            else { $frames.Add((TxxxFrame $t.Name $t.Values)) }     # anything else keeps its own name
        }
        foreach ($p in $meta.Pictures) { $frames.Add((ApicFrame $p)) }

        $padding = 1024
        $size = $padding; foreach ($f in $frames) { $size += $f.Length }
        $ms = New-Object IO.MemoryStream
        W $ms ([byte[]](0x49, 0x44, 0x33, 4, 0, 0)); W $ms (SyncSafe $size)
        foreach ($f in $frames) { W $ms $f }
        W $ms (New-Object byte[] $padding)
        @{ Bytes = $ms.ToArray(); Fields = $tags.Count }
    }

    # ---- helpers -----------------------------------------------------------------
    function Run([string]$exe, [string]$arguments) {
        $psi = New-Object Diagnostics.ProcessStartInfo $exe, $arguments
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
        $psi.RedirectStandardError = $true; $psi.RedirectStandardOutput = $true
        $p = [Diagnostics.Process]::Start($psi)
        $err = $p.StandardError.ReadToEndAsync(); $out = $p.StandardOutput.ReadToEndAsync()
        $p.WaitForExit()
        if ($p.ExitCode -ne 0) {
            $msg = ($err.Result + $out.Result).Trim() -split "`r?`n" | Select-Object -Last 3
            throw "$([IO.Path]::GetFileName($exe)) failed (exit $($p.ExitCode)): $($msg -join ' | ')"
        }
    }

    # Opens for writing without CREATE_ALWAYS, which fails on hidden/system files.
    function Write-AllBytes([string]$path, [byte[]]$bytes) {
        $fs = New-Object IO.FileStream $path, 'OpenOrCreate', 'Write', 'None'
        try { $fs.SetLength(0); $fs.Write($bytes, 0, $bytes.Length) } finally { $fs.Dispose() }
    }

    # Writes tag + LAME audio (minus any tag LAME may have written) to $dest.
    function Write-TaggedMp3([string]$lameOut, [byte[]]$tag, [string]$dest) {
        $in = [IO.File]::OpenRead($lameOut)
        try {
            $start = 0L; $end = $in.Length
            $h = New-Object byte[] 10; [void]$in.Read($h, 0, 10)
            if ($latin1.GetString($h, 0, 3) -eq 'ID3') {
                $start = 10 + (([int]$h[6] -shl 21) -bor ([int]$h[7] -shl 14) -bor ([int]$h[8] -shl 7) -bor [int]$h[9])
            }
            [void]$in.Seek($start, 'Begin')
            $sync = New-Object byte[] 2; [void]$in.Read($sync, 0, 2)
            if ($sync[0] -ne 0xFF -or ($sync[1] -band 0xE0) -ne 0xE0) { throw 'LAME output has no MPEG frame header' }
            [void]$in.Seek($start, 'Begin')
            $out = New-Object IO.FileStream $dest, 'Create', 'Write', 'None'
            try {
                $out.Write($tag, 0, $tag.Length)
                $buf = New-Object byte[] 1048576
                $left = $end - $start
                while ($left -gt 0) {
                    $n = $in.Read($buf, 0, [int][Math]::Min($buf.Length, $left))
                    if ($n -le 0) { break }
                    $out.Write($buf, 0, $n); $left -= $n
                }
            } finally { $out.Dispose() }
        } finally { $in.Dispose() }
    }

    # ---- playlist update ---------------------------------------------------------
    function Get-Playlists([string]$dir) {
        foreach ($f in [IO.Directory]::GetFiles($dir)) {
            $e = [IO.Path]::GetExtension($f).ToLowerInvariant()
            if ($e -eq '.m3u' -or $e -eq '.m3u8') { $f }
        }
        foreach ($d in [IO.Directory]::GetDirectories($dir)) {
            if ([IO.Path]::GetFileName($d).StartsWith('.')) { continue }   # hidden dot-folders (tool/versioning data)
            try { Get-Playlists $d } catch { }
        }
    }

    function Update-Playlists([string]$root, $converted) {
        foreach ($pl in Get-Playlists $root) {
            try {
                $bytes = [IO.File]::ReadAllBytes($pl)
                $bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
                $enc = $null; $text = $null
                if ($bom) { $enc = $utf8; $text = $utf8.GetString($bytes, 3, $bytes.Length - 3) }
                else {
                    try { $text = (New-Object Text.UTF8Encoding $false, $true).GetString($bytes); $enc = $utf8 }
                    catch { $enc = [Text.Encoding]::Default; $text = $enc.GetString($bytes) }
                }
                $plDir = [IO.Path]::GetDirectoryName($pl)
                $parts = [regex]::Split($text, '(\r\n|\n|\r)')          # odd indexes keep the line breaks
                $changed = 0
                for ($i = 0; $i -lt $parts.Length; $i += 2) {
                    $line = $parts[$i]; $entry = $line.Trim()
                    if (-not $entry -or $entry.StartsWith('#')) { continue }
                    if ($entry -notmatch '\.flac$') { continue }
                    try {
                        $p = $entry
                        if ($p -match '^file:') { $p = ([Uri]$p).LocalPath }
                        if (-not [IO.Path]::IsPathRooted($p)) { $p = [IO.Path]::Combine($plDir, $p) }
                        $full = [IO.Path]::GetFullPath($p)
                    } catch { continue }
                    if ($converted.Contains($full)) {
                        $parts[$i] = [regex]::Replace($line, '\.flac(\s*)$', '.mp3$1', 'IgnoreCase'); $changed++
                    }
                }
                if ($changed -gt 0) {
                    [IO.File]::Copy($pl, "$pl.bak", $true)
                    $out = $enc.GetBytes(($parts -join ''))
                    if ($bom) { $out = [byte[]](0xEF, 0xBB, 0xBF) + $out }
                    Write-AllBytes $pl ([byte[]]$out)
                    Log ("LIST  {0}: {1} entr{2} updated (backup: {3}.bak)" -f (Rel $pl), $changed, $(if ($changed -eq 1) { 'y' } else { 'ies' }), [IO.Path]::GetFileName($pl))
                }
            } catch { Log "FAIL  playlist $(Rel $pl): $($_.Exception.Message)" }
        }
    }

    # ---- main loop -----------------------------------------------------------------
    $deleted = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $ok = 0; $skip = 0; $fail = 0
    try {
        Log ("Start: {0} file(s), quality {1}, overwrite={2}, delete FLAC={3}, update playlists={4}" -f `
                $Opt.Files.Count, $Opt.Quality, $Opt.Overwrite, $Opt.DeleteFlac, $Opt.UpdatePlaylists)
        foreach ($flac in $Opt.Files) {
            if ($Sync.Cancel) { Log 'Cancelled.'; break }
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $dest = [IO.Path]::ChangeExtension($flac, '.mp3')
            $tmpBase = [IO.Path]::Combine([IO.Path]::GetTempPath(), 'flac2mp3_' + [guid]::NewGuid().ToString('N'))
            $wav = "$tmpBase.wav"; $lameOut = "$tmpBase.mp3"; $destTmp = "$dest.tmp"
            try {
                if ([IO.File]::Exists($dest) -and -not $Opt.Overwrite) { Log "SKIP  $(Rel $dest) already exists"; $skip++; continue }
                $meta = Read-FlacMeta $flac
                Run $Opt.Flac "--decode --silent --force -o `"$wav`" `"$flac`""
                Run $Opt.Lame "-S --noreplaygain $($Opt.LameArgs) `"$wav`" `"$lameOut`""
                $tag = Build-Id3 $meta
                Write-TaggedMp3 $lameOut $tag.Bytes $destTmp
                if ([IO.File]::Exists($dest)) { [IO.File]::Delete($dest) }
                [IO.File]::Move($destTmp, $dest)
                [IO.File]::SetLastWriteTime($dest, [IO.File]::GetLastWriteTime($flac))
                $note = ''
                if ($Opt.DeleteFlac) {
                    [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($flac, 'OnlyErrorDialogs', 'SendToRecycleBin')
                    [void]$deleted.Add($flac); $note = ', FLAC -> Recycle Bin'
                }
                $ok++
                Log ("OK    {0} -> .mp3  [{1}, {2} fields, {3} picture(s), {4:0.0}s{5}]" -f (Rel $flac), $Opt.Quality, $tag.Fields, $meta.Pictures.Count, $sw.Elapsed.TotalSeconds, $note)
            } catch {
                $fail++
                Log "FAIL  $(Rel $flac): $($_.Exception.Message)"
                if ([IO.File]::Exists($destTmp)) { [IO.File]::Delete($destTmp) }
            } finally {
                foreach ($t in @($wav, $lameOut)) { if ([IO.File]::Exists($t)) { [IO.File]::Delete($t) } }
                $Sync.Done++
            }
        }
        if ($Opt.UpdatePlaylists -and $deleted.Count -gt 0) {
            Log 'Updating playlists...'
            Update-Playlists $Opt.MainDir $deleted
        }
        Log "Done: $ok converted, $skip skipped, $fail failed."
    } catch {
        Log "ERROR $($_.Exception.Message)"
    } finally {
        $Sync.Failed = $fail
        $Sync.Finished = $true
    }
}

function New-Sync([int]$total, [bool]$echo) {
    [hashtable]::Synchronized(@{
            Log = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
            Total = $total; Done = 0; Cancel = $false; Finished = $false; Failed = 0; Echo = $echo
        })
}

function New-Options($files, [string]$quality, [bool]$overwrite, [bool]$delete, [bool]$playlists, [string]$flac, [string]$lame) {
    @{
        Files = [string[]]@($files); Quality = $quality; LameArgs = $QualityArgs[$quality]
        Overwrite = $overwrite; DeleteFlac = $delete; UpdatePlaylists = ($delete -and $playlists)
        MainDir = $MainDir; Flac = $flac; Lame = $lame
    }
}

$FlacExe = Find-Tool 'flac.exe'
$LameExe = Find-Tool 'lame.exe'

# ---------------------------------------------------------------------------
# CLI mode
# ---------------------------------------------------------------------------
if ($NoGui) {
    if (-not $FlacExe -or -not $LameExe) { throw 'flac.exe and lame.exe must be on PATH.' }
    $r = Resolve-InputList $Files $Delimiter $MainDir
    $r.Rejected | ForEach-Object { Write-Host $_ }
    $sync = New-Sync $r.Valid.Count $true
    & $Worker $sync (New-Options $r.Valid $Quality (-not $NoOverwrite) $DeleteFlac.IsPresent $UpdatePlaylists.IsPresent $FlacExe $LameExe)
    exit $(if ($sync.Failed -gt 0) { 1 } else { 0 })
}

# ---------------------------------------------------------------------------
# GUI
# ---------------------------------------------------------------------------
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

function New-Ctl([string]$type, [hashtable]$props) {
    $c = New-Object "System.Windows.Forms.$type"
    foreach ($k in $props.Keys) { $c.$k = $props[$k] }
    $c
}
function New-Flow([bool]$topDown = $false) {
    New-Ctl FlowLayoutPanel @{ AutoSize = $true; Dock = 'Fill'; WrapContents = $false; Margin = '0,0,0,0'
        FlowDirection = $(if ($topDown) { 'TopDown' } else { 'LeftToRight' }) }
}
function New-Label([string]$text) { New-Ctl Label @{ Text = $text; AutoSize = $true; Margin = '3,7,3,3' } }

$form = New-Ctl Form @{
    Text = 'FLAC to MP3'; StartPosition = 'CenterScreen'; AutoScaleMode = 'Dpi'
    Font = New-Object Drawing.Font('Segoe UI', 9); ClientSize = New-Object Drawing.Size(860, 720)
    MinimumSize = New-Object Drawing.Size(640, 560)
}

$root = New-Ctl TableLayoutPanel @{ Dock = 'Fill'; ColumnCount = 1; Padding = '10,10,10,10' }
[void]$root.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 100)))
function Add-Row($ctl, [string]$sizeType = 'AutoSize', [float]$value = 0) {
    [void]$root.RowStyles.Add((New-Object Windows.Forms.RowStyle($sizeType, $value)))
    $root.Controls.Add($ctl, 0, $root.RowStyles.Count - 1)
}

# Main folder row
$rowMain = New-Ctl TableLayoutPanel @{ AutoSize = $true; Dock = 'Fill'; ColumnCount = 3; Margin = '0,0,0,6' }
[void]$rowMain.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('AutoSize')))
[void]$rowMain.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 100)))
[void]$rowMain.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('AutoSize')))
$txtMain = New-Ctl TextBox @{ Text = $MainDir; Dock = 'Fill'; Margin = '3,4,3,3' }
$btnMain = New-Ctl Button @{ Text = 'Browse...'; AutoSize = $true }
$rowMain.Controls.Add((New-Label 'Main folder:'), 0, 0); $rowMain.Controls.Add($txtMain, 1, 0); $rowMain.Controls.Add($btnMain, 2, 0)
Add-Row $rowMain

Add-Row (New-Ctl Label @{ AutoSize = $true; Margin = '3,6,3,3'
        Text = 'FLAC files - paste paths (absolute, or relative to the main folder) and/or use the buttons. Only files inside the main folder are used.' })

# Input box + picker buttons
$rowIn = New-Ctl TableLayoutPanel @{ Dock = 'Fill'; ColumnCount = 2; Margin = '0,0,0,0' }
[void]$rowIn.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 100)))
[void]$rowIn.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('AutoSize')))
[void]$rowIn.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent', 100)))
$txtIn = New-Ctl TextBox @{ Multiline = $true; ScrollBars = 'Both'; WordWrap = $false; Dock = 'Fill'; AcceptsReturn = $true
    Font = New-Object Drawing.Font('Consolas', 9) }
$pickers = New-Flow $true
$btnFiles = New-Ctl Button @{ Text = 'Add files...'; Width = 110 }
$btnFolder = New-Ctl Button @{ Text = 'Add folder...'; Width = 110 }
$btnClear = New-Ctl Button @{ Text = 'Clear'; Width = 110 }
$pickers.Controls.AddRange(@($btnFiles, $btnFolder, $btnClear))
$rowIn.Controls.Add($txtIn, 0, 0); $rowIn.Controls.Add($pickers, 1, 0)
Add-Row $rowIn 'Percent' 40

# Delimiter
$rowDelim = New-Flow
$txtDelim = New-Ctl TextBox @{ Text = '\n'; Width = 60; Margin = '3,4,3,3' }
$rowDelim.Controls.AddRange(@((New-Label 'Delimiter:'), $txtDelim,
        (New-Label 'default \n (new line); any text works, e.g.  ;  |  ,  \t')))
Add-Row $rowDelim

# Quality
$rowQ = New-Flow
$rowQ.Controls.Add((New-Label 'Quality:'))
$radios = [ordered]@{}
foreach ($q in $QualityArgs.Keys) {
    $label = $(if ($q -eq 'CBR320') { 'CBR 320 kbps' } else { "VBR $q" })
    $radios[$q] = New-Ctl RadioButton @{ Text = $label; AutoSize = $true; Margin = '6,5,6,3'; Checked = ($q -eq 'CBR320') }
    $rowQ.Controls.Add($radios[$q])
}
Add-Row $rowQ

# Options
$rowOpt = New-Flow $true
$chkOverwrite = New-Ctl CheckBox @{ Text = 'Overwrite existing .mp3'; AutoSize = $true; Checked = $true }
$chkDelete = New-Ctl CheckBox @{ Text = 'Delete original FLAC after a successful conversion (moves it to the Recycle Bin)'; AutoSize = $true }
$chkPlaylists = New-Ctl CheckBox @{ Text = 'Also update playlists (.m3u / .m3u8) in the main folder: replace the .flac entries with the .mp3'
    AutoSize = $true; Enabled = $false; Margin = '24,3,3,3' }
$rowOpt.Controls.AddRange(@($chkOverwrite, $chkDelete, $chkPlaylists))
Add-Row $rowOpt

# Run controls
$rowRun = New-Ctl TableLayoutPanel @{ AutoSize = $true; Dock = 'Fill'; ColumnCount = 4; Margin = '0,6,0,6' }
foreach ($s in @('AutoSize', 'AutoSize', 'Percent', 'AutoSize')) {
    [void]$rowRun.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle($s, 100)))
}
$btnGo = New-Ctl Button @{ Text = 'Convert'; Width = 100; Height = 30; Enabled = [bool]($FlacExe -and $LameExe) }
$btnCancel = New-Ctl Button @{ Text = 'Cancel'; Width = 100; Height = 30; Enabled = $false }
# Flat progress bar (the system ProgressBar can't be recoloured): a track panel with a fill panel inside.
$bar = New-Ctl Panel @{ Dock = 'Fill'; Margin = '6,10,6,10'; Height = 12 }
$barFill = New-Ctl Panel @{ Dock = 'Left'; Width = 0 }
$bar.Controls.Add($barFill)
$script:barMax = 1; $script:barValue = 0
function Set-Progress([int]$value, [int]$max) {
    $script:barMax = [Math]::Max(1, $max); $script:barValue = [Math]::Min($script:barMax, $value)
    $barFill.Width = [int]($bar.ClientSize.Width * $script:barValue / $script:barMax)
}
$bar.Add_Resize({ Set-Progress $script:barValue $script:barMax })
$lblStatus = New-Ctl Label @{ Text = 'Idle'; AutoSize = $true; Margin = '3,9,3,3' }
$rowRun.Controls.Add($btnGo, 0, 0); $rowRun.Controls.Add($btnCancel, 1, 0); $rowRun.Controls.Add($bar, 2, 0); $rowRun.Controls.Add($lblStatus, 3, 0)
Add-Row $rowRun

$txtLog = New-Ctl TextBox @{ Multiline = $true; ReadOnly = $true; ScrollBars = 'Both'; WordWrap = $false; Dock = 'Fill'
    Font = New-Object Drawing.Font('Consolas', 9); BackColor = [Drawing.SystemColors]::Window }
Add-Row $txtLog 'Percent' 60

$form.Controls.Add($root)

# ---- dark theme ---------------------------------------------------------------
Add-Type -Namespace Native -Name Dwm -MemberDefinition @'
[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
[DllImport("uxtheme.dll", CharSet = CharSet.Unicode)] public static extern int SetWindowTheme(IntPtr hwnd, string app, string idList);
[DllImport("uxtheme.dll", EntryPoint = "#135")] public static extern int SetPreferredAppMode(int mode);
'@
# Undocumented (uxtheme ordinal 135, Win10 1903+): ForceDark lets "DarkMode_Explorer" darken scrollbars.
try { [void][Native.Dwm]::SetPreferredAppMode(2) } catch { }
$Theme = @{
    Back = [Drawing.Color]::FromArgb(30, 30, 30); Input = [Drawing.Color]::FromArgb(43, 43, 46)
    Fore = [Drawing.Color]::FromArgb(230, 230, 230); Border = [Drawing.Color]::FromArgb(70, 70, 76)
    Button = [Drawing.Color]::FromArgb(51, 51, 55); Hover = [Drawing.Color]::FromArgb(64, 64, 70)
    Accent = [Drawing.Color]::FromArgb(14, 99, 156); AccentHover = [Drawing.Color]::FromArgb(17, 119, 187)
}
function Set-DarkTheme($ctl) {
    $ctl.ForeColor = $Theme.Fore
    switch ($ctl.GetType().Name) {
        'TextBox' { $ctl.BackColor = $Theme.Input; $ctl.BorderStyle = 'FixedSingle' }
        'Button' {
            $ctl.FlatStyle = 'Flat'; $ctl.BackColor = $Theme.Button
            $ctl.FlatAppearance.BorderColor = $Theme.Border; $ctl.FlatAppearance.MouseOverBackColor = $Theme.Hover
        }
        { $_ -in 'CheckBox', 'RadioButton' } { $ctl.FlatStyle = 'Flat'; $ctl.BackColor = $Theme.Back }
        default { $ctl.BackColor = $Theme.Back }
    }
    foreach ($c in $ctl.Controls) { Set-DarkTheme $c }
}
Set-DarkTheme $form
$btnGo.BackColor = $Theme.Accent; $btnGo.FlatAppearance.BorderColor = $Theme.Accent
$btnGo.FlatAppearance.MouseOverBackColor = $Theme.AccentHover
$form.Add_HandleCreated({
        $on = 1   # DWMWA_USE_IMMERSIVE_DARK_MODE (20): dark title bar on Win10 20H1+ / Win11
        [void][Native.Dwm]::DwmSetWindowAttribute($form.Handle, 20, [ref]$on, 4)
    })
# Dark scrollbars; applied at handle creation so they are themed before the first paint.
foreach ($t in @($txtIn, $txtLog)) { $t.Add_HandleCreated({ param($s) [void][Native.Dwm]::SetWindowTheme($s.Handle, 'DarkMode_Explorer', $null) }) }
$bar.BackColor = $Theme.Input; $barFill.BackColor = $Theme.Accent

function Write-UiLog([string]$m) { $txtLog.AppendText($m + "`r`n") }
if (-not $FlacExe -or -not $LameExe) { Write-UiLog 'ERROR flac.exe and/or lame.exe not found on PATH. Add their folder to PATH and restart.' }
else { Write-UiLog "flac: $FlacExe"; Write-UiLog "lame: $LameExe" }
$form.Add_Shown({ $txtIn.Focus() })

function Get-MainDir {
    $d = $txtMain.Text.Trim().Trim('"')
    if (-not $d -or -not [IO.Directory]::Exists($d)) { return $null }
    $d = [IO.Path]::GetFullPath($d).TrimEnd('\'); if ($d.Length -eq 2) { $d += '\' }
    $d
}

# Appends paths to the input box, separated by the current delimiter.
function Add-InputPaths([string[]]$paths) {
    if (-not $paths) { return }
    $d = ConvertFrom-Delimiter $txtDelim.Text
    if ($d -eq "`n") { $d = "`r`n" }
    $cur = $txtIn.Text
    if ($cur -and -not $cur.EndsWith($d)) { $cur += $d }
    $txtIn.Text = $cur + ($paths -join $d) + $(if ($d -eq "`r`n") { $d } else { '' })
}

$chkDelete.Add_CheckedChanged({ $chkPlaylists.Enabled = $chkDelete.Checked; if (-not $chkDelete.Checked) { $chkPlaylists.Checked = $false } })

$btnMain.Add_Click({
        $dlg = New-Ctl FolderBrowserDialog @{ Description = 'Main folder'; SelectedPath = $txtMain.Text }
        if ($dlg.ShowDialog($form) -eq 'OK') { $txtMain.Text = $dlg.SelectedPath }
    })
$btnFiles.Add_Click({
        $main = Get-MainDir
        $dlg = New-Ctl OpenFileDialog @{ Multiselect = $true; Filter = 'FLAC files (*.flac)|*.flac'; Title = 'Add FLAC files' }
        if ($main) { $dlg.InitialDirectory = $main }
        if ($dlg.ShowDialog($form) -eq 'OK') { Add-InputPaths $dlg.FileNames }
    })
$btnFolder.Add_Click({
        $main = Get-MainDir
        $dlg = New-Ctl FolderBrowserDialog @{ Description = 'Add every .flac in this folder (and its subfolders)' }
        if ($main) { $dlg.SelectedPath = $main }
        if ($dlg.ShowDialog($form) -eq 'OK') {
            $found = @([IO.Directory]::GetFiles($dlg.SelectedPath, '*.flac', 'AllDirectories') | Sort-Object)
            Write-UiLog "Added $($found.Count) file(s) from $($dlg.SelectedPath)"
            Add-InputPaths $found
        }
    })
$btnClear.Add_Click({ $txtIn.Clear() })

$script:job = $null
$timer = New-Object Windows.Forms.Timer
$timer.Interval = 150

function Set-Busy([bool]$busy) {
    foreach ($c in @($txtMain, $btnMain, $txtIn, $btnFiles, $btnFolder, $btnClear, $txtDelim, $chkOverwrite, $chkDelete, $btnGo) + @($radios.Values)) { $c.Enabled = -not $busy }
    $chkPlaylists.Enabled = (-not $busy) -and $chkDelete.Checked
    $btnCancel.Enabled = $busy
}

$timer.Add_Tick({
        $j = $script:job
        if (-not $j) { return }
        $sb = New-Object Text.StringBuilder
        $m = $null
        while ($j.Sync.Log.TryDequeue([ref]$m)) { [void]$sb.Append($m).Append("`r`n") }
        if ($sb.Length) { $txtLog.AppendText($sb.ToString()) }
        Set-Progress $j.Sync.Done $j.Sync.Total
        $lblStatus.Text = "$($j.Sync.Done) / $($j.Sync.Total)"
        if ($j.Sync.Finished) {
            $timer.Stop()
            try { $j.PS.EndInvoke($j.Handle) } catch { Write-UiLog "ERROR $($_.Exception.Message)" }
            $j.PS.Dispose(); $j.RS.Dispose()
            $script:job = $null
            Set-Busy $false
            $lblStatus.Text = "Done $($j.Sync.Done) / $($j.Sync.Total)"
        }
    })

$btnGo.Add_Click({
        $main = Get-MainDir
        if (-not $main) { [void][Windows.Forms.MessageBox]::Show($form, 'Main folder does not exist.', 'FLAC to MP3', 'OK', 'Warning'); return }
        $script:MainDir = $main
        $r = Resolve-InputList $txtIn.Text $txtDelim.Text $main
        $txtLog.Clear()
        foreach ($m in $r.Rejected) { Write-UiLog $m }
        if ($r.Valid.Count -eq 0) { Write-UiLog 'Nothing to convert.'; return }

        if ($chkDelete.Checked) {
            $msg = "$($r.Valid.Count) FLAC file(s) will be moved to the Recycle Bin after each successful conversion."
            if ($chkPlaylists.Checked) { $msg += "`n`nPlaylists under $main will be updated (a .bak copy is kept)." }
            if ([Windows.Forms.MessageBox]::Show($form, $msg + "`n`nContinue?", 'FLAC to MP3', 'OKCancel', 'Question') -ne 'OK') { return }
        }

        $quality = ($radios.Keys | Where-Object { $radios[$_].Checked } | Select-Object -First 1)
        $sync = New-Sync $r.Valid.Count $false
        $opt = New-Options $r.Valid $quality $chkOverwrite.Checked $chkDelete.Checked $chkPlaylists.Checked $FlacExe $LameExe

        $rs = [runspacefactory]::CreateRunspace(); $rs.Open()
        $ps = [powershell]::Create(); $ps.Runspace = $rs
        [void]$ps.AddScript($Worker.ToString()).AddArgument($sync).AddArgument($opt)
        $script:job = @{ PS = $ps; RS = $rs; Sync = $sync; Handle = $ps.BeginInvoke() }
        Set-Progress 0 1
        Set-Busy $true
        $timer.Start()
    })

$btnCancel.Add_Click({
        if ($script:job) { $script:job.Sync.Cancel = $true; $btnCancel.Enabled = $false; Write-UiLog 'Cancelling after the current file...' }
    })

$form.Add_FormClosing({
        param($s, $e)
        if ($script:job -and -not $script:job.Sync.Finished) {
            $a = [Windows.Forms.MessageBox]::Show($form, 'A conversion is running. Stop after the current file and close?', 'FLAC to MP3', 'YesNo', 'Warning')
            if ($a -ne 'Yes') { $e.Cancel = $true; return }
            $script:job.Sync.Cancel = $true
            while (-not $script:job.Sync.Finished) { Start-Sleep -Milliseconds 100 }
        }
    })

[void]$form.ShowDialog()
