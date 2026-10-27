# Downloads the third-party build dependencies into .\sdk (git-ignored):
#   - foobar2000 SDK (foobar2000.org)  -> sdk\foobar2000, sdk\pfc, sdk\libPPUI, ...
#   - WTL headers (NuGet package "wtl") -> sdk\wtl\lib\native\include
# Re-run with -Force to replace an existing sdk folder.
param(
    [string]$SdkVersion = '2026-10-01',
    [string]$WtlVersion = '10.0.10320',
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
$root = Join-Path $PSScriptRoot 'sdk'

if (Test-Path $root) {
    if (-not $Force) { throw "$root already exists. Use -Force to replace it." }
    Remove-Item -Recurse -Force $root
}
New-Item -ItemType Directory -Force $root, "$root\wtl" | Out-Null

$sdkArchive = Join-Path $root 'SDK.7z'
Write-Host "Downloading foobar2000 SDK $SdkVersion..."
Invoke-WebRequest "https://www.foobar2000.org/downloads/SDK-$SdkVersion.7z" -OutFile $sdkArchive -UseBasicParsing
# Windows 10 1803+ tar.exe (libarchive) extracts .7z.
& "$env:SystemRoot\System32\tar.exe" -xf $sdkArchive -C $root
if ($LASTEXITCODE -ne 0) { throw 'Extracting the SDK failed.' }

$wtlArchive = Join-Path $root 'wtl\wtl.zip'
Write-Host "Downloading WTL $WtlVersion..."
Invoke-WebRequest "https://api.nuget.org/v3-flatcontainer/wtl/$WtlVersion/wtl.$WtlVersion.nupkg" -OutFile $wtlArchive -UseBasicParsing
Expand-Archive $wtlArchive -DestinationPath "$root\wtl" -Force

foreach ($check in 'foobar2000\SDK\foobar2000.h', 'pfc\pfc.h', 'wtl\lib\native\include\atlapp.h') {
    if (-not (Test-Path (Join-Path $root $check))) { throw "Missing $check after setup." }
}
Write-Host "SDK ready in $root"
