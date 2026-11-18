#Requires -Version 5.1
<#
.SYNOPSIS
    Safe restore of restorable HWID registry values with pre-snapshot and rollback.
#>

Set-StrictMode -Version Latest

function Test-IsAdministrator {
    [CmdletBinding()]
    param()

    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        return $false
    }
}

function Set-RegistryStringValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$Value
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }

    $existing = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $existing) {
        New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType String -Force | Out-Null
    }
    else {
        Set-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -Force
    }
}

function Write-RestorableRegistry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Restorable
    )

    $map = ConvertTo-HwidHashtable -InputObject $Restorable
    $written = New-Object System.Collections.Generic.List[string]
    $skipped = New-Object System.Collections.Generic.List[string]

    $targets = @(
        [pscustomobject]@{ Name = 'machineGuid'; Path = 'HKLM:\SOFTWARE\Microsoft\Cryptography'; RegName = 'MachineGuid' }
        [pscustomobject]@{ Name = 'hwProfileGuid'; Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\IDConfigDB\Hardware Profiles\0001'; RegName = 'HwProfileGuid' }
        [pscustomobject]@{ Name = 'sqmMachineId'; Path = 'HKLM:\SOFTWARE\Microsoft\SQMClient'; RegName = 'MachineId' }
    )

    foreach ($t in $targets) {
        $value = $null
        if ($map.Contains($t.Name)) {
            $value = $map[$t.Name]
        }

        if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)) {
            $skipped.Add($t.Name)
            Write-Warning "Überspringe $($t.Name): Wert fehlt im Backup."
            continue
        }

        if (-not (Test-IsGuidString -Value ([string]$value))) {
            throw "Ungültige GUID für $($t.Name): $value"
        }

        Set-RegistryStringValue -Path $t.Path -Name $t.RegName -Value ([string]$value)
        $written.Add($t.Name)
    }

    return [pscustomobject]@{
        Written = @($written)
        Skipped = @($skipped)
    }
}

function Invoke-HwidRestore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$BackupPath,

        [Parameter(Mandatory)]
        [string]$BackupDirectory,

        [switch]$Force
    )

    if (-not (Test-IsAdministrator)) {
        throw 'Restore benötigt Administrator-Rechte. PowerShell als Administrator neu starten und erneut ausführen.'
    }

    $backup = Read-HwidBackupFile -Path $BackupPath
    $validation = Test-HwidBackupObject -Backup $backup
    if (-not $validation.IsValid) {
        $msg = ($validation.Errors -join '; ')
        throw "Backup ungültig: $msg"
    }

    $current = New-HwidBackupObject
    $diff = Compare-RestorableHwid -Current $current -Target $backup
    Write-Host (Format-HwidDiff -DiffRows $diff)
    Write-Host ''

    # Always create pre-restore snapshot (even with -Force)
    if (-not (Test-Path -LiteralPath $BackupDirectory)) {
        New-Item -ItemType Directory -Path $BackupDirectory -Force | Out-Null
    }
    $snap = Save-HwidBackup -BackupDirectory $BackupDirectory -Prefix 'pre-restore'
    Write-Host "Pre-Restore-Snapshot gespeichert: $($snap.Path)"

    $willWrite = @($diff | Where-Object { $_.WillWrite -and $_.Changed })
    if ($willWrite.Count -eq 0) {
        Write-Host 'Keine Änderungen nötig — aktuelle restorable Werte entsprechen dem Backup.'
        return [pscustomobject]@{
            Status         = 'NoChange'
            SnapshotPath   = $snap.Path
            BackupPath     = $BackupPath
            Written        = @()
            Skipped        = @($diff | Where-Object { -not $_.WillWrite } | ForEach-Object { $_.Name })
        }
    }

    if (-not $Force) {
        Write-Host 'Es werden nur bekannte Registry-Werte überschrieben (MachineGuid, HwProfileGuid, SQM MachineId).'
        Write-Host 'Firmware-, Disk- und MAC-Werte bleiben unberührt.'
        $answer = Read-Host 'Restore fortsetzen? Tippe YES zum Bestätigen'
        if ($answer -ne 'YES') {
            Write-Host "Abgebrochen. Snapshot bleibt erhalten: $($snap.Path)"
            return [pscustomobject]@{
                Status       = 'Cancelled'
                SnapshotPath = $snap.Path
                BackupPath   = $BackupPath
                Written      = @()
                Skipped      = @()
            }
        }
    }

    try {
        $result = Write-RestorableRegistry -Restorable $backup.restorable
        Write-Host ''
        Write-Host "Restore erfolgreich. Geschrieben: $($result.Written -join ', ')"
        if ($result.Skipped.Count -gt 0) {
            Write-Host "Übersprungen: $($result.Skipped -join ', ')"
        }
        Write-Host 'Neustart empfohlen, damit alle Dienste die neuen Werte laden. (Kein Auto-Reboot.)'
        Write-Host "Falls etwas schiefgeht: .\hwid.ps1 restore `"$($snap.Path)`""

        return [pscustomobject]@{
            Status       = 'Success'
            SnapshotPath = $snap.Path
            BackupPath   = $BackupPath
            Written      = $result.Written
            Skipped      = $result.Skipped
        }
    }
    catch {
        Write-Error "Restore fehlgeschlagen: $($_.Exception.Message)"
        Write-Warning "Rollback aus Snapshot: $($snap.Path)"
        try {
            Write-RestorableRegistry -Restorable $snap.Payload.restorable | Out-Null
            Write-Host 'Rollback abgeschlossen.'
        }
        catch {
            throw "Rollback fehlgeschlagen. Manuell wiederherstellen mit: .\hwid.ps1 restore `"$($snap.Path)`" — Originalfehler: $($_.Exception.Message)"
        }
        throw "Restore abgebrochen und Rollback ausgeführt. Details: $($_.Exception.Message)"
    }
}
