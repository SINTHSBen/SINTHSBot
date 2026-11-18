#Requires -Version 5.1
<#
.SYNOPSIS
    Safe restore + AMIDEWIN original-restore script generation (Nebel-aware).

.NOTES
    Safe restore writes registry IDs and restores/clears NetworkAddress overrides.
    Firmware SMBIOS is NEVER auto-flashed. Use New-AmideOriginalRestoreScript.
#>

Set-StrictMode -Version Latest

$script:NetClassPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}'

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
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Value
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
        [Parameter(Mandatory)]$Restorable
    )

    $map = ConvertTo-HwidHashtable -InputObject $Restorable
    $written = New-Object System.Collections.Generic.List[string]
    $skipped = New-Object System.Collections.Generic.List[string]

    $targets = @(
        [pscustomobject]@{ Name = 'machineGuid'; Path = 'HKLM:\SOFTWARE\Microsoft\Cryptography'; RegName = 'MachineGuid'; Guid = $true }
        [pscustomobject]@{ Name = 'hwProfileGuid'; Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\IDConfigDB\Hardware Profiles\0001'; RegName = 'HwProfileGuid'; Guid = $true }
        [pscustomobject]@{ Name = 'sqmMachineId'; Path = 'HKLM:\SOFTWARE\Microsoft\SQMClient'; RegName = 'MachineId'; Guid = $true }
        [pscustomobject]@{ Name = 'susClientId'; Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate'; RegName = 'SusClientId'; Guid = $true }
        [pscustomobject]@{ Name = 'computerHardwareId'; Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\SystemInformation'; RegName = 'ComputerHardwareId'; Guid = $false }
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

        if ($t.Guid -and -not (Test-IsGuidString -Value ([string]$value))) {
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

function Restore-NetworkAddressOverrides {
    [CmdletBinding()]
    param(
        $Overrides
    )

    $cleared = 0
    $set = 0

    if (-not (Test-Path -LiteralPath $script:NetClassPath)) {
        return [pscustomobject]@{ Cleared = 0; Set = 0 }
    }

    # Build map adapterId -> desired NetworkAddress (null means remove override = hardware MAC)
    $desired = @{}
    foreach ($item in @($Overrides)) {
        if ($null -eq $item) { continue }
        $h = ConvertTo-HwidHashtable -InputObject $item
        if (-not $h.Contains('adapterId') -or [string]::IsNullOrWhiteSpace([string]$h.adapterId)) {
            continue
        }
        $addr = $null
        if ($h.Contains('networkAddress') -and $h.networkAddress -and -not [string]::IsNullOrWhiteSpace([string]$h.networkAddress)) {
            $addr = [string]$h.networkAddress
        }
        $desired[[string]$h.adapterId] = $addr
    }

    $subkeys = Get-ChildItem -LiteralPath $script:NetClassPath -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -match '^\d{4}$' }

    foreach ($key in @($subkeys)) {
        try {
            $props = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop
            if (-not ($props.PSObject.Properties.Name -contains 'NetCfgInstanceId')) {
                continue
            }
            $id = [string]$props.NetCfgInstanceId
            if ([string]::IsNullOrWhiteSpace($id)) { continue }

            $hasOverride = ($props.PSObject.Properties.Name -contains 'NetworkAddress') -and
                $null -ne $props.NetworkAddress -and
                -not [string]::IsNullOrWhiteSpace([string]$props.NetworkAddress)

            if ($desired.ContainsKey($id)) {
                $want = $desired[$id]
                if ($null -eq $want) {
                    if ($hasOverride) {
                        Remove-ItemProperty -LiteralPath $key.PSPath -Name 'NetworkAddress' -ErrorAction SilentlyContinue
                        $cleared++
                    }
                }
                else {
                    Set-ItemProperty -LiteralPath $key.PSPath -Name 'NetworkAddress' -Value $want -Force
                    $set++
                }
            }
            else {
                # Adapter not in backup: clear spoof override to return toward hardware MAC
                if ($hasOverride) {
                    Remove-ItemProperty -LiteralPath $key.PSPath -Name 'NetworkAddress' -ErrorAction SilentlyContinue
                    $cleared++
                }
            }
        }
        catch { }
    }

    return [pscustomobject]@{ Cleared = $cleared; Set = $set }
}

function Invoke-HwidRestore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BackupPath,
        [Parameter(Mandatory)][string]$BackupDirectory,
        [switch]$Force
    )

    if (-not (Test-IsAdministrator)) {
        throw 'Restore benötigt Administrator-Rechte. PowerShell als Administrator neu starten und erneut ausführen.'
    }

    $backup = Read-HwidBackupFile -Path $BackupPath
    $validation = Test-HwidBackupObject -Backup $backup
    if (-not $validation.IsValid) {
        throw ("Backup ungültig: {0}" -f ($validation.Errors -join '; '))
    }

    $current = New-HwidBackupObject
    $diff = Compare-RestorableHwid -Current $current -Target $backup
    Write-Host (Format-HwidDiff -DiffRows $diff)
    Write-Host ''

    if ($backup.smbios) {
        $smb = Compare-SmbiosToBackup -CurrentBackup $current -TargetBackup $backup
        Write-Host (Format-SmbiosVerify -Rows $smb)
        $mismatched = @($smb | Where-Object { -not $_.Match })
        if ($mismatched.Count -gt 0) {
            Write-Warning 'SMBIOS weicht vom Original-Backup ab (typisch nach Nebel Permanent Spoof).'
            Write-Warning 'Safe restore ändert KEINE UEFI-Serials. Danach: .\hwid.ps1 generate-amide-restore <backup>'
        }
        Write-Host ''
    }

    if (-not (Test-Path -LiteralPath $BackupDirectory)) {
        New-Item -ItemType Directory -Path $BackupDirectory -Force | Out-Null
    }
    $snap = Save-HwidBackup -BackupDirectory $BackupDirectory -Prefix 'pre-restore'
    Write-Host "Pre-Restore-Snapshot gespeichert: $($snap.Path)"

    $willWrite = @($diff | Where-Object { $_.WillWrite -and $_.Changed })
    $hasNetworkPlan = $true  # always reconcile NetworkAddress against backup

    if ($willWrite.Count -eq 0) {
        Write-Host 'Keine Registry-ID-Änderungen -- NetworkAddress wird trotzdem an Backup angeglichen.'
    }

    if (-not $Force) {
        Write-Host 'Safe restore schreibt:'
        Write-Host '  - Registry: MachineGuid, HwProfileGuid, SQM MachineId, SusClientId, ComputerHardwareId'
        Write-Host '  - NetworkAddress Overrides (Registry-MAC) gemäß Backup / clear → Hardware-MAC'
        Write-Host 'NICHT geschrieben: UEFI/SMBIOS (AMIDEWIN), EEPROM-MAC (MACX), TPM/BIOS-Flash.'
        $answer = Read-Host 'Safe restore fortsetzen? Tippe YES zum Bestätigen'
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
        $netResult = Restore-NetworkAddressOverrides -Overrides $backup.restorable.networkAddressOverrides

        Write-Host ''
        Write-Host "Registry geschrieben: $($result.Written -join ', ')"
        if ($result.Skipped.Count -gt 0) {
            Write-Host "Registry übersprungen: $($result.Skipped -join ', ')"
        }
        Write-Host ("NetworkAddress: {0} entfernt, {1} gesetzt" -f $netResult.Cleared, $netResult.Set)
        Write-Host 'Neustart empfohlen (kein Auto-Reboot).'
        Write-Host "Rollback-Snapshot: .\hwid.ps1 restore `"$($snap.Path)`""
        Write-Host 'Für Original-UEFI-Serials: .\hwid.ps1 generate-amide-restore <dieses-backup>'

        return [pscustomobject]@{
            Status       = 'Success'
            SnapshotPath = $snap.Path
            BackupPath   = $BackupPath
            Written      = $result.Written
            Skipped      = $result.Skipped
            Network      = $netResult
        }
    }
    catch {
        Write-Error "Restore fehlgeschlagen: $($_.Exception.Message)"
        Write-Warning "Rollback aus Snapshot: $($snap.Path)"
        try {
            Write-RestorableRegistry -Restorable $snap.Payload.restorable | Out-Null
            Restore-NetworkAddressOverrides -Overrides $snap.Payload.restorable.networkAddressOverrides | Out-Null
            Write-Host 'Rollback abgeschlossen.'
        }
        catch {
            throw "Rollback fehlgeschlagen. Manuell: .\hwid.ps1 restore `"$($snap.Path)`" -- $($_.Exception.Message)"
        }
        throw "Restore abgebrochen und Rollback ausgeführt. Details: $($_.Exception.Message)"
    }
}

function Invoke-HwidVerify {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BackupPath
    )

    $backup = Read-HwidBackupFile -Path $BackupPath
    $validation = Test-HwidBackupObject -Backup $backup
    if (-not $validation.IsValid) {
        throw ("Backup ungültig: {0}" -f ($validation.Errors -join '; '))
    }

    $current = New-HwidBackupObject
    $diff = Compare-RestorableHwid -Current $current -Target $backup
    Write-Host (Format-HwidDiff -DiffRows $diff)
    Write-Host ''

    if ($backup.smbios) {
        Write-Host (Format-SmbiosVerify -Rows (Compare-SmbiosToBackup -CurrentBackup $current -TargetBackup $backup))
        Write-Host ''
    }

    $curMacs = @()
    if ($current.infoOnly -and $current.infoOnly.macAddresses) {
        $curMacs = @($current.infoOnly.macAddresses)
    }
    $bakMacs = @()
    if ($backup.infoOnly -and $backup.infoOnly.macAddresses) {
        $bakMacs = @($backup.infoOnly.macAddresses)
    }
    Write-Host 'MAC fingerprints (infoOnly -- EEPROM/Kernel spoofs zeigen sich hier):'
    Write-Host ("  aktuell: {0}" -f ($(if ($curMacs.Count) { $curMacs -join ', ' } else { '<keine>' })))
    Write-Host ("  backup:  {0}" -f ($(if ($bakMacs.Count) { $bakMacs -join ', ' } else { '<keine>' })))

    $regMismatch = @($diff | Where-Object { $_.WillWrite -and $_.Changed }).Count
    $smbMismatch = 0
    if ($backup.smbios) {
        $smbMismatch = @(Compare-SmbiosToBackup -CurrentBackup $current -TargetBackup $backup | Where-Object { -not $_.Match }).Count
    }

    if ($regMismatch -eq 0 -and $smbMismatch -eq 0 -and (($curMacs -join ',') -eq ($bakMacs -join ','))) {
        Write-Host ''
        Write-Host 'Verify: aktueller Stand entspricht dem Original-Backup.'
        return [pscustomobject]@{ Status = 'Match' }
    }

    Write-Host ''
    Write-Host 'Verify: Abweichungen gefunden -- typisch nach Spoof. Safe restore + ggf. generate-amide-restore nutzen.'
    return [pscustomobject]@{ Status = 'Mismatch'; Registry = $regMismatch; Smbios = $smbMismatch }
}

