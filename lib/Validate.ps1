#Requires -Version 5.1
<#
.SYNOPSIS
    Schema/GUID validation, diffs, and verify helpers for HWID backups.
#>

Set-StrictMode -Version Latest

$script:GuidLoosePattern = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
$script:GuidBracedPattern = '^\{[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}$'

function Test-IsGuidString {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Value,

        [ValidateSet('Loose', 'Braced', 'Either')]
        [string]$Style = 'Either'
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }

    switch ($Style) {
        'Loose'  { return [bool]($Value -match $script:GuidLoosePattern) }
        'Braced' { return [bool]($Value -match $script:GuidBracedPattern) }
        default  {
            return [bool](
                ($Value -match $script:GuidLoosePattern) -or
                ($Value -match $script:GuidBracedPattern)
            )
        }
    }
}

function Get-RestorablePropertyNames {
    # Scalar registry fields compared/restored by safe restore
    return @('machineGuid', 'hwProfileGuid', 'sqmMachineId', 'susClientId', 'computerHardwareId')
}

function Get-GuidRestorablePropertyNames {
    return @('machineGuid', 'hwProfileGuid', 'sqmMachineId', 'susClientId')
}

function ConvertTo-HwidHashtable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $InputObject
    )

    if ($InputObject -is [hashtable] -or $InputObject -is [System.Collections.Specialized.OrderedDictionary]) {
        return $InputObject
    }

    $hash = [ordered]@{}
    foreach ($prop in $InputObject.PSObject.Properties) {
        $hash[$prop.Name] = $prop.Value
    }
    return $hash
}

function Test-HwidBackupObject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        $Backup
    )

    $errors = New-Object System.Collections.Generic.List[string]

    if ($null -eq $Backup) {
        $errors.Add('Backup-Objekt ist null.')
        return [pscustomobject]@{
            IsValid = $false
            Errors  = @($errors)
        }
    }

    $map = ConvertTo-HwidHashtable -InputObject $Backup

    if (-not $map.Contains('schemaVersion')) {
        $errors.Add('Feld schemaVersion fehlt.')
    }
    else {
        $ver = [int]$map.schemaVersion
        if ($ver -lt 1 -or $ver -gt 2) {
            $errors.Add("Nicht unterstützte schemaVersion: $($map.schemaVersion) (erwartet: 1 oder 2).")
        }
    }

    if (-not $map.Contains('restorable') -or $null -eq $map.restorable) {
        $errors.Add('Feld restorable fehlt.')
        return [pscustomobject]@{
            IsValid = $false
            Errors  = @($errors)
        }
    }

    $restorable = ConvertTo-HwidHashtable -InputObject $map.restorable
    $hasAny = $false

    foreach ($name in Get-RestorablePropertyNames) {
        if (-not $restorable.Contains($name)) {
            continue
        }
        $value = $restorable[$name]
        if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)) {
            continue
        }

        $hasAny = $true
        if ((Get-GuidRestorablePropertyNames) -contains $name) {
            if (-not (Test-IsGuidString -Value ([string]$value) -Style Either)) {
                $errors.Add("restorable.$name ist keine gültige GUID: '$value'")
            }
        }
    }

    # Schema v2: SMBIOS original block is recommended but optional for v1 backups
    if ($map.Contains('schemaVersion') -and [int]$map.schemaVersion -ge 2) {
        if (-not $map.Contains('smbios') -or $null -eq $map.smbios) {
            $errors.Add('schemaVersion 2 erwartet Feld smbios (Original-Serials für AMIDEWIN-Restore).')
        }
        else {
            $smbios = ConvertTo-HwidHashtable -InputObject $map.smbios
            $smbiosAny = $false
            foreach ($k in @('systemUuid', 'baseBoardSerial', 'chassisSerial', 'systemSerial')) {
                if ($smbios.Contains($k) -and $smbios[$k] -and -not [string]::IsNullOrWhiteSpace([string]$smbios[$k])) {
                    $smbiosAny = $true
                    break
                }
            }
            if (-not $smbiosAny) {
                $errors.Add('smbios enthält keine Original-Serials/UUID.')
            }
            if ($smbios.Contains('systemUuid') -and $smbios.systemUuid -and -not (Test-IsGuidString -Value ([string]$smbios.systemUuid))) {
                $errors.Add("smbios.systemUuid ist keine gültige GUID: '$($smbios.systemUuid)'")
            }
        }
    }

    if (-not $hasAny -and -not ($map.Contains('smbios') -and $map.smbios)) {
        $errors.Add('restorable enthält keine wiederherstellbaren Werte.')
    }
    elseif (-not $hasAny) {
        # SMBIOS-only backup still useful for amide restore
        $hasAny = $true
    }

    if (-not $hasAny) {
        $errors.Add('Backup enthält keine wiederherstellbaren Werte.')
    }

    return [pscustomobject]@{
        IsValid = ($errors.Count -eq 0)
        Errors  = @($errors)
    }
}

