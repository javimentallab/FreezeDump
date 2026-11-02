#Requires -Version 7.4
<#
.SYNOPSIS
  Removes the scheduled task, stops the running watchdog, removes the firewall rule and the program folder.

.DESCRIPTION
  Run it from an elevated PowerShell 7 prompt. Use -WhatIf to see every step without changing anything.
  Logs, dumps and config.json stay in the data folder unless -RemoveData is used.

  If the config sets its own dataDir, -RemoveData also deletes the logs and dumps there, and nothing else:
  that folder can hold other things.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
  [string]$InstallDir = (Join-Path $env:ProgramFiles 'FreezeDump'),
  [string]$DataDir = (Join-Path $env:ProgramData 'FreezeDump'),
  [switch]$RemoveData
)
$ErrorActionPreference = 'Stop'

# From the installed copy the helpers are in .\src, and so they are from a clone of the repository.
. (Join-Path $PSScriptRoot 'src\Installer-Helpers.ps1')

if (-not $WhatIfPreference -and -not (Test-IsAdministrator)) {
  throw 'Run this from an elevated PowerShell 7 prompt (or add -WhatIf to only see the steps).'
}

# Read now: the config is about to be deleted, and it says where the logs and dumps really are.
$ownDataDir = Get-ConfiguredDataDir -DataDir $DataDir -LoadTypesScript (Join-Path $PSScriptRoot 'src\Load-Types.ps1')

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
  if ($ownDataDir) { Remove-WatchdogFile -Folder $ownDataDir }
  if ((Test-Path -LiteralPath $DataDir) -and $PSCmdlet.ShouldProcess($DataDir, 'Delete logs, dumps and config')) {
    Remove-Item -LiteralPath $DataDir -Recurse -Force
  }
}
else {
  if (Test-Path -LiteralPath $DataDir) {
    Write-Output "Logs, dumps and config are still in $DataDir. Delete them with -RemoveData or by hand."
  }
  if ($ownDataDir) {
    Write-Output "Logs and dumps are also in $ownDataDir. Delete them with -RemoveData or by hand."
  }
}
Write-Output 'Done.'
