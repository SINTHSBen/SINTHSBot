#Requires -Version 5.1
param(
    [ValidateSet('fd', 'self')]
    [string]$Mode = 'fd'
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$proj = Join-Path $PSScriptRoot 'HwidGui\HwidGui.csproj'
$out = Join-Path $root 'dist'

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    throw 'dotnet SDK fehlt. https://dotnet.microsoft.com/download'
}

New-Item -ItemType Directory -Force -Path $out | Out-Null

if ($Mode -eq 'self') {
    Write-Host 'Building self-contained win-x64...'
    dotnet publish $proj -c Release -r win-x64 --self-contained true `
        -p:PublishSingleFile=true -p:EnableWindowsTargeting=true -o $out
}
else {
    Write-Host 'Building framework-dependent win-x64 (needs .NET 8 Desktop Runtime)...'
    dotnet publish $proj -c Release -r win-x64 --self-contained false `
        -p:PublishSingleFile=true -p:EnableWindowsTargeting=true -o $out
}

$exe = Join-Path $out 'SINTHSBot-HWID.exe'
if (-not (Test-Path $exe)) { throw "Build fehlgeschlagen: $exe" }
Get-Item $exe | Format-List FullName, Length, LastWriteTime
