# flac2mp3

Converts FLAC files to MP3 with `lame.exe`, copying all metadata and cover art. It can optionally move the
source FLAC to the Recycle Bin and point playlists at the new MP3.

There are two independent tools:

| | **foobar2000 component** (`foo_flac2mp3/`) | **Standalone GUI** (`FlacToMp3.ps1`) |
|---|---|---|
| Runs from | right-click in foobar2000 → *Convert to MP3* | a WinForms window (`FlacToMp3.cmd`) |
| Decoder | foobar2000's own decoders | `flac.exe` from PATH |
| Tag writer | foobar2000's own (exact foobar result, ID3v2.3 by default) | built-in ID3v2.4 writer, foobar-style mapping |
| Playlists updated | foobar2000 playlists + `.m3u`/`.m3u8` files | `.m3u`/`.m3u8` files |
| Needs | foobar2000 2.x (x64) | Windows PowerShell 5.1, `flac.exe` + `lame.exe` on PATH |

`FOOBAR-COMPONENT.md` explains why the component exists, how it works internally, and its tag behaviour.

## Repository layout

```
.gitignore
Directory.Build.targets   adds the WTL include path to every MSBuild project below this folder
setup-sdk.ps1             downloads the foobar2000 SDK + WTL into sdk\ (git-ignored)
FlacToMp3.ps1             standalone GUI / CLI converter
FOOBAR-COMPONENT.md       design notes for the component
foo_flac2mp3\
  main.cpp                component info + "Convert to MP3" context menu
  preferences.cpp         Preferences > Tools > FLAC to MP3 page (settings storage)
  converter.cpp           decode -> lame -> tags/art -> move -> recycle -> playlists
  flac2mp3.h              shared declarations (Settings, entry points)
  foo_flac2mp3.rc         preferences dialog layout
  resource.h, stdafx.h, PCH.cpp
  foo_flac2mp3.vcxproj    MSBuild project (based on the SDK's foo_sample)
  build.ps1               build + package as foo_flac2mp3.fb2k-component
sdk\                      (not in git) foobar2000 SDK and WTL, created by setup-sdk.ps1
```

## foobar2000 component

### Prerequisites
- Windows 10/11 x64, foobar2000 2.x (64-bit)
- Visual Studio 2022 (Community is fine) with the **Desktop development with C++** workload
- `lame.exe` on PATH, or in `foobar2000\encoders` (bundled with foobar2000's encoder pack)

### Build
```powershell
# one time: fetch foobar2000 SDK 2026-10-01 and WTL 10.0.10320 into .\sdk
powershell -ExecutionPolicy Bypass -File .\setup-sdk.ps1

# build Release x64 and package it
powershell -ExecutionPolicy Bypass -File .\foo_flac2mp3\build.ps1
```
Output:
- `foo_flac2mp3\x64\Release\foo_flac2mp3.dll`
- `foo_flac2mp3\foo_flac2mp3.fb2k-component` (a zip with `x64/foo_flac2mp3.dll`). This file is committed, so a clone
  can be installed without building. Rebuild and commit it together with any source change.

The first build also compiles the SDK libraries and takes about a minute. Later builds are incremental.
To build from Visual Studio, open `foo_flac2mp3\foo_flac2mp3.vcxproj` and choose **Release | x64**.

### Install / update
1. Close foobar2000.
2. Double-click `foo_flac2mp3\foo_flac2mp3.fb2k-component` and confirm. Or use *Preferences > Components > Install...*
3. Restart foobar2000 when asked. **FLAC to MP3** appears under *Preferences > Components*.

To uninstall: *Preferences > Components* → right-click **FLAC to MP3** → *Remove* → restart.

### Settings — *Preferences > Tools > FLAC to MP3*
You can also open this page from right-click → *Convert to MP3 > Settings...*

| Setting | Default | |
|---|---|---|
| Overwrite existing MP3 files | on | off = skip tracks whose `.mp3` already exists |
| Parallel conversions | 0 | 0 = one per CPU core |
| lame.exe | empty | empty = PATH, then `foobar2000\encoders\lame.exe` |
| Delete the source FLAC | off | moves it to the Recycle Bin; the options below apply only when this is on |
| Replace FLAC with MP3 in foobar2000 playlists | on | same position; Ctrl+Z undoes it per playlist; locked playlists are skipped |
| Replace FLAC with MP3 in .m3u / .m3u8 files under: *folder* | on, folder empty | set the folder (e.g. `D:\Music`); empty = playlist files are never touched |
| Keep a .bak copy of each changed playlist file | off | writes `<playlist>.bak` before changing it |

### Use
Select tracks → right-click → **Convert to MP3** → **CBR 320 kbps / VBR V0 / VBR V1 / VBR V2**.
- The MP3 is written next to the FLAC with the same name, and gets the FLAC's modified date.
- With *Delete* on, a confirmation lists what will happen first.
- A progress dialog with Cancel is shown. At the end a report lists converted, skipped and failed tracks and the
  playlists that changed. The same report goes to *View > Console*.
- Tracks that aren't local `.flac` files, and multi-track (cue sheet) FLACs, are skipped.

From a script, use the bare command name:
```
foobar2000.exe "/context_command:VBR V0" "D:\music\a.flac" "D:\music\b.flac"
```
`Convert to MP3/VBR V0` is **not** recognised on the command line, and foobar2000 shows an "unknown parameter" error.

### Testing a build without touching your foobar2000 profile
1. Copy the foobar2000 program folder somewhere and create an empty `portable_mode_enabled` file in it.
2. Put the DLL in `<copy>\profile\user-components-x64\foo_flac2mp3\`.
3. Optional: build with `$env:CL='/DFLAC2MP3_TEST'` to get a test build. It defaults *Delete* to on, takes the
   playlist folder from the `FLAC2MP3_TEST_MAIN` environment variable, and traces to `%TEMP%\foo_flac2mp3_trace.log`.
   Release builds contain none of this.

## Standalone GUI (`FlacToMp3.ps1`)

No build needed. It needs `flac.exe` and `lame.exe` on PATH (for example, add `C:\Program Files\foobar2000\encoders` to PATH).

Launch it with a `FlacToMp3.cmd` placed in the music folder, next to this `flac2mp3` folder:
```bat
@echo off
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0flac2mp3\FlacToMp3.ps1" -MainDir "%CD%."
```
- **Main folder:** defaults to the current directory. Only FLACs inside it are converted, and only playlists inside it are updated.
- **Input:** paste paths using a custom delimiter (default new line), and/or use *Add files* / *Add folder*.
- **Options:**
  - Quality: CBR 320 / V0 / V1 / V2
  - Overwrite (default on)
  - Delete source (Recycle Bin)
  - Update `.m3u`/`.m3u8` playlists. This writes a `.bak` copy of each changed playlist.

CLI mode, used for testing:
```powershell
powershell -File FlacToMp3.ps1 -NoGui -MainDir D:\Music -Files "a.flac|sub\b.flac" -Delimiter "|" `
  -Quality V0 [-NoOverwrite] [-DeleteFlac] [-UpdatePlaylists]
```

## Files created next to your music
- `<name>.mp3.tmp`: written during a conversion, then renamed to `<name>.mp3`. It's only left behind if the conversion is interrupted.
- `<playlist>.bak`: a backup of a changed playlist. The component writes it only when the option is on; the standalone GUI always writes it.

If the music folder is synced or backed up, you may want to exclude these patterns.
