#Requires -Version 5.1
<#
.SYNOPSIS
    Fixture tests for lib/Validate.ps1 (no Windows registry required).

.EXAMPLE
    pwsh -File ./tests/Validate.Tests.ps1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot (Join-Path 'lib' 'Validate.ps1'))

$fixtureDir = Join-Path $PSScriptRoot 'fixtures'
$script:Passed = 0
$script:Failed = 0
$script:Failures = New-Object System.Collections.Generic.List[string]

function Assert-True {
    param(
        [string]$Name,
        [bool]$Condition,
        [string]$Detail = ''
    )
    if ($Condition) {
        $script:Passed++
        Write-Host "  PASS  $Name"
    }
    else {
        $script:Failed++
        $msg = if ($Detail) { "$Name — $Detail" } else { $Name }
        $script:Failures.Add($msg)
        Write-Host "  FAIL  $msg"
    }
}

function Assert-Equal {
    param(
        [string]$Name,
        $Expected,
        $Actual
    )
    $ok = [string]$Expected -eq [string]$Actual
    Assert-True -Name $Name -Condition $ok -Detail ("expected='$Expected' actual='$Actual'")
}

function Read-Fixture {
    param([string]$FileName)
    $path = Join-Path $fixtureDir $FileName
    $raw = [System.IO.File]::ReadAllText($path)
    return ($raw | ConvertFrom-Json)
}

Write-Host '=== Test-IsGuidString ==='

Assert-True 'loose GUID accepted' (Test-IsGuidString -Value 'a1b2c3d4-e5f6-7890-abcd-ef1234567890' -Style Loose)
Assert-True 'braced GUID accepted (Braced)' (Test-IsGuidString -Value '{a1b2c3d4-e5f6-7890-abcd-ef1234567890}' -Style Braced)
Assert-True 'braced GUID accepted (Either)' (Test-IsGuidString -Value '{a1b2c3d4-e5f6-7890-abcd-ef1234567890}' -Style Either)
Assert-True 'loose rejected as Braced' (-not (Test-IsGuidString -Value 'a1b2c3d4-e5f6-7890-abcd-ef1234567890' -Style Braced))
Assert-True 'braced rejected as Loose' (-not (Test-IsGuidString -Value '{a1b2c3d4-e5f6-7890-abcd-ef1234567890}' -Style Loose))
Assert-True 'null rejected' (-not (Test-IsGuidString -Value $null))
Assert-True 'empty rejected' (-not (Test-IsGuidString -Value ''))
Assert-True 'garbage rejected' (-not (Test-IsGuidString -Value 'not-a-guid'))
Assert-True 'short hex rejected' (-not (Test-IsGuidString -Value 'abcd-efgh'))
Assert-True 'uppercase loose accepted' (Test-IsGuidString -Value 'A1B2C3D4-E5F6-7890-ABCD-EF1234567890' -Style Loose)

Write-Host ''
Write-Host '=== Test-HwidBackupObject (fixtures) ==='

$validFull = Read-Fixture 'valid-full.json'
$validPartial = Read-Fixture 'valid-partial.json'
$invalidGuid = Read-Fixture 'invalid-bad-guid.json'
$invalidSchema = Read-Fixture 'invalid-schema.json'
$invalidEmpty = Read-Fixture 'invalid-empty-restorable.json'

$r1 = Test-HwidBackupObject -Backup $validFull
Assert-True 'valid-full IsValid (schema v2)' $r1.IsValid -Detail (($r1.Errors -join '; '))

$r2 = Test-HwidBackupObject -Backup $validPartial
Assert-True 'valid-partial IsValid (schema v1 only machineGuid)' $r2.IsValid -Detail (($r2.Errors -join '; '))

$r3 = Test-HwidBackupObject -Backup $invalidGuid
Assert-True 'invalid-bad-guid rejected' (-not $r3.IsValid)
Assert-True 'invalid-bad-guid mentions machineGuid' (
    [bool]($r3.Errors | Where-Object { $_ -match 'machineGuid' })
)

$r4 = Test-HwidBackupObject -Backup $invalidSchema
Assert-True 'invalid-schema rejected' (-not $r4.IsValid)
Assert-True 'invalid-schema mentions schemaVersion' (
    [bool]($r4.Errors | Where-Object { $_ -match 'schemaVersion' })
)

$r5 = Test-HwidBackupObject -Backup $invalidEmpty
Assert-True 'invalid-empty-restorable rejected' (-not $r5.IsValid)

$rNull = Test-HwidBackupObject -Backup $null
Assert-True 'null backup rejected' (-not $rNull.IsValid)

$missingRestorable = [pscustomobject]@{ schemaVersion = 1; hostname = 'x' }
$rMiss = Test-HwidBackupObject -Backup $missingRestorable
Assert-True 'missing restorable rejected' (-not $rMiss.IsValid)

Write-Host ''
Write-Host '=== Compare-RestorableHwid / Format-HwidDiff ==='