function New-AmideOriginalRestoreScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BackupPath,
        [Parameter(Mandatory)][string]$OutputDirectory
    )

    $backup = Read-HwidBackupFile -Path $BackupPath
    $validation = Test-HwidBackupObject -Backup $backup
    if (-not $validation.IsValid) {
        throw ("Backup ungültig: {0}" -f ($validation.Errors -join '; '))
    }
    if (-not $backup.smbios) {
        throw 'Backup enthält kein smbios-Feld. Bitte neues Backup mit .\hwid.ps1 backup erzeugen (schema v2).'
    }

    $smbios = ConvertTo-HwidHashtable -InputObject $backup.smbios
    $uuid = if ($smbios.Contains('systemUuid')) { [string]$smbios.systemUuid } else { $null }
    $bs = if ($smbios.Contains('baseBoardSerial')) { [string]$smbios.baseBoardSerial } else { $null }
    $cs = if ($smbios.Contains('chassisSerial')) { [string]$smbios.chassisSerial } else { $null }
    $ss = if ($smbios.Contains('systemSerial')) { [string]$smbios.systemSerial } else { $null }
    $bt = if ($smbios.Contains('baseBoardTag') -and $smbios.baseBoardTag) {
        [string]$smbios.baseBoardTag
    }
    elseif ($smbios.Contains('biosSerial') -and $smbios.biosSerial) {
        [string]$smbios.biosSerial
    }
    else {
        'Default string'
    }

    if ([string]::IsNullOrWhiteSpace($bs) -and [string]::IsNullOrWhiteSpace($cs) -and [string]::IsNullOrWhiteSpace($ss) -and [string]::IsNullOrWhiteSpace($uuid)) {
        throw 'Keine SMBIOS-Originalwerte im Backup -- AMIDEWIN-Restore-Skript kann nicht erzeugt werden.'
    }

    if (-not (Test-Path -LiteralPath $OutputDirectory)) {
        New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    }

    $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHHmmssZ')
    $batPath = Join-Path $OutputDirectory ("restore-amide-original-$stamp.bat")
    $txtPath = Join-Path $OutputDirectory ("restore-amide-original-$stamp.txt")

    # Never use /SU auto here -- that would create a NEW uuid (spoof). Restore ORIGINAL uuid.
    $uuidArg = $null
    if ($uuid -and (Test-IsGuidString -Value $uuid)) {
        $uuidArg = $uuid.Trim('{}')
    }

    $cmdLines = New-Object System.Collections.Generic.List[string]
    if ($uuidArg) { $cmdLines.Add("AMIDEWINx64.EXE /SU $uuidArg") }
    if ($bs) { $cmdLines.Add("AMIDEWINx64.EXE /BS $bs") }
    if ($cs) { $cmdLines.Add("AMIDEWINx64.EXE /CS $cs") }
    if ($ss) { $cmdLines.Add("AMIDEWINx64.EXE /SS $ss") }
    if ($bt) { $cmdLines.Add("AMIDEWINx64.EXE /BT $bt") }

    $bat = @"
