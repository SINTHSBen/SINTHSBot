#Requires -Version 5.1
<#
.SYNOPSIS
    Schema/GUID validation and restorable-field diff for HWID backups.
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
    return @('machineGuid', 'hwProfileGuid', 'sqmMachineId')
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
    elseif ([int]$map.schemaVersion -ne 1) {
        $errors.Add("Nicht unterstützte schemaVersion: $($map.schemaVersion) (erwartet: 1).")
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
        # MachineGuid / SQM MachineId are typically unbraced; HwProfileGuid is often braced.
        # Accept either form for all restorable fields.
        if (-not (Test-IsGuidString -Value ([string]$value) -Style Either)) {
            $errors.Add("restorable.$name ist keine gültige GUID: '$value'")
        }
    }

    if (-not $hasAny) {
        $errors.Add('restorable enthält keine wiederherstellbaren Werte.')
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

    # Works for PSCustomObject (ConvertFrom-Json) and OrderedDictionary/hashtable backups.
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
        if ($afterStr -eq '<fehlt / skip>') {
            $changed = $false
        }
        elseif ($beforeStr -ne $afterStr) {
            $changed = $true
        }

        $rows += [pscustomobject]@{
            Name    = $name
            Current = $beforeStr
            Target  = $afterStr
            Changed = $changed
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
    $lines.Add('Diff (restorable):')
    $lines.Add(('{0,-16} {1,-40} {2,-40} {3}' -f 'Feld', 'Aktuell', 'Ziel', 'Aktion'))
    $lines.Add(('-' * 110))

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
        $lines.Add(('{0,-16} {1,-40} {2,-40} {3}' -f $row.Name, $row.Current, $row.Target, $action))
    }

    return ($lines -join [Environment]::NewLine)
}
