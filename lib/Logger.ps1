#Requires -Version 5.1
<#
.SYNOPSIS
    File logger for SINTHSBot HWID tool.
#>

Set-StrictMode -Version Latest

function Get-HwidLogDirectory {
    if (-not [string]::IsNullOrWhiteSpace($env:SINTHSBOT_LOGS)) {
        return $env:SINTHSBOT_LOGS
    }
    if (-not [string]::IsNullOrWhiteSpace($env:SINTHSBOT_BACKUPS)) {
        return Join-Path (Split-Path -Parent $env:SINTHSBOT_BACKUPS) 'logs'
    }
    $local = [Environment]::GetFolderPath('LocalApplicationData')
    if ([string]::IsNullOrWhiteSpace($local)) {
        return Join-Path $PSScriptRoot '..\logs'
    }
    return Join-Path $local 'SINTHSBot-HWID\logs'
}

function Initialize-HwidLog {
    [CmdletBinding()]
    param()

    $dir = Get-HwidLogDirectory
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    return $dir
}

function Write-HwidLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('DEBUG', 'INFO', 'WARN', 'ERROR')]
        [string]$Level,

        [Parameter(Mandatory)]
        [string]$Message,

        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    try {
        $dir = Initialize-HwidLog
        $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
        $line = '[{0}] [{1}] {2}' -f $stamp, $Level, $Message
        if ($ErrorRecord) {
            $line += [Environment]::NewLine + '  Exception: ' + $ErrorRecord.Exception.ToString()
            if ($ErrorRecord.ScriptStackTrace) {
                $line += [Environment]::NewLine + '  Stack: ' + $ErrorRecord.ScriptStackTrace
            }
            if ($ErrorRecord.InvocationInfo) {
                $line += [Environment]::NewLine + ('  At: {0}:{1}' -f $ErrorRecord.InvocationInfo.ScriptName, $ErrorRecord.InvocationInfo.ScriptLineNumber)
            }
        }

        $latest = Join-Path $dir 'latest.log'
        $session = Join-Path $dir ('session-{0}.log' -f (Get-Date).ToString('yyyyMMdd'))
        Add-Content -LiteralPath $latest -Value $line -Encoding UTF8
        Add-Content -LiteralPath $session -Value $line -Encoding UTF8

        if ($Level -eq 'ERROR') {
            $errFile = Join-Path $dir 'latest-error.txt'
            $errBody = @(
                "SINTHSBot HWID — letzter Fehler"
                "Zeit: $stamp"
                "Message: $Message"
                ""
                $line
                ""
                "Log-Ordner: $dir"
                "Bitte diese Datei oder latest.log schicken, wenn Backup/Restore hakt."
            ) -join [Environment]::NewLine
            [System.IO.File]::WriteAllText($errFile, $errBody)
        }
    }
    catch {
        # Logging must never break the main flow
    }
}
