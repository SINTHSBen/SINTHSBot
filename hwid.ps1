#Requires -Version 5.1
<#
.SYNOPSIS
    Windows HWID Backup & Restore -- original identity before/after Nebel-style spoof.

.DESCRIPTION
    backup / verify / safe restore (registry + NetworkAddress) /
    generate-amide-restore (writes ORIGINAL SMBIOS script for AMIDEWIN -- never randomizes).
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('backup', 'list', 'show', 'restore', 'verify', 'generate-amide-restore', 'help')]
    [string]$Command = 'help',

    [Parameter(Position = 1)]
    [string]$Path,

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($scriptRoot)) {
    $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}

. (Join-Path $scriptRoot 'lib\Logger.ps1')
. (Join-Path $scriptRoot 'lib\Collect.ps1')
. (Join-Path $scriptRoot 'lib\Validate.ps1')
. (Join-Path $scriptRoot 'lib\Restore.ps1')

$BackupDirectory = if (-not [string]::IsNullOrWhiteSpace($env:SINTHSBOT_BACKUPS)) {
    $env:SINTHSBOT_BACKUPS
}
else {
    Join-Path $scriptRoot 'backups'
}

function Show-Usage {
    @"
SINTHSBot HWID Backup & Restore (Nebel-aware)

Workflow:
  1) VOR dem Spoof:  .\hwid.ps1 backup
  2) Nach dem Spoof: .\hwid.ps1 verify <backup>
  3) Safe restore:   .\hwid.ps1 restore <backup>
  4) UEFI original:  .\hwid.ps1 generate-amide-restore <backup>