function Get-RestorableMap {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Backup
    )

    $map = ConvertTo-HwidHashtable -InputObject $Backup
    if (-not $map.Contains('restorable') -or $null -eq $map.restorable) {
        return [ordered]@{}
    }
    return ConvertTo-HwidHashtable -InputObject $map.restorable
}

function Resolve-RestorableMap {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $InputObject
    )

    $map = ConvertTo-HwidHashtable -InputObject $InputObject
    if ($map.Contains('restorable')) {
        return Get-RestorableMap -Backup $InputObject
    }
    return $map
}

function Compare-RestorableHwid {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Current,

        [Parameter(Mandatory)]
        $Target
    )

    $currentMap = Resolve-RestorableMap -InputObject $Current
    $targetMap = Resolve-RestorableMap -InputObject $Target

    $rows = @()
    foreach ($name in Get-RestorablePropertyNames) {
        $before = $null
        $after = $null
        if ($currentMap.Contains($name)) { $before = $currentMap[$name] }
        if ($targetMap.Contains($name)) { $after = $targetMap[$name] }

        $beforeStr = if ($null -eq $before -or [string]::IsNullOrWhiteSpace([string]$before)) { '<fehlt>' } else { [string]$before }
        $afterStr = if ($null -eq $after -or [string]::IsNullOrWhiteSpace([string]$after)) { '<fehlt / skip>' } else { [string]$after }

        $changed = $false
        if ($afterStr -ne '<fehlt / skip>' -and $beforeStr -ne $afterStr) {
            $changed = $true
        }

        $rows += [pscustomobject]@{
            Name      = $name
            Current   = $beforeStr
            Target    = $afterStr
            Changed   = $changed
            WillWrite = ($afterStr -ne '<fehlt / skip>')
        }
    }

    return $rows
}

function Format-HwidDiff {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$DiffRows
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('Diff (restorable registry):')
    $lines.Add(('{0,-20} {1,-40} {2,-40} {3}' -f 'Feld', 'Aktuell', 'Ziel', 'Aktion'))
    $lines.Add(('-' * 120))

    foreach ($row in $DiffRows) {
        $action = if (-not $row.WillWrite) {
            'SKIP'
        }
        elseif ($row.Changed) {
            'WRITE'
        }
        else {
            'OK'
        }
        $lines.Add(('{0,-20} {1,-40} {2,-40} {3}' -f $row.Name, $row.Current, $row.Target, $action))
    }

    return ($lines -join [Environment]::NewLine)
}

function Compare-SmbiosToBackup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$CurrentBackup,
        [Parameter(Mandatory)]$TargetBackup
    )

    $fields = @('systemUuid', 'systemSerial', 'baseBoardSerial', 'chassisSerial', 'biosSerial')
    $curMap = if ($CurrentBackup.smbios) { ConvertTo-HwidHashtable -InputObject $CurrentBackup.smbios } else { [ordered]@{} }
    $tgtMap = if ($TargetBackup.smbios) { ConvertTo-HwidHashtable -InputObject $TargetBackup.smbios } else { [ordered]@{} }

    $rows = @()
    foreach ($name in $fields) {
        $c = if ($curMap.Contains($name) -and $curMap[$name]) { [string]$curMap[$name] } else { '<fehlt>' }
        $t = if ($tgtMap.Contains($name) -and $tgtMap[$name]) { [string]$tgtMap[$name] } else { '<fehlt>' }
        $rows += [pscustomobject]@{
            Name    = $name
            Current = $c
            Backup  = $t
            Match   = ($c -eq $t)
        }
    }
    return $rows
}

function Format-SmbiosVerify {
    param([object[]]$Rows)
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('Verify SMBIOS (Nebel Permanent Spoof targets):')
    $lines.Add(('{0,-18} {1,-36} {2,-36} {3}' -f 'Feld', 'Aktuell', 'Backup-Original', 'Status'))
    $lines.Add(('-' * 110))
    foreach ($r in $Rows) {
        $status = if ($r.Match) { 'OK' } else { 'MISMATCH' }
        $lines.Add(('{0,-18} {1,-36} {2,-36} {3}' -f $r.Name, $r.Current, $r.Backup, $status))
    }
    return ($lines -join [Environment]::NewLine)
}
