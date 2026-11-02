# Shared by install.ps1 and uninstall.ps1. The functions without side effects are covered by the tests.
$script:TaskName = 'FreezeDump'

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

# The folder that the installed config sets with "dataDir", if it is not the data folder itself.
# A config that can not be read must not stop the uninstall, so that only gets a warning.
function Get-ConfiguredDataDir {
  param([string]$DataDir, [string]$LoadTypesScript)
  $configPath = Join-Path $DataDir 'config.json'
  if (-not (Test-Path -LiteralPath $configPath)) { return $null }
  try {
    . $LoadTypesScript
    $configured = [FreezeDump.WatchdogConfig]::Load($configPath).DataDir
  }
  catch {
    Write-Warning "Could not read ${configPath}: $($_.Exception.Message) If it sets its own dataDir, delete the logs and dumps there by hand."
    return $null
  }
  if ([IO.Path]::GetFullPath($configured).TrimEnd('\') -ieq [IO.Path]::GetFullPath($DataDir).TrimEnd('\')) { return $null }
  return $configured
}

# Deletes the logs and dumps that this program wrote in a folder set by the config. That folder can
# be any folder, with other things in it, so there is no recursive delete here: only files named as
# this program names them, and then the folders that are left empty.
function Remove-WatchdogFile {
  [CmdletBinding(SupportsShouldProcess)]
  param([string]$Folder)
  $owned = @(
    @{ Dir = 'dumps'; Name = '^((hang|test)-\d{8}-\d{6}(-rescued(-\d+)?)?|reserve-\d+)\.dmp$' },
    @{ Dir = 'logs'; Name = '^\d{4}-\d{2}-\d{2}\.log$' }
  )
  foreach ($part in $owned) {
    $dir = Join-Path $Folder $part.Dir
    if (-not (Test-Path -LiteralPath $dir)) { continue }
    foreach ($file in Get-ChildItem -LiteralPath $dir -File -Force) {
      if ($file.Name -match $part.Name -and $PSCmdlet.ShouldProcess($file.FullName, 'Delete this log or dump')) {
        Remove-Item -LiteralPath $file.FullName -Force
      }
    }
  }
  foreach ($dir in (Join-Path $Folder 'dumps'), (Join-Path $Folder 'logs'), $Folder) {
    if (-not (Test-Path -LiteralPath $dir)) { continue }
    $isRoot = [IO.Path]::GetPathRoot($dir).TrimEnd('\') -ieq $dir.TrimEnd('\')
    if ($isRoot -or (Get-ChildItem -LiteralPath $dir -Force | Select-Object -First 1)) { continue }
    if ($PSCmdlet.ShouldProcess($dir, 'Delete this empty folder')) {
      Remove-Item -LiteralPath $dir -Force
    }
  }
}

# Well-known SIDs, because group names change with the Windows language. The whole list of rules is
# replaced, because any rule already on the folder has to go, not only those of these accounts.
function Set-RestrictedAcl {
  [CmdletBinding(SupportsShouldProcess)]
  param([string]$Path, [switch]$UsersCanRead)
  $rules = @(@('S-1-5-18', 'FullControl'), @('S-1-5-32-544', 'FullControl'))
  if ($UsersCanRead) { $rules += , @('S-1-5-32-545', 'ReadAndExecute') }
  if ($PSCmdlet.ShouldProcess($Path, 'Allow only SYSTEM and Administrators to change it')) {
    $security = [Security.AccessControl.DirectorySecurity]::new()
    $security.SetAccessRuleProtection($true, $false)
    foreach ($rule in $rules) {
      $sid = [Security.Principal.SecurityIdentifier]::new($rule[0])
      $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid, $rule[1], 'ContainerInherit, ObjectInherit', 'None', 'Allow'))
    }
    [IO.FileSystemAclExtensions]::SetAccessControl([IO.DirectoryInfo]::new($Path), $security)
  }
}
