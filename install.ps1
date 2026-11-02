#Requires -Version 7.4
<#
.SYNOPSIS
  Installs the watchdog as a scheduled task that starts elevated when the user logs on.

.DESCRIPTION
  Run it from an elevated PowerShell 7 prompt. Use -WhatIf to see every step without changing anything.

  The program goes to a folder that only administrators can change, because the task runs it elevated
  at every logon. Logs, dumps and config.json go to a separate folder that only administrators can read,
  because dumps hold kernel memory.

  The config comes from config.json next to this script if there is one, otherwise config.example.json.
  An existing installed config is kept unless -ReplaceConfig is used.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
  [string]$InstallDir = (Join-Path $env:ProgramFiles 'FreezeDump'),
  [string]$DataDir = (Join-Path $env:ProgramData 'FreezeDump'),
  [string]$User = "$env:USERDOMAIN\$env:USERNAME",
  [switch]$ReplaceConfig,
  [switch]$NoStart
)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
. (Join-Path $here 'src\Installer-Helpers.ps1')
. (Join-Path $here 'src\Load-Types.ps1')

if (-not $WhatIfPreference -and -not (Test-IsAdministrator)) {
  throw 'Run this from an elevated PowerShell 7 prompt (or add -WhatIf to only see the steps).'
}

$pwshPath = Join-Path $PSHOME 'pwsh.exe'
if ($pwshPath -like '*\WindowsApps\*') {
  Write-Warning 'This PowerShell comes from the Microsoft Store and its path changes with every update. Use the MSI build, or run install.ps1 again after updating.'
}

$sourceConfig = Join-Path $here 'config.json'
if (-not (Test-Path -LiteralPath $sourceConfig)) { $sourceConfig = Join-Path $here 'config.example.json' }
$installedConfig = Join-Path $DataDir 'config.json'
$useInstalled = (Test-Path -LiteralPath $installedConfig) -and -not $ReplaceConfig
$configToUse = if ($useInstalled) { $installedConfig } else { $sourceConfig }

# Stops here, with nothing changed yet, if the config is wrong. An empty dataDir means "next to the file".
try {
  $json = Get-Content -LiteralPath $configToUse -Raw
  $config = [FreezeDump.WatchdogConfig]::Parse($json, $DataDir)
}
catch {
  $inner = $_.Exception
  while ($inner.InnerException) { $inner = $inner.InnerException }
  throw "Config problem in ${configToUse}: $($inner.Message)"
}
Write-Output "Config OK ($configToUse): $($config.Summary())"

$scriptPath = Join-Path $InstallDir 'src\watchdog.ps1'
Stop-InstalledWatchdog -ScriptPath $scriptPath
Remove-WatchdogFirewallRule

if ($PSCmdlet.ShouldProcess($InstallDir, 'Copy the program files')) {
  New-Item -ItemType Directory -Force -Path (Join-Path $InstallDir 'src') | Out-Null
  Copy-Item -Force -Path (Join-Path $here 'src\*') -Destination (Join-Path $InstallDir 'src')
  foreach ($file in 'LICENSE', 'NOTICE', 'config.example.json', 'uninstall.ps1') {
    Copy-Item -Force -LiteralPath (Join-Path $here $file) -Destination $InstallDir
  }
}
Set-RestrictedAcl -Path $InstallDir -UsersCanRead

if ($PSCmdlet.ShouldProcess($DataDir, 'Create the data folder')) {
  New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
}
Set-RestrictedAcl -Path $DataDir
# The dumps go wherever the config says, and they hold kernel memory wherever that is. Only the two
# folders of this program are locked: the one in the config can be any folder, with other things in it.
# The watchdog locks them again every time it starts, in case the config changes after this.
if ($config.DataDir -ne $DataDir) {
  foreach ($folder in $config.LogDir, $config.DumpDir) {
    if ($PSCmdlet.ShouldProcess($folder, 'Create the folder set in the config')) {
      New-Item -ItemType Directory -Force -Path $folder | Out-Null
    }
    Set-RestrictedAcl -Path $folder
  }
}
if ((-not $useInstalled) -and $PSCmdlet.ShouldProcess($installedConfig, "Copy the config from $sourceConfig")) {
  Copy-Item -Force -LiteralPath $sourceConfig -Destination $installedConfig
}

$taskArguments = "--headless `"$pwshPath`" -NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -ConfigPath `"$installedConfig`""
if ($PSCmdlet.ShouldProcess($script:TaskName, "Register a scheduled task for $User, elevated, at logon")) {
  $action = New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32\conhost.exe') -Argument $taskArguments -WorkingDirectory $DataDir
  $trigger = New-ScheduledTaskTrigger -AtLogOn -User $User
  $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew -Priority 4
  $principal = New-ScheduledTaskPrincipal -UserId $User -LogonType Interactive -RunLevel Highest
  Register-ScheduledTask -TaskName $script:TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
    -Description 'Requests a live kernel dump if Windows stops being able to create processes.' | Out-Null
}

$firewall = Get-FirewallPlan -Config $config
if ($firewall -and $PSCmdlet.ShouldProcess($script:TaskName, "Allow TCP $($firewall.Port) from $($firewall.RemoteAddress -join ', ')")) {
  New-NetFirewallRule -DisplayName $script:TaskName -Direction Inbound -Protocol TCP -LocalPort $firewall.Port `
    -RemoteAddress $firewall.RemoteAddress -Program $pwshPath -Action Allow -Profile Any | Out-Null
}

if ($WhatIfPreference) {
  Write-Output 'Nothing was changed: this was only -WhatIf.'
  return
}

if ($NoStart) {
  Write-Output 'Not started now. It will start at the next logon.'
  return
}

Start-ScheduledTask -TaskName $script:TaskName
Start-Sleep -Seconds 8
Write-Output "Task state: $((Get-ScheduledTask -TaskName $script:TaskName).State)"
$todayLog = Join-Path $config.LogDir ((Get-Date -Format 'yyyy-MM-dd') + '.log')
if (Test-Path -LiteralPath $todayLog) { Get-Content -LiteralPath $todayLog -Tail 4 }
Write-Output "Logs and dumps: $($config.DataDir)"
