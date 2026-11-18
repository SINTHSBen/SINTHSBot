#Requires -Version 5.1
<#
.SYNOPSIS
    Windows HWID Backup & Restore — original identity before/after Nebel-style spoof.

.DESCRIPTION
    backup / verify / safe restore (registry + NetworkAddress) /
    generate-amide-restore (writes ORIGINAL SMBIOS script for AMIDEWIN — never randomizes).

.EXAMPLE
    .\hwid.ps1 backup
.EXAMPLE
    .\hwid.ps1 verify .\backups\hwid-....json
.EXAMPLE
    .\hwid.ps1 restore .\backups\hwid-....json
.EXAMPLE
    .\hwid.ps1 generate-amide-restore .\backups\hwid-....json
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
     (prüft Skript, legt AMIDEWINx64.EXE daneben, tippt RESTORE-ORIGINAL)

Usage:
  .\hwid.ps1 backup
  .\hwid.ps1 list
  .\hwid.ps1 show [file]
  .\hwid.ps1 verify <file>
  .\hwid.ps1 restore <file> [-Force]
  .\hwid.ps1 generate-amide-restore <file>

Safe restore writes:
  MachineGuid, HwProfileGuid, SQM MachineId, SusClientId, ComputerHardwareId,
  NetworkAddress overrides (clear/set to match backup)

Never auto-writes:
  UEFI/SMBIOS firmware, EEPROM MAC (MACX), TPM/BIOS flash, random spoof values
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

function Invoke-HwidBackupCommand {
    $result = Save-HwidBackup -BackupDirectory $BackupDirectory -Prefix 'hwid'
    $validation = Test-HwidBackupObject -Backup $result.Payload
    if (-not $validation.IsValid) {
        Write-Warning ("Backup geschrieben, aber Validierung: {0}" -f ($validation.Errors -join '; '))
    }

    Write-Host "Original-Backup gespeichert: $($result.Path)"
    Write-Host ''
    $r = $result.Payload.restorable
    Write-Host 'Registry (safe restorable):'
    Write-Host ("  machineGuid:   {0}" -f $(if ($r.machineGuid) { $r.machineGuid } else { '<n/a>' }))
    Write-Host ("  hwProfileGuid: {0}" -f $(if ($r.hwProfileGuid) { $r.hwProfileGuid } else { '<n/a>' }))
    Write-Host ("  sqmMachineId:  {0}" -f $(if ($r.sqmMachineId) { $r.sqmMachineId } else { '<n/a>' }))
    Write-Host ("  susClientId:   {0}" -f $(if ($r.susClientId) { $r.susClientId } else { '<n/a>' }))
    $s = $result.Payload.smbios
    Write-Host 'SMBIOS (für generate-amide-restore):'
    Write-Host ("  UUID:          {0}" -f $(if ($s.systemUuid) { $s.systemUuid } else { '<n/a>' }))
    Write-Host ("  BaseBoard:     {0}" -f $(if ($s.baseBoardSerial) { $s.baseBoardSerial } else { '<n/a>' }))
    Write-Host ("  Chassis:       {0}" -f $(if ($s.chassisSerial) { $s.chassisSerial } else { '<n/a>' }))
    Write-Host ("  SystemSerial:  {0}" -f $(if ($s.systemSerial) { $s.systemSerial } else { '<n/a>' }))
    Write-Host ''
    Write-Host 'Wichtig: Dieses Backup VOR Nebel Permanent Spoof / MACX erstellen.'
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
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