Logs: `$env:LOCALAPPDATA\SINTHSBot-HWID\logs\latest.log
"@ | Write-Host
}

function Resolve-BackupPath {
    param([Parameter(Mandatory)][string]$FilePath)

    if ([System.IO.Path]::IsPathRooted($FilePath) -and (Test-Path -LiteralPath $FilePath)) {
        return (Resolve-Path -LiteralPath $FilePath).Path
    }

    $inBackups = Join-Path $BackupDirectory $FilePath
    if (Test-Path -LiteralPath $inBackups) {
        return (Resolve-Path -LiteralPath $inBackups).Path
    }

    if (Test-Path -LiteralPath $FilePath) {
        return (Resolve-Path -LiteralPath $FilePath).Path
    }

    throw "Backup-Datei nicht gefunden: $FilePath"
}

function Get-PropSafe {
    param($Object, [string]$Name, [string]$Fallback = '<n/a>')
    if ($null -eq $Object) { return $Fallback }
    try {
        $map = $Object
        if ($Object -isnot [hashtable] -and $Object -isnot [System.Collections.Specialized.OrderedDictionary]) {
            # PSCustomObject / others
            $p = $Object.PSObject.Properties[$Name]
            if ($null -eq $p -or $null -eq $p.Value -or [string]::IsNullOrWhiteSpace([string]$p.Value)) {
                return $Fallback
            }
            return [string]$p.Value
        }
        if ($map.Contains($Name) -and $map[$Name] -and -not [string]::IsNullOrWhiteSpace([string]$map[$Name])) {
            return [string]$map[$Name]
        }
    }
    catch { }
    return $Fallback
}

function Invoke-HwidBackupCommand {
    Write-HwidLog -Level INFO -Message ("backup start backupsDir={0}" -f $BackupDirectory)
    Write-HwidLog -Level INFO -Message ("PSVersion={0} User={1} IsAdmin={2}" -f $PSVersionTable.PSVersion, $env:USERNAME, (Test-IsAdministrator))

    try {
        $result = Save-HwidBackup -BackupDirectory $BackupDirectory -Prefix 'hwid'
        Write-HwidLog -Level INFO -Message ("backup written path={0}" -f $result.Path)

        $validation = Test-HwidBackupObject -Backup $result.Payload
        if (-not $validation.IsValid) {
            $msg = ($validation.Errors -join '; ')
            Write-Warning ("Backup geschrieben, aber Validierung: {0}" -f $msg)
            Write-HwidLog -Level WARN -Message ("backup validation soft-fail: {0}" -f $msg)
        }
        else {
            Write-HwidLog -Level INFO -Message 'backup validation OK'
        }

        Write-Host "Original-Backup gespeichert: $($result.Path)"
        Write-Host ''
        $r = $result.Payload.restorable
        Write-Host 'Registry (safe restorable):'
        Write-Host ("  machineGuid:   {0}" -f (Get-PropSafe $r 'machineGuid'))
        Write-Host ("  hwProfileGuid: {0}" -f (Get-PropSafe $r 'hwProfileGuid'))
        Write-Host ("  sqmMachineId:  {0}" -f (Get-PropSafe $r 'sqmMachineId'))
        Write-Host ("  susClientId:   {0}" -f (Get-PropSafe $r 'susClientId'))
        $s = $result.Payload.smbios
        Write-Host 'SMBIOS (für generate-amide-restore):'
        Write-Host ("  UUID:          {0}" -f (Get-PropSafe $s 'systemUuid'))
        Write-Host ("  BaseBoard:     {0}" -f (Get-PropSafe $s 'baseBoardSerial'))
        Write-Host ("  Chassis:       {0}" -f (Get-PropSafe $s 'chassisSerial'))
        Write-Host ("  SystemSerial:  {0}" -f (Get-PropSafe $s 'systemSerial'))
        Write-Host ''
        Write-Host ("Log: {0}" -f (Join-Path (Get-HwidLogDirectory) 'latest.log'))
        Write-Host 'Wichtig: Dieses Backup VOR Nebel Permanent Spoof / MACX erstellen.'
    }
    catch {
        Write-HwidLog -Level ERROR -Message 'backup failed' -ErrorRecord $_
        throw
    }
}

function Invoke-HwidListCommand {
    if (-not (Test-Path -LiteralPath $BackupDirectory)) {
        Write-Host 'Keine Backups vorhanden.'
        return
    }

    $files = @(Get-ChildItem -LiteralPath $BackupDirectory -Filter '*.json' -File |
        Sort-Object LastWriteTime -Descending)

    if ($files.Count -eq 0) {
        Write-Host 'Keine Backups vorhanden.'
        return
    }

    Write-Host ('{0,-42} {1,-22} {2}' -f 'Datei', 'Geändert', 'Größe')
    Write-Host ('-' * 80)
    foreach ($f in $files) {
        Write-Host ('{0,-42} {1,-22} {2,8:N0} B' -f $f.Name, $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'), $f.Length)
    }
}

function Invoke-HwidShowCommand {
    param([string]$FilePath)

    if ([string]::IsNullOrWhiteSpace($FilePath)) {
        $current = New-HwidBackupObject
        Write-Host 'Aktueller Stand (noch nicht als Datei gespeichert):'
        Write-Host ($current | ConvertTo-Json -Depth 10)
        return
    }

    $resolved = Resolve-BackupPath -FilePath $FilePath
    $backup = Read-HwidBackupFile -Path $resolved
    $validation = Test-HwidBackupObject -Backup $backup
    if (-not $validation.IsValid) {
        Write-Warning ("Validierung: {0}" -f ($validation.Errors -join '; '))
    }
    Write-Host "Datei: $resolved"
    Write-Host ($backup | ConvertTo-Json -Depth 10)
}

Write-HwidLog -Level INFO -Message ("hwid.ps1 start command={0} path={1} force={2}" -f $Command, $Path, [bool]$Force)

try {
    switch ($Command) {
        'help' { Show-Usage }
        'backup' { Invoke-HwidBackupCommand }
        'list' { Invoke-HwidListCommand }
        'show' { Invoke-HwidShowCommand -FilePath $Path }
        'verify' {
            if ([string]::IsNullOrWhiteSpace($Path)) {
                throw 'verify benötigt eine Backup-Datei.'
            }
            $null = Invoke-HwidVerify -BackupPath (Resolve-BackupPath -FilePath $Path)
        }
        'restore' {
            if ([string]::IsNullOrWhiteSpace($Path)) {
                throw 'restore benötigt eine Backup-Datei.'
            }
            $null = Invoke-HwidRestore -BackupPath (Resolve-BackupPath -FilePath $Path) -BackupDirectory $BackupDirectory -Force:$Force
        }
        'generate-amide-restore' {
            if ([string]::IsNullOrWhiteSpace($Path)) {
                throw 'generate-amide-restore benötigt eine Backup-Datei.'
            }
            $outDir = Join-Path $BackupDirectory 'amide-restore'
            $null = New-AmideOriginalRestoreScript -BackupPath (Resolve-BackupPath -FilePath $Path) -OutputDirectory $outDir
        }
        default { Show-Usage }
    }
    Write-HwidLog -Level INFO -Message ("hwid.ps1 end OK command={0}" -f $Command)
}
catch {
    Write-HwidLog -Level ERROR -Message ("hwid.ps1 failed command={0}" -f $Command) -ErrorRecord $_
    Write-Error $_.Exception.Message
    Write-Host ("Log: {0}" -f (Join-Path (Get-HwidLogDirectory) 'latest-error.txt'))
    exit 1
}