$current = [ordered]@{
    schemaVersion = 2
    restorable    = [ordered]@{
        machineGuid        = 'a1b2c3d4-e5f6-7890-abcd-ef1234567890'
        hwProfileGuid      = '{11111111-2222-3333-4444-555555555555}'
        sqmMachineId       = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
        susClientId        = 'd4e5f6a7-b8c9-0123-def0-234567890123'
        computerHardwareId = '{e5f6a7b8-c9d0-1234-ef01-345678901234}'
    }
}

$diff = Compare-RestorableHwid -Current $current -Target $validFull
$byName = @{}
foreach ($row in $diff) { $byName[$row.Name] = $row }

Assert-Equal 'diff row count' 5 $diff.Count
Assert-True 'machineGuid unchanged (OK)' (-not $byName['machineGuid'].Changed)
Assert-True 'machineGuid WillWrite' $byName['machineGuid'].WillWrite
Assert-True 'hwProfileGuid changed' $byName['hwProfileGuid'].Changed
Assert-True 'sqmMachineId changed' $byName['sqmMachineId'].Changed
Assert-True 'susClientId unchanged' (-not $byName['susClientId'].Changed)

$diffPartial = Compare-RestorableHwid -Current $current -Target $validPartial
$partialMap = @{}
foreach ($row in $diffPartial) { $partialMap[$row.Name] = $row }

Assert-True 'partial hwProfileGuid skipped' (-not $partialMap['hwProfileGuid'].WillWrite)
Assert-True 'partial sqmMachineId skipped' (-not $partialMap['sqmMachineId'].WillWrite)
Assert-True 'partial machineGuid WillWrite' $partialMap['machineGuid'].WillWrite

$flatCurrent = [ordered]@{
    machineGuid   = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
    hwProfileGuid = '{11111111-2222-3333-4444-555555555555}'
    sqmMachineId  = 'bbbbbbbb-cccc-dddd-eeee-ffffffffffff'
}
$flatTarget = [ordered]@{
    machineGuid   = 'cccccccc-dddd-eeee-ffff-000000000000'
    hwProfileGuid = '{11111111-2222-3333-4444-555555555555}'
    sqmMachineId  = $null
}
$flatDiff = Compare-RestorableHwid -Current $flatCurrent -Target $flatTarget
$flatBy = @{}
foreach ($row in $flatDiff) { $flatBy[$row.Name] = $row }
Assert-True 'flat machineGuid changed' $flatBy['machineGuid'].Changed
Assert-True 'flat hwProfileGuid unchanged' (-not $flatBy['hwProfileGuid'].Changed)
Assert-True 'flat sqmMachineId skip' (-not $flatBy['sqmMachineId'].WillWrite)

$formatted = Format-HwidDiff -DiffRows $diff
Assert-True 'diff header present' ($formatted -match 'Diff \(restorable registry\)')
Assert-True 'diff shows WRITE for hwProfileGuid' ($formatted -match 'hwProfileGuid\s+.+\s+WRITE')
Assert-True 'diff shows OK for machineGuid' ($formatted -match 'machineGuid\s+.+\s+OK')

$formattedPartial = Format-HwidDiff -DiffRows $diffPartial
Assert-True 'diff shows SKIP for missing fields' ($formattedPartial -match 'SKIP')

Write-Host ''
Write-Host '=== Compare-SmbiosToBackup ==='
$curSmb = [pscustomobject]@{
    smbios = [ordered]@{
        systemUuid      = '11111111-2222-3333-4444-555555555555'
        systemSerial    = 'CHANGED'
        baseBoardSerial = '07D36RE_NB341CYCBD'
        chassisSerial   = '651012'
        biosSerial      = 'To be filled by O.E.M.'
    }
}
$smbRows = Compare-SmbiosToBackup -CurrentBackup $curSmb -TargetBackup $validFull
$smbMap = @{}
foreach ($row in $smbRows) { $smbMap[$row.Name] = $row }
Assert-True 'uuid match' $smbMap['systemUuid'].Match
Assert-True 'systemSerial mismatch' (-not $smbMap['systemSerial'].Match)
Assert-True 'baseBoard match' $smbMap['baseBoardSerial'].Match
$smbFmt = Format-SmbiosVerify -Rows $smbRows
Assert-True 'smbios verify header' ($smbFmt -match 'Verify SMBIOS')
Assert-True 'smbios shows MISMATCH' ($smbFmt -match 'MISMATCH')

Write-Host ''
Write-Host '=== Get-RestorablePropertyNames ==='
$names = Get-RestorablePropertyNames
Assert-equal 'property count' 5 $names.Count
Assert-True 'includes machineGuid' ($names -contains 'machineGuid')
Assert-True 'includes susClientId' ($names -contains 'susClientId')
Assert-True 'includes computerHardwareId' ($names -contains 'computerHardwareId')

Write-Host ''
Write-Host ("Results: {0} passed, {1} failed" -f $script:Passed, $script:Failed)
if ($script:Failed -gt 0) {
    Write-Host 'Failures:'
    foreach ($f in $script:Failures) {
        Write-Host "  - $f"
    }
    exit 1
}

Write-Host 'All validation tests passed.'
exit 0
