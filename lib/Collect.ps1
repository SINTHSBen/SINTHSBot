#Requires -Version 5.1
<#
.SYNOPSIS
    Collect Windows HWID identifiers (restorable registry + info-only CIM data).
#>

Set-StrictMode -Version Latest

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

function Get-RestorableHwid {
    [CmdletBinding()]
    param()

    $machineGuid = Get-RegistryStringValue -Path 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name 'MachineGuid'
    $hwProfileGuid = Get-RegistryStringValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\IDConfigDB\Hardware Profiles\0001' -Name 'HwProfileGuid'
    $sqmMachineId = Get-RegistryStringValue -Path 'HKLM:\SOFTWARE\Microsoft\SQMClient' -Name 'MachineId'

    return [ordered]@{
        machineGuid   = $machineGuid
        hwProfileGuid = $hwProfileGuid
        sqmMachineId  = $sqmMachineId
    }
}

function Get-InfoOnlyHwid {
    [CmdletBinding()]
    param()

    $biosUuid = $null
    $baseBoardSerial = $null
    $diskSerials = @()
    $macAddresses = @()
    $windowsBuild = $null
    $osCaption = $null

    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystemProduct -ErrorAction Stop
        if ($cs -and $cs.UUID) {
            $biosUuid = [string]$cs.UUID
        }
    }
    catch { }

    try {
        $board = Get-CimInstance -ClassName Win32_BaseBoard -ErrorAction Stop | Select-Object -First 1
        if ($board -and $board.SerialNumber) {
            $baseBoardSerial = [string]$board.SerialNumber
        }
    }
    catch { }

    try {
        $disks = Get-CimInstance -ClassName Win32_DiskDrive -ErrorAction Stop
        foreach ($disk in @($disks)) {
            if ($disk.SerialNumber) {
                $serial = ([string]$disk.SerialNumber).Trim()
                if ($serial) {
                    $diskSerials += $serial
                }
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
        computerName     = $env:COMPUTERNAME
        biosUuid         = $biosUuid
        baseBoardSerial  = $baseBoardSerial
        diskSerials      = @($diskSerials)
        macAddresses     = @($macAddresses)
        windowsBuild     = $windowsBuild
        osCaption        = $osCaption
    }
}

function New-HwidBackupObject {
    [CmdletBinding()]
    param()

    $createdAt = (Get-Date).ToString('o')

    return [ordered]@{
        schemaVersion = 1
        createdAt     = $createdAt
        hostname      = $env:COMPUTERNAME
        restorable    = Get-RestorableHwid
        infoOnly      = Get-InfoOnlyHwid
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
    $json = $payload | ConvertTo-Json -Depth 6
    # UTF8 without BOM for broad tooling compatibility
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
    $obj = $raw | ConvertFrom-Json
    return $obj
}
