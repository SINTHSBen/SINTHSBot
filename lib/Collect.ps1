#Requires -Version 5.1
<#
.SYNOPSIS
    Collect Windows identity for original-HWID backup (Nebel-aware).

.NOTES
    Captures what Nebel Spoofer targets so you can restore AFTER a spoof:
      - Registry software IDs
      - NetworkAddress overrides (registry MAC spoof)
      - SMBIOS serials / UUID (for AMIDEWIN original restore script)
      - Hardware MAC fingerprints + disk serials (verify / info)
    Schema version 2.
#>

Set-StrictMode -Version Latest

$script:HwidSchemaVersion = 2
$script:NetClassPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}'

function Get-RegistryStringValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Name
    )

    try {
        if (-not (Test-Path -LiteralPath $Path)) {
            return $null
        }
        $item = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop
        $value = $item.$Name
        if ($null -eq $value) {
            return $null
        }
        return [string]$value
    }
    catch {
        return $null
    }
}

function Get-CimString {
    param(
        [Parameter(Mandatory)][string]$ClassName,
        [Parameter(Mandatory)][string]$PropertyName
    )
    try {
        $obj = Get-CimInstance -ClassName $ClassName -ErrorAction Stop | Select-Object -First 1
        if ($null -eq $obj) { return $null }
        $val = $obj.$PropertyName
        if ($null -eq $val) { return $null }
        $s = ([string]$val).Trim()
        if ([string]::IsNullOrWhiteSpace($s)) { return $null }
        return $s
    }
    catch {
        return $null
    }
}

function Get-NetworkAddressOverrides {
    [CmdletBinding()]
    param()

    $overrides = @()
    if (-not (Test-Path -LiteralPath $script:NetClassPath)) {
        return @($overrides)
    }

    try {
        $subkeys = Get-ChildItem -LiteralPath $script:NetClassPath -ErrorAction Stop |
            Where-Object { $_.PSChildName -match '^\d{4}$' }

        foreach ($key in @($subkeys)) {
            try {
                $props = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop
                $instanceId = $null
                if ($props.PSObject.Properties.Name -contains 'NetCfgInstanceId') {
                    $instanceId = [string]$props.NetCfgInstanceId
                }
                if ([string]::IsNullOrWhiteSpace($instanceId)) {
                    continue
                }

                $networkAddress = $null
                if ($props.PSObject.Properties.Name -contains 'NetworkAddress') {
                    $raw = $props.NetworkAddress
                    if ($null -ne $raw -and -not [string]::IsNullOrWhiteSpace([string]$raw)) {
                        $networkAddress = ([string]$raw).Trim()
                    }
                }

                $overrides += [ordered]@{
                    adapterId      = $instanceId
                    networkAddress = $networkAddress
                    driverDesc     = $(if ($props.PSObject.Properties.Name -contains 'DriverDesc') { [string]$props.DriverDesc } else { $null })
                }
            }
            catch { }
        }
    }
    catch { }

    return @($overrides)
}

function Get-RegistryRestorable {
    [CmdletBinding()]
    param()

    return [ordered]@{
        machineGuid        = Get-RegistryStringValue -Path 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name 'MachineGuid'
        hwProfileGuid      = Get-RegistryStringValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\IDConfigDB\Hardware Profiles\0001' -Name 'HwProfileGuid'
        sqmMachineId       = Get-RegistryStringValue -Path 'HKLM:\SOFTWARE\Microsoft\SQMClient' -Name 'MachineId'
        susClientId        = Get-RegistryStringValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate' -Name 'SusClientId'
        computerHardwareId = Get-RegistryStringValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SystemInformation' -Name 'ComputerHardwareId'
    }
}

function Get-SmbiosOriginal {
    [CmdletBinding()]
    param()

    # Fields Nebel Permanent Spoof overwrites via AMIDEWIN (/SU /BS /CS /SS /BT)
    $systemUuid = Get-CimString -ClassName 'Win32_ComputerSystemProduct' -PropertyName 'UUID'
    $systemSerial = Get-CimString -ClassName 'Win32_ComputerSystemProduct' -PropertyName 'IdentifyingNumber'
    if (-not $systemSerial) {
        $systemSerial = Get-CimString -ClassName 'Win32_BIOS' -PropertyName 'SerialNumber'
    }

    $baseBoardSerial = Get-CimString -ClassName 'Win32_BaseBoard' -PropertyName 'SerialNumber'
    $baseBoardProduct = Get-CimString -ClassName 'Win32_BaseBoard' -PropertyName 'Product'
    $baseBoardManufacturer = Get-CimString -ClassName 'Win32_BaseBoard' -PropertyName 'Manufacturer'
    $baseBoardTag = Get-CimString -ClassName 'Win32_BaseBoard' -PropertyName 'Tag'

    $chassisSerial = Get-CimString -ClassName 'Win32_SystemEnclosure' -PropertyName 'SerialNumber'
    $biosSerial = Get-CimString -ClassName 'Win32_BIOS' -PropertyName 'SerialNumber'
    $biosVendor = Get-CimString -ClassName 'Win32_BIOS' -PropertyName 'Manufacturer'
    $biosVersion = Get-CimString -ClassName 'Win32_BIOS' -PropertyName 'SMBIOSBIOSVersion'

    $regBios = [ordered]@{
        SystemManufacturer    = Get-RegistryStringValue -Path 'HKLM:\HARDWARE\DESCRIPTION\System\BIOS' -Name 'SystemManufacturer'
        SystemProductName     = Get-RegistryStringValue -Path 'HKLM:\HARDWARE\DESCRIPTION\System\BIOS' -Name 'SystemProductName'
        SystemSerialNumber    = Get-RegistryStringValue -Path 'HKLM:\HARDWARE\DESCRIPTION\System\BIOS' -Name 'SystemSerialNumber'
        BaseBoardManufacturer = Get-RegistryStringValue -Path 'HKLM:\HARDWARE\DESCRIPTION\System\BIOS' -Name 'BaseBoardManufacturer'
        BaseBoardProduct      = Get-RegistryStringValue -Path 'HKLM:\HARDWARE\DESCRIPTION\System\BIOS' -Name 'BaseBoardProduct'
        BaseBoardVersion      = Get-RegistryStringValue -Path 'HKLM:\HARDWARE\DESCRIPTION\System\BIOS' -Name 'BaseBoardVersion'
        BIOSVendor            = Get-RegistryStringValue -Path 'HKLM:\HARDWARE\DESCRIPTION\System\BIOS' -Name 'BIOSVendor'
        BIOSVersion           = Get-RegistryStringValue -Path 'HKLM:\HARDWARE\DESCRIPTION\System\BIOS' -Name 'BIOSVersion'
    }

    return [ordered]@{
        systemUuid            = $systemUuid
        systemSerial          = $systemSerial
        baseBoardSerial       = $baseBoardSerial
        baseBoardProduct      = $baseBoardProduct
        baseBoardManufacturer = $baseBoardManufacturer
        baseBoardTag          = $baseBoardTag
        chassisSerial         = $chassisSerial
        biosSerial            = $biosSerial
        biosVendor            = $biosVendor
        biosVersion           = $biosVersion
        registryBios          = $regBios
    }
}

