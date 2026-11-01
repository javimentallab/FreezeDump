#Requires -Version 7.2
<#
.SYNOPSIS
  Removes the scheduled task, stops the running watchdog, removes the firewall rule and the program folder.

.DESCRIPTION
  Run it from an elevated PowerShell 7 prompt. Use -WhatIf to see every step without changing anything.
  Logs, dumps and config.json stay in the data folder unless -RemoveData is used.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
  [string]$InstallDir = (Join-Path $env:ProgramFiles 'HangDumpWatchdog'),
  [string]$DataDir = (Join-Path $env:ProgramData 'HangDumpWatchdog'),
  [switch]$RemoveData
)
$ErrorActionPreference = 'Stop'

# From the installed copy the helpers are in .\src, and so they are from a clone of the repository.
. (Join-Path $PSScriptRoot 'src\Installer-Helpers.ps1')

if (-not $WhatIfPreference -and -not (Test-IsAdministrator)) {
  throw 'Run this from an elevated PowerShell 7 prompt (or add -WhatIf to only see the steps).'
}

Stop-InstalledWatchdog -ScriptPath (Join-Path $InstallDir 'src\watchdog.ps1')
Remove-WatchdogFirewallRule

if ((Test-Path -LiteralPath $InstallDir) -and $PSCmdlet.ShouldProcess($InstallDir, 'Delete the program folder')) {
  try {
    Remove-Item -LiteralPath $InstallDir -Recurse -Force
  }
  catch {
    Write-Warning "Could not delete $InstallDir completely: $($_.Exception.Message) Delete it by hand after leaving that folder."
  }
}

if ($RemoveData) {
  if ((Test-Path -LiteralPath $DataDir) -and $PSCmdlet.ShouldProcess($DataDir, 'Delete logs, dumps and config')) {
    Remove-Item -LiteralPath $DataDir -Recurse -Force
  }
}
elseif (Test-Path -LiteralPath $DataDir) {
  Write-Host "Logs, dumps and config are still in $DataDir. Delete them with -RemoveData or by hand."
}
Write-Host 'Done.'