@echo off
title SINTHSBot AMIDEWIN ORIGINAL RESTORE
color 4F
cd /D "%~dp0"

echo ========================================================
echo   SINTHSBot - RESTORE ORIGINAL SMBIOS (NOT A SPOOF)
echo ========================================================
echo.
echo This writes the ORIGINAL serials from YOUR backup back
echo into UEFI via AMIDEWINx64.EXE (same tool Nebel uses).
echo.
echo WRONG values can brick firmware. Review the commands:
echo.

"@
    foreach ($c in $cmdLines) {
        $bat += "echo   $c" + [Environment]::NewLine
    }
    $bat += @"

echo.
echo Place AMIDEWINx64.EXE + drivers in THIS folder first.
echo.
set /p CONFIRM=Type RESTORE-ORIGINAL to continue: 
if /I not "%CONFIRM%"=="RESTORE-ORIGINAL" (
  echo Aborted.
  exit /b 1
)

"@
    foreach ($c in $cmdLines) {
        $bat += $c + [Environment]::NewLine
    }
    $bat += @"

echo.
echo Done. Reboot required. Then run: hwid.ps1 verify <backup.json>
pause
"@

    $txt = @"
SINTHSBot AMIDEWIN original restore
Created: $((Get-Date).ToString('o'))
Source backup: $BackupPath

Commands (ORIGINAL values only -- no randomization):
$($cmdLines -join "`r`n")

After running the .bat as Admin and rebooting:
  .\hwid.ps1 verify `"$BackupPath`"

EEPROM MAC (MACX) is NOT covered here. If Nebel/MACX changed NIC flash,
write back the MACs listed in the backup infoOnly.macAddresses using your NIC tool.
"@

    [System.IO.File]::WriteAllText($batPath, $bat)
    [System.IO.File]::WriteAllText($txtPath, $txt)

    Write-Host "AMIDEWIN Original-Restore-Skript: $batPath"
    Write-Host "Befehlsübersicht:                 $txtPath"
    Write-Host 'Kopiere AMIDEWINx64.EXE (+ .sys Treiber) in denselben Ordner, prüfe die Werte, dann als Admin ausführen.'
    Write-Host 'Kein Auto-Flash von hier aus -- absichtlich.'

    return [pscustomobject]@{
        BatPath = $batPath
        TxtPath = $txtPath
        Commands = @($cmdLines)
    }
}