function Get-InfoOnlyHwid {
    [CmdletBinding()]
    param()

    $diskSerials = @()
    $macAddresses = @()
    $windowsBuild = $null
    $osCaption = $null

    try {
        $disks = Get-CimInstance -ClassName Win32_DiskDrive -ErrorAction Stop
        foreach ($disk in @($disks)) {
            if ($disk.SerialNumber) {
                $serial = ([string]$disk.SerialNumber).Trim()
                if ($serial) { $diskSerials += $serial }
            }
        }
    }
    catch { }

    try {
        $nics = Get-CimInstance -ClassName Win32_NetworkAdapter -ErrorAction Stop |
            Where-Object { $_.MACAddress -and $_.PhysicalAdapter }
        foreach ($nic in @($nics)) {
            $mac = [string]$nic.MACAddress
            if ($mac -and ($macAddresses -notcontains $mac)) {
                $macAddresses += $mac
            }
        }
    }
    catch { }

    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop | Select-Object -First 1
        if ($os) {
            $windowsBuild = [string]$os.BuildNumber
            $osCaption = [string]$os.Caption
        }
    }
    catch { }

    return [ordered]@{
        computerName = $env:COMPUTERNAME
        diskSerials  = @($diskSerials)
        macAddresses = @($macAddresses)
        windowsBuild = $windowsBuild
        osCaption    = $osCaption
        notes        = @(
            'Backup BEFORE Nebel Permanent Spoof / Kernel MAC / MACX.',
            'SMBIOS fields are restored via generate-amide-restore (AMIDEWIN), not via safe restore.',
            'EEPROM MAC (MACX) is NOT auto-restored — keep original MACs from infoOnly.macAddresses.'
        )
    }
}

function New-HwidBackupObject {
    [CmdletBinding()]
    param()

    $registry = Get-RegistryRestorable
    $network = @(Get-NetworkAddressOverrides)
    $smbios = Get-SmbiosOriginal
    $info = Get-InfoOnlyHwid

    return [ordered]@{
        schemaVersion = $script:HwidSchemaVersion
        createdAt     = (Get-Date).ToString('o')
        hostname      = $env:COMPUTERNAME
        purpose       = 'original-identity-backup-before-spoof'
        nebelTargets  = @(
            'AMIDEWIN SMBIOS UUID/BS/CS/SS/BT',
            'NetworkAddress registry MAC',
            'MACX EEPROM MAC',
            'NdisMacChanger kernel MAC'
        )
        restorable    = [ordered]@{
            machineGuid             = $registry.machineGuid
            hwProfileGuid           = $registry.hwProfileGuid
            sqmMachineId            = $registry.sqmMachineId
            susClientId             = $registry.susClientId
            computerHardwareId      = $registry.computerHardwareId
            networkAddressOverrides = $network
        }
        smbios        = $smbios
        infoOnly      = $info
    }
}

function Save-HwidBackup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$BackupDirectory,

        [string]$Prefix = 'hwid'
    )

    if (-not (Test-Path -LiteralPath $BackupDirectory)) {
        New-Item -ItemType Directory -Path $BackupDirectory -Force | Out-Null
    }

    $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHHmmssZ')
    $fileName = '{0}-{1}.json' -f $Prefix, $stamp
    $path = Join-Path -Path $BackupDirectory -ChildPath $fileName

    $payload = New-HwidBackupObject
    $json = $payload | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($path, $json)

    return [pscustomobject]@{
        Path    = $path
        Payload = $payload
    }
}

function Read-HwidBackupFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Backup-Datei nicht gefunden: $Path"
    }

    $raw = [System.IO.File]::ReadAllText($Path)
    return ($raw | ConvertFrom-Json)
}
