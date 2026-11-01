# Shared by install.ps1 and uninstall.ps1. The functions without side effects are covered by the tests.
$script:TaskName = 'Hang Dump Watchdog'

function Test-IsAdministrator {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  return ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# True only for a command line that runs exactly this copy of watchdog.ps1.
function Test-IsWatchdogCommandLine {
  param([string]$CommandLine, [string]$ScriptPath)
  if ([string]::IsNullOrWhiteSpace($CommandLine)) { return $false }
  $normalized = $CommandLine.Replace('/', '\')
  $target = $ScriptPath.Replace('/', '\')
  $at = $normalized.IndexOf($target, [StringComparison]::OrdinalIgnoreCase)
  if ($at -lt 0) { return $false }
  $next = $at + $target.Length
  return ($next -eq $normalized.Length) -or ($normalized[$next] -in @('"', ' ', "'"))
}

# Firewall rule only when clients on other machines have to reach the listener.
function Get-FirewallPlan {
  param($Config)
  $listener = $Config.Listener
  if (-not $listener.Enabled) { return $null }
  if ([Net.IPAddress]::IsLoopback([Net.IPAddress]::Parse($listener.BindAddress))) { return $null }
  return [pscustomobject]@{ Port = $listener.Port; RemoteAddress = @($listener.AllowedClients) }
}

# Stops a running copy. Ending the task alone can leave its pwsh process alive, so that one is
# found by its command line, and only if it runs this exact script.
function Stop-InstalledWatchdog {
  [CmdletBinding(SupportsShouldProcess)]
  param([string]$ScriptPath)
  $task = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
  if ($task -and $PSCmdlet.ShouldProcess($script:TaskName, 'Stop and remove the scheduled task')) {
    Stop-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false
  }
  foreach ($process in Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'") {
    if ($process.ProcessId -eq $PID) { continue }
    if (-not (Test-IsWatchdogCommandLine -CommandLine $process.CommandLine -ScriptPath $ScriptPath)) { continue }
    if ($PSCmdlet.ShouldProcess("pwsh.exe, process $($process.ProcessId)", 'Stop the running watchdog')) {
      Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
    }
  }
}

function Remove-WatchdogFirewallRule {
  [CmdletBinding(SupportsShouldProcess)]
  param()
  $rule = Get-NetFirewallRule -DisplayName $script:TaskName -ErrorAction SilentlyContinue
  if ($rule -and $PSCmdlet.ShouldProcess($script:TaskName, 'Remove the firewall rule')) {
    $rule | Remove-NetFirewallRule
  }
}

# Well-known SIDs, because group names change with the Windows language.
function Set-RestrictedAcl {
  [CmdletBinding(SupportsShouldProcess)]
  param([string]$Path, [switch]$UsersCanRead)
  $grants = @('*S-1-5-18:(OI)(CI)F', '*S-1-5-32-544:(OI)(CI)F')
  if ($UsersCanRead) { $grants += '*S-1-5-32-545:(OI)(CI)RX' }
  if ($PSCmdlet.ShouldProcess($Path, 'Allow only SYSTEM and Administrators to change it')) {
    & icacls.exe $Path /inheritance:r /grant:r @grants | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls failed on $Path with exit code $LASTEXITCODE" }
  }
}
