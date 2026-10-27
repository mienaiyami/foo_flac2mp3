# Builds foo_flac2mp3 (Release x64) and packages it as foo_flac2mp3.fb2k-component next to this script.
# Double-click the .fb2k-component (or Preferences > Components > Install...) to install it into foobar2000.
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$msbuild = & $vswhere -latest -requires Microsoft.Component.MSBuild -find 'MSBuild\**\Bin\MSBuild.exe' | Select-Object -First 1
if (-not $msbuild) { throw 'MSBuild not found; install Visual Studio 2022 with "Desktop development with C++".' }

& $msbuild "$here\foo_flac2mp3.vcxproj" /p:Configuration=Release /p:Platform=x64 /m /v:minimal /nologo
if ($LASTEXITCODE -ne 0) { throw 'Build failed.' }

# foobar2000 2.x packages carry the 64-bit DLL in an x64/ subfolder. The entry is written by hand because
# Compress-Archive on Windows PowerShell 5.1 stores "x64\..." with a backslash.
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$pkg = "$here\foo_flac2mp3.fb2k-component"
Remove-Item $pkg -ErrorAction SilentlyContinue
$archive = [IO.Compression.ZipFile]::Open($pkg, 'Create')
try {
    [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, "$here\x64\Release\foo_flac2mp3.dll", 'x64/foo_flac2mp3.dll')
} finally { $archive.Dispose() }
"Package: $pkg"
