#Requires -Version 5.1
<#
.SYNOPSIS
    Windows HWID Backup & Restore (safe-by-default).

.DESCRIPTION
    Backup and restore MachineGuid / HwProfileGuid / SQM MachineId only.
    Never touches firmware, disk serials, MACs, or drivers.

.EXAMPLE
    .\hwid.ps1 backup
.EXAMPLE
    .\hwid.ps1 list
.EXAMPLE
    .\hwid.ps1 show
.EXAMPLE
    .\hwid.ps1 restore .\backups\hwid-....json
.EXAMPLE
    .\hwid.ps1 restore .\backups\hwid-....json -Force
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('backup', 'list', 'show', 'restore', 'help')]
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

$BackupDirectory = Join-Path $scriptRoot 'backups'

function Show-Usage {
    @"
SINTHSBot HWID Backup & Restore

Usage:
  .\hwid.ps1 backup
  .\hwid.ps1 list
  .\hwid.ps1 show [file]
  .\hwid.ps1 restore <file> [-Force]

Notes:
  - Restore needs Administrator rights.
  - Restore writes ONLY MachineGuid, HwProfileGuid, SQM MachineId.
  - A pre-restore snapshot is always created under backups\pre-restore-*.json
"@ | Write-Host
}

function Invoke-HwidBackupCommand {
    $result = Save-HwidBackup -BackupDirectory $BackupDirectory -Prefix 'hwid'
    $validation = Test-HwidBackupObject -Backup $result.Payload
    if (-not $validation.IsValid) {
        Write-Warning ("Backup geschrieben, aber Validierung meldet: {0}" -f ($validation.Errors -join '; '))
    }

    Write-Host "Backup gespeichert: $($result.Path)"
    Write-Host ''
    Write-Host 'Restorable:'
    $r = $result.Payload.restorable
    Write-Host ("  machineGuid:   {0}" -f $(if ($r.machineGuid) { $r.machineGuid } else { '<nicht lesbar>' }))
    Write-Host ("  hwProfileGuid: {0}" -f $(if ($r.hwProfileGuid) { $r.hwProfileGuid } else { '<nicht lesbar>' }))
    Write-Host ("  sqmMachineId:  {0}" -f $(if ($r.sqmMachineId) { $r.sqmMachineId } else { '<nicht vorhanden>' }))
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

function Format-HwidObject {
    param($Backup)

    $json = $Backup | ConvertTo-Json -Depth 6
    Write-Host $json
}

function Invoke-HwidShowCommand {
    param([string]$FilePath)

    if ([string]::IsNullOrWhiteSpace($FilePath)) {
        $current = New-HwidBackupObject
        Write-Host 'Aktueller Stand (noch nicht als Datei gespeichert):'
        Format-HwidObject -Backup $current
        return
    }

    $resolved = $FilePath
    if (-not [System.IO.Path]::IsPathRooted($resolved)) {
        $candidate = Join-Path $BackupDirectory $FilePath
        if (Test-Path -LiteralPath $candidate) {
            $resolved = $candidate
        }
        elseif (Test-Path -LiteralPath $FilePath) {
            $resolved = (Resolve-Path -LiteralPath $FilePath).Path
        }
    }

    $backup = Read-HwidBackupFile -Path $resolved
    $validation = Test-HwidBackupObject -Backup $backup
    if (-not $validation.IsValid) {
        Write-Warning ("Validierung: {0}" -f ($validation.Errors -join '; '))
    }
    Write-Host "Datei: $resolved"
    Format-HwidObject -Backup $backup
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

try {
    switch ($Command) {
        'help' {
            Show-Usage
        }
        'backup' {
            Invoke-HwidBackupCommand
        }
        'list' {
            Invoke-HwidListCommand
        }
        'show' {
            Invoke-HwidShowCommand -FilePath $Path
        }
        'restore' {
            if ([string]::IsNullOrWhiteSpace($Path)) {
                throw 'restore benötigt eine Backup-Datei. Beispiel: .\hwid.ps1 restore .\backups\hwid-....json'
            }
            $resolved = Resolve-BackupPath -FilePath $Path
            $null = Invoke-HwidRestore -BackupPath $resolved -BackupDirectory $BackupDirectory -Force:$Force
        }
        default {
            Show-Usage
        }
    }
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
