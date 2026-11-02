#Requires -Version 7.2
<#
.SYNOPSIS
  Watches whether Windows can still create processes and, if it cannot, asks for a live kernel dump.

.DESCRIPTION
  With no switches it runs the watchdog, which is what the scheduled task does. It needs elevation.

    -Simulate     Pretend hang on a virtual clock. No dump, no process started, no admin needed.
    -Scenario     With -Simulate: ok, dump-fails or dump-stuck.
    -CheckConfig  Validates the config file and exits.
    -TestNotify   Sends one test notification.
    -TestDump     Requests ONE REAL dump. Elevated only, asks first, freezes the PC for about 2 s.
    -ShowVersion  Prints the version.

.PARAMETER ConfigPath
  Config file. Default: config.json in %ProgramData%\FreezeDump. With -Simulate no file is
  read unless this is given, and then only the timing settings are used.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
  [string]$ConfigPath,
  [switch]$Simulate,
  [ValidateSet('ok', 'dump-fails', 'dump-stuck')][string]$Scenario = 'ok',
  [switch]$CheckConfig,
  [switch]$TestNotify,
  [switch]$TestDump,
  [switch]$ShowVersion
)
$ErrorActionPreference = 'Stop'

$modes = @($Simulate, $CheckConfig, $TestNotify, $TestDump, $ShowVersion) | Where-Object { $_ }
if (@($modes).Count -gt 1) {
  [Console]::Error.WriteLine('error: use only one of -Simulate, -CheckConfig, -TestNotify, -TestDump and -ShowVersion.')
  exit 2
}

. (Join-Path $PSScriptRoot 'Load-Types.ps1')

if ($ShowVersion) {
  "FreezeDump $([FreezeDump.Program]::Version)"
  exit 0
}

function Get-Config {
  param([string]$Path, [switch]$IgnoreInstalledFile)
  if ($Path) { return [FreezeDump.WatchdogConfig]::Load($Path) }
  $default = [FreezeDump.WatchdogConfig]::DefaultConfigPath()
  if ((-not $IgnoreInstalledFile) -and (Test-Path -LiteralPath $default)) { return [FreezeDump.WatchdogConfig]::Load($default) }
  return [FreezeDump.WatchdogConfig]::Defaults()
}

function Get-RootMessage {
  param($ErrorRecord)
  $e = $ErrorRecord.Exception
  while ($e.InnerException) { $e = $e.InnerException }
  return $e.Message
}

try {
  if ($Simulate) {
    $settings = Get-Config -Path $ConfigPath -IgnoreInstalledFile
    # Straight to the console, because the simulation writes its log lines there too.
    [Console]::Out.WriteLine("FreezeDump $([FreezeDump.Program]::Version) - SIMULATION, scenario: $Scenario")
    [Console]::Out.WriteLine('Virtual clock. No kernel dump is requested, no process is started, nothing leaves this PC.')
    [Console]::Out.WriteLine()
    $result = [FreezeDump.Simulation]::Run($Scenario, $settings, $null, $true)
    [Console]::Out.WriteLine()
    [Console]::Out.WriteLine("Simulated dump requests: $($result.DumpRequests). Simulated files kept: $($result.DumpFiles.Count). Real dumps: 0.")
    exit 0
  }

  $config = Get-Config -Path $ConfigPath

  if ($CheckConfig) {
    "Config OK: $($config.Summary())"
    "Data folder: $($config.DataDir)"
    exit 0
  }

  if ($TestNotify) {
    [FreezeDump.Program]::SendTestNotification($config)
    exit 0
  }

  if ($TestDump) {
    $target = "this PC, writing to $($config.DumpDir)"
    if ($PSCmdlet.ShouldProcess($target, 'Request ONE REAL live kernel dump (freezes the PC for about 2 s, writes several GB)')) {
      [FreezeDump.Program]::RunTestDump($config)
      'Test dumps are not rotated: delete the test-*.dmp file when you are done. It holds kernel memory, do not share it.'
    }
    exit 0
  }

  exit [FreezeDump.Program]::RunForever($config)
}
catch {
  $message = Get-RootMessage $_
  # No window and no console when the scheduled task runs this: leave the reason where it can be found.
  if (-not ($Simulate -or $CheckConfig -or $TestNotify -or $TestDump)) {
    try {
      $errorLog = Join-Path ([FreezeDump.WatchdogConfig]::DefaultDataDir()) 'startup-error.log'
      New-Item -ItemType Directory -Force -Path (Split-Path $errorLog) | Out-Null
      Add-Content -LiteralPath $errorLog -Value "$(Get-Date -Format 's') $message"
    }
    catch { }
  }
  [Console]::Error.WriteLine("error: $message")
  exit 2
}
