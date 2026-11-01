#Requires -Version 7.2
<#
.SYNOPSIS
  Tests for the detection, the configuration, the simulation and the listener. No dependencies.

.DESCRIPTION
  They never request a kernel dump: nothing in here can arm the native call (see LiveDumpGate) and
  only the simulated dump writer is used. No admin rights needed. The only processes started are a
  harmless "cmd /c exit 0" for the real probe and the short pwsh runs that check the command line.
  The only socket is on the loopback address, on a port picked by Windows.

  Exit code 0 means every test passed.
#>
param([string]$Filter = '')
$ErrorActionPreference = 'Stop'

$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src\Load-Types.ps1')
. (Join-Path $root 'src\Installer-Helpers.ps1')

$script:passed = 0
$script:failures = [System.Collections.Generic.List[string]]::new()
$workRoot = Join-Path ([IO.Path]::GetTempPath()) ("hdw-tests-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $workRoot | Out-Null

function New-WorkDir {
  $dir = Join-Path $workRoot ([Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $dir | Out-Null
  return $dir
}

function Test-Case {
  param([string]$Name, [scriptblock]$Body)
  if ($Filter -and $Name -notlike "*$Filter*") { return }
  try {
    & $Body
    $script:passed++
    Write-Host "  ok    $Name"
  }
  catch {
    $script:failures.Add("$Name -> $($_.Exception.Message)")
    Write-Host "  FAIL  $Name -> $($_.Exception.Message)"
  }
}

function Assert-True {
  param($Value, [string]$Message = 'expected true')
  if (-not $Value) { throw $Message }
}

function Assert-False {
  param($Value, [string]$Message = 'expected false')
  if ($Value) { throw $Message }
}

function Assert-Equal {
  param($Expected, $Actual, [string]$Message = '')
  if ($Expected -ne $Actual) { throw "expected [$Expected], got [$Actual] $Message" }
}

function Assert-Throws {
  param([scriptblock]$Body, [string]$Contains)
  $thrown = $null
  try { & $Body } catch { $thrown = $_.Exception }
  if (-not $thrown) { throw "expected an error containing '$Contains'" }
  $text = ''
  while ($thrown) { $text += " $($thrown.Message)"; $thrown = $thrown.InnerException }
  if ($text -notlike "*$Contains*") { throw "wrong error: $text (expected '$Contains')" }
}

function Get-Matching {
  param($Lines, [string]$Pattern)
  return @($Lines | Where-Object { $_ -cmatch $Pattern })
}

function Assert-InOrder {
  param($Lines, [string[]]$Patterns)
  $at = -1
  foreach ($pattern in $Patterns) {
    $found = -1
    for ($i = $at + 1; $i -lt $Lines.Count; $i++) {
      if ($Lines[$i] -cmatch $pattern) { $found = $i; break }
    }
    if ($found -lt 0) { throw "line matching '$pattern' not found after line $at" }
    $at = $found
  }
}

$Parse = { param($Json) [HangDumpWatchdog.WatchdogConfig]::Parse($Json, 'C:\Data\Watchdog') }
$NewDetector = { param($Hang = 45, $Max = 2, $Gap = 150) [HangDumpWatchdog.HangDetector]::new($Hang, $Max, $Gap) }
$Inf = [double]::PositiveInfinity

Write-Host 'Safety'

Test-Case 'the native dump is not armed when the tests start' {
  Assert-False ([HangDumpWatchdog.LiveDumpGate]::Armed)
}

Test-Case 'the gate refuses while it is not armed' {
  Assert-Throws { [HangDumpWatchdog.LiveDumpGate]::EnsureArmed() } 'not armed'
}

Test-Case 'tests cannot arm the gate: Arm is not public' {
  $arm = [HangDumpWatchdog.LiveDumpGate].GetMethod('Arm', [Reflection.BindingFlags]'Public,Static')
  Assert-True ($null -eq $arm)
}

Test-Case 'the native structure keeps its 64-byte layout' {
  Assert-Equal 64 ([HangDumpWatchdog.LiveKernelDump]::ControlStructSize)
}

Write-Host 'Detection'

Test-Case 'a healthy probe never reports a hang' {
  $d = & $NewDetector
  foreach ($second in 1..300) {
    $r = $d.Tick(0.05, $false, $false, $Inf)
    Assert-False ($r.HangStarted -or $r.RequestDump -or $r.Recovered)
  }
  Assert-False $d.Hung
}

Test-Case 'exactly at the limit is not a hang yet, just over it is' {
  $d = & $NewDetector
  Assert-False $d.Tick(45.0, $true, $false, $Inf).HangStarted
  Assert-True $d.Tick(45.1, $true, $false, $Inf).HangStarted
}

Test-Case 'a hang starts once and asks for the first dump at once' {
  $d = & $NewDetector
  $first = $d.Tick(46, $true, $false, $Inf)
  Assert-True $first.HangStarted
  Assert-True $first.RequestDump
  Assert-Equal 1 $first.DumpNumber
  Assert-False $d.Tick(47, $true, $true, 1).HangStarted
}

Test-Case 'no dump while another is running' {
  $d = & $NewDetector
  Assert-False $d.Tick(46, $true, $true, $Inf).RequestDump
  Assert-Equal 0 $d.DumpsThisHang
}

Test-Case 'the second dump waits for the minimum gap' {
  $d = & $NewDetector
  [void]$d.Tick(46, $true, $false, $Inf)
  Assert-False $d.Tick(100, $true, $false, 149.9).RequestDump
  $second = $d.Tick(200, $true, $false, 150)
  Assert-True $second.RequestDump
  Assert-Equal 2 $second.DumpNumber
}

Test-Case 'never more than the limit of dumps per hang' {
  $d = & $NewDetector
  foreach ($i in 1..10) { [void]$d.Tick(46 + $i * 200, $true, $false, $Inf) }
  Assert-Equal 2 $d.DumpsThisHang
}

Test-Case 'a limit of 0 dumps only logs the hang' {
  $d = & $NewDetector 45 0 150
  $r = $d.Tick(46, $true, $false, $Inf)
  Assert-True $r.HangStarted
  Assert-False $r.RequestDump
}

Test-Case 'recovery needs the probe to have ended' {
  $d = & $NewDetector
  [void]$d.Tick(46, $true, $false, $Inf)
  Assert-False $d.Tick(0, $true, $false, 5).Recovered
  Assert-True $d.Tick(0, $false, $false, 5).Recovered
  Assert-False $d.Hung
}

Test-Case 'a new hang gets a new allowance of dumps' {
  $d = & $NewDetector
  foreach ($i in 1..3) { [void]$d.Tick(46 + $i * 200, $true, $false, $Inf) }
  [void]$d.Tick(0, $false, $false, $Inf)
  $again = $d.Tick(46, $true, $false, $Inf)
  Assert-True $again.HangStarted
  Assert-True $again.RequestDump
  Assert-Equal 1 $again.DumpNumber
}

Test-Case 'the real probe times a real short process' {
  $clock = [HangDumpWatchdog.SystemClock]::new()
  $probe = [HangDumpWatchdog.ProcessProbe]::new($clock)
  Assert-True ($probe.LastMs -lt 0)
  $probe.Kick()
  $limit = [DateTime]::Now.AddSeconds(20)
  while ($probe.Running -and [DateTime]::Now -lt $limit) { Start-Sleep -Milliseconds 50 }
  Assert-False $probe.Running 'the probe did not end in 20 s'
  Assert-Equal '' $probe.LastError
  Assert-True ($probe.LastMs -gt 0)
  Assert-Equal 0 $probe.PendingSeconds
}

Test-Case 'the real sampler reads the system' {
  $sample = [HangDumpWatchdog.ProcessSampler]::new([HangDumpWatchdog.SystemClock]::new()).Sample()
  Assert-True ($sample.ProcessCount -gt 0)
  Assert-True ($sample.RamPercent -gt 0 -and $sample.RamPercent -le 100)
}

Write-Host 'Configuration'

Test-Case 'the defaults are valid and keep extras off' {
  $c = [HangDumpWatchdog.WatchdogConfig]::Defaults()
  Assert-Equal 45 $c.HangSeconds
  Assert-False $c.Ntfy.Enabled
  Assert-False $c.Listener.Enabled
}

Test-Case 'config.example.json loads and matches the defaults' {
  $c = [HangDumpWatchdog.WatchdogConfig]::Load((Join-Path $root 'config.example.json'))
  $d = [HangDumpWatchdog.WatchdogConfig]::Defaults()
  foreach ($name in 'HangSeconds', 'ProbeIntervalSeconds', 'SampleIntervalSeconds', 'MaxDumpsPerHang', 'MinSecondsBetweenDumps', 'KeepDumps', 'ReserveFiles', 'LogRetentionDays') {
    Assert-Equal $d.$name $c.$name $name
  }
  Assert-False $c.Ntfy.Enabled
  Assert-False $c.Listener.Enabled
  Assert-Equal $root $c.DataDir 'an empty dataDir means next to the file'
}

Test-Case 'an empty file is fine and environment variables are expanded' {
  Assert-Equal 'C:\Data\Watchdog' (& $Parse '{}').DataDir
  $env:HDW_TEST_DIR = 'D:\Somewhere'
  Assert-Equal 'D:\Somewhere\x' (& $Parse '{ "dataDir": "%HDW_TEST_DIR%\\x" }').DataDir
  Remove-Item Env:HDW_TEST_DIR
}

Test-Case 'comments and trailing commas are accepted' {
  Assert-Equal 60 (& $Parse "{ // note`n `"hangSeconds`": 60, }").HangSeconds
}

Test-Case 'a typo in a setting name is an error, not silence' {
  Assert-Throws { & $Parse '{ "hangSecond": 60 }' } "unknown setting 'hangSecond'"
  Assert-Throws { & $Parse '{ "ntfy": { "ulr": "x" } }' } "unknown setting 'ntfy.ulr'"
  Assert-Throws { & $Parse '{ "listener": { "tokn": "x" } }' } "unknown setting 'listener.tokn'"
}

Test-Case 'broken JSON and wrong types give a clear error' {
  Assert-Throws { & $Parse '{ nope' } 'not valid JSON'
  Assert-Throws { & $Parse '[]' } 'JSON object'
  Assert-Throws { & $Parse '{ "hangSeconds": "45" }' } 'whole number'
  Assert-Throws { & $Parse '{ "hangSeconds": 45.5 }' } 'whole number'
  Assert-Throws { & $Parse '{ "dataDir": 3 }' } 'must be text'
  Assert-Throws { & $Parse '{ "listener": { "enabled": "yes" } }' } 'true or false'
}

Test-Case 'numbers out of range are rejected' {
  foreach ($case in @(
      @('hangSeconds', 9), @('hangSeconds', 3601), @('probeIntervalSeconds', 0), @('sampleIntervalSeconds', 0),
      @('maxDumpsPerHang', -1), @('maxDumpsPerHang', 21), @('minSecondsBetweenDumps', 29), @('keepDumps', 0),
      @('reserveFiles', -1), @('reserveFiles', 9), @('logRetentionDays', 0))) {
    Assert-Throws { & $Parse ('{ "' + $case[0] + '": ' + $case[1] + ' }') } $case[0]
  }
}

Test-Case 'the probe must run more often than the hang limit' {
  Assert-Throws { & $Parse '{ "hangSeconds": 20, "probeIntervalSeconds": 20 }' } 'lower than'
}

Test-Case 'the data folder must be local and absolute' {
  foreach ($bad in 'relative\\dir', '\\\\server\\share', '\\\\?\\C:\\x', 'C:relative', 'C:\\a\\..\\b', 'C:/x') {
    Assert-Throws { & $Parse ('{ "dataDir": "' + $bad + '" }') } 'dataDir'
  }
  Assert-Equal 'D:\Watchdog' (& $Parse '{ "dataDir": "D:\\Watchdog" }').DataDir
}

Test-Case 'notification URLs are validated' {
  foreach ($bad in 'not a url', 'ftp://ntfy.example.com/topic', 'file:///C:/x', 'https://ntfy.example.com/', 'https://user:pw@ntfy.example.com/topic',
    'http://ntfy.example.com/topic', 'http://203.0.113.5/topic', 'http://172.32.0.1/topic') {
    Assert-Throws { & $Parse ('{ "ntfy": { "url": "' + $bad + '" } }') } 'ntfy.url'
  }
  foreach ($good in 'https://ntfy.example.com/topic', 'http://localhost:8090/topic', 'http://127.0.0.1/topic', 'http://10.0.0.5/topic', 'http://172.16.0.1/topic') {
    Assert-True (& $Parse ('{ "ntfy": { "url": "' + $good + '" } }')).Ntfy.Enabled
  }
}

Test-Case 'a notification token needs a URL and has no spaces' {
  Assert-Throws { & $Parse '{ "ntfy": { "token": "abc" } }' } "'ntfy.url' is empty"
  Assert-Throws { & $Parse '{ "ntfy": { "url": "https://ntfy.example.com/t", "token": "a b" } }' } 'ntfy.token'
}

Test-Case 'listener settings are validated' {
  Assert-Throws { & $Parse '{ "listener": { "port": 80 } }' } 'listener.port'
  Assert-Throws { & $Parse '{ "listener": { "bindAddress": "somehost" } }' } 'bindAddress'
  Assert-Throws { & $Parse '{ "listener": { "allowedClients": ["nope"] } }' } 'allowedClients'
  Assert-Throws { & $Parse '{ "listener": { "token": "short" } }' } 'at least 16'
  Assert-Throws { & $Parse '{ "listener": { "token": "has a space in the middle" } }' } 'listener.token'
  Assert-Throws { & $Parse '{ "listener": { "enabled": true, "bindAddress": "0.0.0.0" } }' } 'allowedClients'
  Assert-True (& $Parse '{ "listener": { "enabled": true } }').Listener.Enabled
}

Test-Case 'tokens never appear in the summary' {
  $c = & $Parse '{ "ntfy": { "url": "https://ntfy.example.com/t", "token": "ntfysecretvalue" }, "listener": { "enabled": true, "token": "listenersecretvalue" } }'
  Assert-False ($c.Summary() -match 'secretvalue')
}

Test-Case 'the notification request is well formed and only sends a token if there is one' {
  $log = [HangDumpWatchdog.Logger]::new((New-WorkDir), [HangDumpWatchdog.SystemClock]::new(), $false, $true)
  $request = [HangDumpWatchdog.NtfyNotifier]::new('https://ntfy.example.com/t', 'tk_abc', $log).BuildRequest('Title', 'Body')
  Assert-Equal 'POST' $request.Method.Method
  Assert-Equal 'https://ntfy.example.com/t' $request.RequestUri.AbsoluteUri
  Assert-Equal 'Bearer tk_abc' ($request.Headers.GetValues('Authorization') -join '')
  Assert-Equal 'Title' ($request.Headers.GetValues('Title') -join '')
  $request = [HangDumpWatchdog.NtfyNotifier]::new('https://ntfy.example.com/t', '', $log).BuildRequest('Title', 'Body')
  Assert-False $request.Headers.Contains('Authorization')
}

Add-Type -TypeDefinition @'
using System.Net.Sockets;
using System.Text;
using System.Threading.Tasks;

public static class FakeHttpServer
{
    // Answers one request on a loopback socket and returns what it received.
    public static Task<string> ServeOnce(TcpListener listener)
    {
        return Task.Run(() =>
        {
            using (TcpClient client = listener.AcceptTcpClient())
            {
                client.ReceiveTimeout = 5000;
                NetworkStream stream = client.GetStream();
                var received = new StringBuilder();
                var buffer = new byte[4096];
                while (true)
                {
                    int n = stream.Read(buffer, 0, buffer.Length);
                    if (n <= 0) break;
                    received.Append(Encoding.ASCII.GetString(buffer, 0, n));
                    string text = received.ToString();
                    if (text.Contains("\r\n\r\n") && text.EndsWith("Body text")) break;
                }
                byte[] answer = Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
                stream.Write(answer, 0, answer.Length);
                return received.ToString();
            }
        });
    }
}
'@ -ReferencedAssemblies 'System.Net.Sockets', 'System.Net.Primitives', 'System.Collections', 'System.Threading.Tasks', 'System.Linq', 'System.Runtime', 'System.Text.Encoding.Extensions', 'System.Threading', 'Microsoft.Win32.Primitives', 'System.ComponentModel.Primitives'

Test-Case 'a notification really goes out, to a local test server' {
  $server = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
  $server.Start()
  try {
    $port = $server.LocalEndpoint.Port
    $log = [HangDumpWatchdog.Logger]::new((New-WorkDir), [HangDumpWatchdog.SystemClock]::new(), $false, $true)
    $received = [FakeHttpServer]::ServeOnce($server)
    [HangDumpWatchdog.NtfyNotifier]::new("http://127.0.0.1:$port/test-topic", 'tk_abc', $log).Send('Title text', 'Body text')
    Assert-True $received.Wait(5000) 'the server got nothing'
    $request = $received.Result
    Assert-True ($request -like 'POST /test-topic HTTP/1.1*') "got: $request"
    Assert-True ($request -like '*Authorization: Bearer tk_abc*')
    Assert-True ($request -like '*Title: Title text*')
    Assert-True ($request -like '*Body text')
    Assert-True ((Get-Matching $log.Lines() 'ntfy 200').Count -eq 1)
  }
  finally { $server.Stop() }
}

Test-Case 'a failed notification is logged, without the token, and does not stop anything' {
  $server = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
  $server.Start()
  $port = $server.LocalEndpoint.Port
  $server.Stop()
  $log = [HangDumpWatchdog.Logger]::new((New-WorkDir), [HangDumpWatchdog.SystemClock]::new(), $false, $true)
  [HangDumpWatchdog.NtfyNotifier]::new("http://127.0.0.1:$port/test-topic", 'tk_secret_value', $log).Send('T', 'B')
  Assert-True ((Get-Matching $log.Lines() 'ntfy failed').Count -eq 1)
  Assert-False (($log.Lines() -join ' ') -like '*tk_secret_value*')
}

Test-Case 'no ntfy URL means no notifier that can reach the network' {
  $log = [HangDumpWatchdog.Logger]::new((New-WorkDir), [HangDumpWatchdog.SystemClock]::new(), $false, $true)
  $notifier = [HangDumpWatchdog.Notifiers]::FromConfig((& $Parse '{}'), $log)
  Assert-Equal 'NullNotifier' $notifier.GetType().Name
}

Write-Host 'Simulation'

$Defaults = [HangDumpWatchdog.WatchdogConfig]::Defaults()
$Sim = { param($Scenario, $Settings = $Defaults, $Dir = (New-WorkDir)) [HangDumpWatchdog.Simulation]::Run($Scenario, $Settings, $Dir, $false) }

Test-Case 'ok: hang found, two dumps with a gap, renamed, recovered' {
  $r = & $Sim 'ok'
  Assert-InOrder $r.Lines @(
    'dump reserves open: 2/2', 'process creation hangs', 'HANG: .* 46 s', 'DUMP requested .*\(1/2\).*reserve-1\.dmp \(reserve already open\)',
    'DUMP finished: status 0x00000000', 'notification \(simulated\): Kernel dump saved', 'DUMP renamed to hang-',
    'DUMP requested .*\(2/2\)', 'DUMP finished: status 0x00000000', 'DUMP renamed to hang-', 'RECOVERED')
  Assert-Equal 2 $r.DumpRequests
  Assert-Equal 2 $r.DumpFiles.Count
  Assert-Equal 2 $r.Notifications.Count
  Assert-Equal 'reserve-1.dmp,reserve-2.dmp' ($r.OtherFiles -join ',')
  Assert-False $r.FinalHung
}

Test-Case 'ok: the gap between the dumps is the configured one' {
  $r = & $Sim 'ok'
  $times = Get-Matching $r.Lines 'DUMP requested' | ForEach-Object { [TimeSpan]::Parse($_.Substring(0, 8)) }
  Assert-Equal 150 ($times[1] - $times[0]).TotalSeconds
}

Test-Case 'dump-fails: reported as failed, nothing kept, reserves ready again' {
  $r = & $Sim 'dump-fails'
  Assert-InOrder $r.Lines @('HANG:', 'DUMP finished: status 0xC0000022', 'notification \(simulated\): Kernel dump FAILED', 'dump reserves open: 2/2', 'RECOVERED')
  Assert-Equal 0 $r.DumpFiles.Count
  Assert-Equal 2 $r.DumpRequests
  Assert-Equal 2 (Get-Matching $r.Notifications 'FAILED').Count
  Assert-Equal 0 (Get-Matching $r.Lines 'DUMP renamed').Count
}

Test-Case 'dump-stuck: reported once, no second attempt, data rescued on the next boot' {
  $r = & $Sim 'dump-stuck'
  Assert-InOrder $r.Lines @('HANG:', 'DUMP requested', "DUMP STUCK: 31 s .*'inside NtSystemDebugControl'", 'notification \(simulated\): Kernel dump stuck',
    'power button', 'starting', 'rescued -> hang-.*-rescued\.dmp', 'dump reserves open: 2/2')
  Assert-Equal 1 $r.DumpRequests
  Assert-Equal 1 (Get-Matching $r.Lines 'DUMP STUCK').Count
  Assert-Equal 0 (Get-Matching $r.Lines 'DUMP finished').Count
  Assert-True $r.FinalHung
  Assert-Equal 1 $r.DumpFiles.Count
  Assert-True ($r.DumpFiles[0] -like '*-rescued.dmp')
}

Test-Case 'simulated files say what they are' {
  $dir = New-WorkDir
  [void](& $Sim 'ok' $Defaults $dir)
  $file = Get-ChildItem (Join-Path $dir 'dumps') -Filter 'hang-*.dmp' | Select-Object -First 1
  Assert-True ((Get-Content -LiteralPath $file.FullName -TotalCount 1) -like 'SIMULATED:*')
  Assert-True ($file.Length -lt 64KB) 'a simulation must not write big files'
}

Test-Case 'without reserves the file is created at dump time' {
  $settings = & $Parse '{ "reserveFiles": 0 }'
  $r = & $Sim 'ok' $settings
  Assert-Equal 1 (Get-Matching $r.Lines 'dump reserves open: 0/0' | Select-Object -First 1 | Measure-Object).Count
  Assert-True ((Get-Matching $r.Lines 'NO reserve: creating the file now').Count -ge 1)
  Assert-Equal 2 $r.DumpFiles.Count
  Assert-Equal 0 $r.OtherFiles.Count
}

Test-Case 'a limit of 0 dumps never requests one' {
  $r = & $Sim 'ok' (& $Parse '{ "maxDumpsPerHang": 0 }')
  Assert-Equal 1 (Get-Matching $r.Lines 'HANG:').Count
  Assert-Equal 0 $r.DumpRequests
  Assert-Equal 0 $r.DumpFiles.Count
}

Test-Case 'old dumps are rotated' {
  $r = & $Sim 'ok' (& $Parse '{ "keepDumps": 1 }')
  Assert-Equal 1 $r.DumpFiles.Count
  Assert-Equal 1 (Get-Matching $r.Lines 'deleting old dump hang-').Count
  Assert-True ($r.DumpFiles[0] -like 'hang-*-031536.dmp') 'the newest one stays'
}

Test-Case 'a leftover reserve with data is rescued at startup, not overwritten' {
  $dir = New-WorkDir
  New-Item -ItemType Directory -Path (Join-Path $dir 'dumps') | Out-Null
  $reserve = Join-Path $dir 'dumps\reserve-2.dmp'
  [IO.File]::WriteAllText($reserve, 'leftover')
  (Get-Item -LiteralPath $reserve).LastWriteTime = [DateTime]'2026-02-03 04:05:06'
  $r = & $Sim 'ok' $Defaults $dir
  Assert-True ((Get-Matching $r.Lines 'rescued -> hang-20260203-040506-rescued\.dmp').Count -eq 1)
  Assert-Equal 'leftover' ([IO.File]::ReadAllText((Join-Path $dir 'dumps\hang-20260203-040506-rescued.dmp')))
}

Test-Case 'old logs are purged after the retention period, recent ones stay' {
  $dir = New-WorkDir
  New-Item -ItemType Directory -Path (Join-Path $dir 'logs') | Out-Null
  $old = Join-Path $dir 'logs\old.log'
  $recent = Join-Path $dir 'logs\recent.log'
  Set-Content -LiteralPath $old -Value 'x'
  Set-Content -LiteralPath $recent -Value 'x'
  (Get-Item -LiteralPath $old).LastWriteTime = [DateTime]'2025-01-01'
  [void](& $Sim 'ok' $Defaults $dir)
  Assert-False (Test-Path -LiteralPath $old) 'the old log should be gone'
  Assert-True (Test-Path -LiteralPath $recent) 'the recent log should stay'
}

Test-Case 'a simulation never arms the native dump' {
  foreach ($scenario in [HangDumpWatchdog.Simulation]::Scenarios()) {
    Assert-False (& $Sim $scenario).RealDumpsArmed $scenario
  }
  Assert-False ([HangDumpWatchdog.LiveDumpGate]::Armed)
}

Test-Case 'a simulation ignores configured notifications and listener' {
  $settings = & $Parse '{ "ntfy": { "url": "https://ntfy.example.com/t" }, "listener": { "enabled": true } }'
  $r = & $Sim 'ok' $settings
  Assert-True ((Get-Matching $r.Lines 'notifications off, listener off').Count -ge 1)
}

Test-Case 'simulation output has only made-up data' {
  $r = & $Sim 'ok'
  $text = $r.Lines -join "`n"
  foreach ($private in $env:USERNAME, $env:COMPUTERNAME, $env:USERPROFILE, [IO.Path]::GetTempPath()) {
    if ($private) { Assert-False ($text.IndexOf($private, [StringComparison]::OrdinalIgnoreCase) -ge 0) "found '$private' in the output" }
  }
}

Test-Case 'the same simulation always prints the same thing' {
  Assert-Equal ((& $Sim 'ok').Lines -join "`n") ((& $Sim 'ok').Lines -join "`n")
}

Test-Case 'with no folder given it uses a temporary one, not the current folder' {
  $dir = New-WorkDir
  $previous = [Environment]::CurrentDirectory
  [Environment]::CurrentDirectory = $dir
  try {
    $r = [HangDumpWatchdog.Simulation]::Run('ok', $Defaults, $null, $false)
    Assert-Equal 2 $r.DumpFiles.Count
    Assert-Equal 0 @(Get-ChildItem -LiteralPath $dir -Force).Count 'files appeared in the current folder'
  }
  finally {
    [Environment]::CurrentDirectory = $previous
  }
}

Test-Case 'a relative simulation folder is refused' {
  Assert-Throws { [HangDumpWatchdog.Simulation]::Run('ok', $Defaults, 'relative\dir', $false) } 'absolute path'
}

Test-Case 'an unknown scenario is refused' {
  Assert-Throws { [HangDumpWatchdog.Simulation]::Run('nope', $Defaults, (New-WorkDir), $false) } 'unknown scenario'
}

Test-Case 'a sampler that stops is reported, a slow but regular one is not' {
  # The check runs every 30 s and the limit is 30 s or three sampling intervals, whichever is longer.
  foreach ($case in @(@(5, 60, $true), @(60, 170, $false), @(60, 215, $true))) {
    $settings = & $Parse ('{ "sampleIntervalSeconds": ' + $case[0] + ' }')
    $settings = $settings.CopyForSimulation((New-WorkDir))
    New-Item -ItemType Directory -Path $settings.LogDir, $settings.DumpDir | Out-Null
    $clock = [HangDumpWatchdog.ManualClock]::new([DateTime]'2026-01-01')
    $log = [HangDumpWatchdog.Logger]::new($settings.LogDir, $clock, $false, $true)
    $dumps = [HangDumpWatchdog.DumpManager]::new($settings, $clock, $log, [HangDumpWatchdog.SimulatedDumpWriter]::new([HangDumpWatchdog.SimulatedDumpMode]::Failure, $clock), [HangDumpWatchdog.NullNotifier]::new())
    $probe = [HangDumpWatchdog.ScriptedProbe]::new($clock, 1e9, 1e9)
    $watchdog = [HangDumpWatchdog.Watchdog]::new($settings, $clock, $log, $probe, [HangDumpWatchdog.SimulatedSampler]::new(), $dumps)
    foreach ($second in 1..$case[1]) { $clock.Advance(1); $watchdog.Step() }
    $reported = (Get-Matching $log.Lines() 'SAMPLER STUCK').Count -gt 0
    Assert-Equal $case[2] $reported "interval $($case[0]) s, $($case[1]) s without a sample"
  }
}

Test-Case 'simulation output has no false alarms' {
  foreach ($scenario in [HangDumpWatchdog.Simulation]::Scenarios()) {
    Assert-Equal 0 (Get-Matching (& $Sim $scenario).Lines 'SAMPLER STUCK').Count $scenario
  }
}

Test-Case 'dump requests are limited by the manager as well' {
  $dir = New-WorkDir
  $settings = $Defaults.CopyForSimulation($dir)
  New-Item -ItemType Directory -Path $settings.LogDir, $settings.DumpDir | Out-Null
  $clock = [HangDumpWatchdog.ManualClock]::new([DateTime]'2026-01-01')
  $log = [HangDumpWatchdog.Logger]::new($settings.LogDir, $clock, $false, $true)
  $writer = [HangDumpWatchdog.SimulatedDumpWriter]::new([HangDumpWatchdog.SimulatedDumpMode]::Success, $clock)
  $dumps = [HangDumpWatchdog.DumpManager]::new($settings, $clock, $log, $writer, [HangDumpWatchdog.NullNotifier]::new())
  Assert-True $dumps.TryRequest('first')
  Assert-True $dumps.WaitIdle(10000)
  Assert-False $dumps.TryRequest('too soon')
  $clock.Advance(150)
  Assert-True $dumps.TryRequest('later')
  Assert-True $dumps.WaitIdle(10000)
  $dumps.CloseReserves()
  Assert-Equal 2 $dumps.Requests
}

Write-Host 'Listener'

$NewListener = {
  param($Options)
  $log = [HangDumpWatchdog.Logger]::new((New-WorkDir), [HangDumpWatchdog.SystemClock]::new(), $false, $true)
  $status = [Func[string]] { 'pong test' }
  $dump = [Func[string, bool]] { param($why) $script:dumpCalls++; $true }
  [HangDumpWatchdog.CommandListener]::new($Options, $status, $dump, $log)
}
$Token = 'abcdefghijklmnopqrstuvwx'
$Lan = [Net.IPAddress]::Parse('10.0.0.5')
$Other = [Net.IPAddress]::Parse('10.0.0.6')

Test-Case 'only loopback and the listed clients are allowed' {
  $o = (& $Parse "{ `"listener`": { `"allowedClients`": [`"10.0.0.5`"] } }").Listener
  $l = & $NewListener $o
  Assert-True $l.IsAllowed([Net.IPAddress]::Loopback)
  Assert-True $l.IsAllowed($Lan)
  Assert-False $l.IsAllowed($Other)
}

Test-Case 'commands: ping, right token, wrong token, junk' {
  $script:dumpCalls = 0
  $l = & $NewListener (& $Parse "{ `"listener`": { `"token`": `"$Token`" } }").Listener
  Assert-Equal 'pong test' $l.Handle($Lan, 'ping')
  Assert-Equal 0 $script:dumpCalls
  Assert-Equal 'ok requested' $l.Handle($Lan, "$Token dump")
  Assert-Equal 1 $script:dumpCalls
  foreach ($bad in 'dump', ' dump', "$Token", "${Token}x dump", "abcdefghijklmnopqrstuvwy dump", '') {
    Assert-Equal '?' $l.Handle($Lan, $bad) "for '$bad'"
  }
  Assert-Equal 1 $script:dumpCalls
}

Test-Case 'with no token configured a dump can not be requested' {
  $script:dumpCalls = 0
  $l = & $NewListener (& $Parse '{}').Listener
  Assert-Equal '?' $l.Handle($Lan, ' dump')
  Assert-Equal '?' $l.Handle($Lan, 'dump')
  Assert-Equal 'pong test' $l.Handle($Lan, 'ping')
  Assert-Equal 0 $script:dumpCalls
}

Test-Case 'round trip over a loopback socket, on a port picked by Windows' {
  $options = [HangDumpWatchdog.ListenerOptions]::new()
  $options.Port = 0
  $log = [HangDumpWatchdog.Logger]::new((New-WorkDir), [HangDumpWatchdog.SystemClock]::new(), $false, $true)
  # A status that does not need a PowerShell runspace on the listener thread.
  $clock = [HangDumpWatchdog.ManualClock]::new([DateTime]'2026-01-01')
  $settings = $Defaults.CopyForSimulation((New-WorkDir))
  $dumps = [HangDumpWatchdog.DumpManager]::new($settings, $clock, $log, [HangDumpWatchdog.SimulatedDumpWriter]::new([HangDumpWatchdog.SimulatedDumpMode]::Failure, $clock), [HangDumpWatchdog.NullNotifier]::new())
  $probe = [HangDumpWatchdog.ScriptedProbe]::new($clock, 1e9, 1e9)
  $watchdog = [HangDumpWatchdog.Watchdog]::new($settings, $clock, $log, $probe, [HangDumpWatchdog.SimulatedSampler]::new(), $dumps)
  $listener = [HangDumpWatchdog.CommandListener]::new($options, [Func[string]]$watchdog.Status, [Func[string, bool]]$dumps.TryRequest, $log)
  Assert-True $listener.Start()
  try {
    Assert-True ($listener.BoundPort -gt 0)
    Assert-True ($listener.BoundPort -ne 47999) 'must not touch the default port'
    $client = [Net.Sockets.TcpClient]::new('127.0.0.1', $listener.BoundPort)
    $client.ReceiveTimeout = 5000
    $stream = $client.GetStream()
    $bytes = [Text.Encoding]::ASCII.GetBytes('ping')
    $stream.Write($bytes, 0, $bytes.Length)
    $reader = [IO.StreamReader]::new($stream)
    $answer = $reader.ReadLine()
    $client.Dispose()
    Assert-True ($answer -like 'pong *hung=False dump=none') "got: $answer"
  }
  finally { $listener.Stop() }
}

Write-Host 'Installer helpers'

Test-Case 'only this exact watchdog script counts as the running watchdog' {
  $script = 'C:\Program Files\HangDumpWatchdog\src\watchdog.ps1'
  Assert-True (Test-IsWatchdogCommandLine -ScriptPath $script -CommandLine '"C:\pwsh.exe" -File "C:\Program Files\HangDumpWatchdog\src\watchdog.ps1" -ConfigPath "x"')
  Assert-True (Test-IsWatchdogCommandLine -ScriptPath $script -CommandLine 'pwsh -File C:/Program Files/HangDumpWatchdog/src/watchdog.ps1')
  Assert-False (Test-IsWatchdogCommandLine -ScriptPath $script -CommandLine 'pwsh -File "D:\other\src\watchdog.ps1"')
  Assert-False (Test-IsWatchdogCommandLine -ScriptPath $script -CommandLine 'pwsh -File "C:\Program Files\HangDumpWatchdog\src\watchdog.ps1.bak"')
  Assert-False (Test-IsWatchdogCommandLine -ScriptPath $script -CommandLine '')
  Assert-False (Test-IsWatchdogCommandLine -ScriptPath $script -CommandLine $null)
}

Test-Case 'a firewall rule is planned only for a listener reachable from outside' {
  Assert-True ($null -eq (Get-FirewallPlan -Config (& $Parse '{}')))
  Assert-True ($null -eq (Get-FirewallPlan -Config (& $Parse '{ "listener": { "enabled": true } }')))
  $plan = Get-FirewallPlan -Config (& $Parse '{ "listener": { "enabled": true, "bindAddress": "0.0.0.0", "port": 50000, "allowedClients": ["10.0.0.5"] } }')
  Assert-Equal 50000 $plan.Port
  Assert-Equal '10.0.0.5' ($plan.RemoteAddress -join ',')
}

Test-Case 'the folder lock leaves only SYSTEM and Administrators, on its contents too' {
  $dir = New-WorkDir
  $sub = New-Item -ItemType Directory -Path (Join-Path $dir 'dumps')
  $file = Join-Path $sub.FullName 'file.dmp'
  Set-Content -LiteralPath $file -Value 'x'
  $me = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  try {
    Set-RestrictedAcl -Path $dir
    # The owner can always read the permissions, even with no access left to the contents. Not
    # Get-Acl: it needs to list the parent folder, which is exactly what has just been taken away.
    $security = @(
      [IO.FileSystemAclExtensions]::GetAccessControl([IO.DirectoryInfo]::new($dir)),
      [IO.FileSystemAclExtensions]::GetAccessControl([IO.DirectoryInfo]::new($sub.FullName)),
      [IO.FileSystemAclExtensions]::GetAccessControl([IO.FileInfo]::new($file))
    )
    foreach ($item in $security) {
      $sids = $item.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) |
        ForEach-Object { $_.IdentityReference.Value } | Sort-Object -Unique
      Assert-Equal 'S-1-5-18,S-1-5-32-544' ($sids -join ',')
    }
    Assert-True $security[0].AreAccessRulesProtected 'it must not inherit from the parent folder'
  }
  finally {
    # Hands the folder back so that it can be deleted without admin rights.
    & icacls.exe $dir /grant "*${me}:(OI)(CI)F" | Out-Null
    Assert-Equal 0 $LASTEXITCODE 'could not restore access to the test folder'
  }
}

Test-Case 'with UsersCanRead, Users get read access and nothing more' {
  $dir = New-WorkDir
  $me = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  try {
    Set-RestrictedAcl -Path $dir -UsersCanRead
    $rules = [IO.FileSystemAclExtensions]::GetAccessControl([IO.DirectoryInfo]::new($dir)).GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])
    $rule = $rules | Where-Object { $_.IdentityReference.Value -eq 'S-1-5-32-545' }
    Assert-True ($rule.FileSystemRights.ToString() -like 'ReadAndExecute*') $rule.FileSystemRights
  }
  finally {
    & icacls.exe $dir /grant "*${me}:(OI)(CI)F" | Out-Null
  }
}

Write-Host 'Command line (separate pwsh processes)'

$Watchdog = Join-Path $root 'src\watchdog.ps1'
$Run = {
  param([string[]]$Arguments)
  $output = & (Join-Path $PSHOME 'pwsh') -NoProfile -NonInteractive -File $Watchdog @Arguments 2>&1
  [pscustomobject]@{ Code = $LASTEXITCODE; Text = ($output -join "`n") }
}

Test-Case '-Simulate works end to end and says that nothing was real' {
  $r = & $Run @('-Simulate')
  Assert-Equal 0 $r.Code $r.Text
  Assert-True ($r.Text -like '*SIMULATION, scenario: ok*')
  Assert-True ($r.Text -like '*HANG:*')
  Assert-True ($r.Text -like '*Simulated dump requests: 2. Simulated files kept: 2. Real dumps: 0.*')
}

Test-Case '-Simulate reports the right number of files for each scenario' {
  Assert-True ((& $Run @('-Simulate', '-Scenario', 'dump-fails')).Text -like '*requests: 2. Simulated files kept: 0.*')
  Assert-True ((& $Run @('-Simulate', '-Scenario', 'dump-stuck')).Text -like '*requests: 1. Simulated files kept: 1.*')
}

Test-Case '-Simulate reads timings from -ConfigPath' {
  $config = Join-Path (New-WorkDir) 'config.json'
  Set-Content -LiteralPath $config -Value '{ "hangSeconds": 20 }'
  $r = & $Run @('-Simulate', '-ConfigPath', $config)
  Assert-Equal 0 $r.Code $r.Text
  Assert-True ($r.Text -like '*HANG: the probe has not been able to create a process for 21 s*')
}

Test-Case '-CheckConfig accepts a good file and rejects a bad one' {
  $dir = New-WorkDir
  $good = Join-Path $dir 'good.json'
  $bad = Join-Path $dir 'bad.json'
  Set-Content -LiteralPath $good -Value '{ "hangSeconds": 60 }'
  Set-Content -LiteralPath $bad -Value '{ "hangSeconds": 1 }'
  $r = & $Run @('-CheckConfig', '-ConfigPath', $good)
  Assert-Equal 0 $r.Code $r.Text
  Assert-True ($r.Text -like '*hang after 60 s*')
  $r = & $Run @('-CheckConfig', '-ConfigPath', $bad)
  Assert-Equal 2 $r.Code $r.Text
  Assert-True ($r.Text -like "*'hangSeconds' must be between*")
}

Test-Case '-TestNotify with no URL says so and sends nothing' {
  $config = Join-Path (New-WorkDir) 'config.json'
  Set-Content -LiteralPath $config -Value '{}'
  $r = & $Run @('-TestNotify', '-ConfigPath', $config)
  Assert-Equal 0 $r.Code $r.Text
  Assert-True ($r.Text -like "*notifications are off*")
}

Test-Case 'two modes at once are refused' {
  $r = & $Run @('-Simulate', '-CheckConfig')
  Assert-Equal 2 $r.Code $r.Text
  Assert-True ($r.Text -like '*use only one of*')
}

Test-Case 'Windows PowerShell 5.1 gets a clean version error' {
  $legacy = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  if (-not (Test-Path -LiteralPath $legacy)) { return }
  $output = & $legacy -NoProfile -NonInteractive -File $Watchdog -Simulate 2>&1
  Assert-True (($output -join ' ') -match 'requires|version') "got: $output"
  Assert-False (($output -join ' ') -like '*SIMULATION*') 'it should not have run'
}

Write-Host 'Repository'

$repoFiles = Get-ChildItem -LiteralPath $root -Recurse -File -Force | Where-Object { $_.FullName -notlike '*\.git\*' -and $_.Extension -ne '.png' }

Test-Case 'scripts and C# are pure ASCII, so PowerShell 5.1 can not misread them' {
  foreach ($file in $repoFiles | Where-Object Extension -in '.ps1', '.cs') {
    $bytes = [IO.File]::ReadAllBytes($file.FullName)
    Assert-False ($bytes | Where-Object { $_ -gt 127 } | Select-Object -First 1) "$($file.Name) has non-ASCII bytes"
  }
}

Test-Case 'scripts avoid the type aliases that PowerShell 5.1 does not know' {
  foreach ($file in $repoFiles | Where-Object Extension -eq '.ps1') {
    Assert-False ((Get-Content -LiteralPath $file.FullName -Raw) -match '\[(uint|ushort|ulong)(\[\])?\]') $file.Name
  }
}

Test-Case 'scripts parse without errors' {
  foreach ($file in $repoFiles | Where-Object Extension -eq '.ps1') {
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$errors)
    Assert-Equal 0 $errors.Count $file.Name
  }
}

Test-Case 'no local paths, private addresses or tokens in the files' {
  # Written so that none of these can match its own line in this file.
  $patterns = @('192\.168\.', 'ghp_[A-Za-z0-9]{20}', 'github_pat_[A-Za-z0-9]{10}', 'tk_[a-z0-9]{29}')
  if ($env:USERNAME) { $patterns += 'C:\\Users\\' + [regex]::Escape($env:USERNAME) }
  if ($env:COMPUTERNAME) { $patterns += [regex]::Escape($env:COMPUTERNAME) }
  foreach ($file in $repoFiles) {
    $text = Get-Content -LiteralPath $file.FullName -Raw
    if (-not $text) { continue }
    foreach ($pattern in $patterns) {
      Assert-False ($text -match $pattern) "$($file.Name) matches $pattern"
    }
  }
}

Test-Case 'the version in the code is the newest one in the changelog' {
  $line = Get-Content -LiteralPath (Join-Path $root 'CHANGELOG.md') | Where-Object { $_ -match '^## \[\d' } | Select-Object -First 1
  Assert-True ($line -like "## ``[$([HangDumpWatchdog.Program]::Version)``]*") "changelog says: $line"
}

Test-Case 'the workflows limit permissions and avoid pull_request_target' {
  foreach ($workflow in Get-ChildItem -LiteralPath (Join-Path $root '.github\workflows') -Filter '*.yml') {
    $text = Get-Content -LiteralPath $workflow.FullName -Raw
    Assert-True ($text -match '(?m)^permissions:') "$($workflow.Name) has no permissions block"
    Assert-False ($text -match 'pull_request_target') $workflow.Name
  }
}

Test-Case 'local config, logs and dumps are ignored by git' {
  $ignore = Get-Content -LiteralPath (Join-Path $root '.gitignore')
  foreach ($entry in 'config.json', 'logs/', 'dumps/', '*.dmp') {
    Assert-True ($ignore -contains $entry) "$entry is missing from .gitignore"
  }
}

Test-Case 'the native dump is still not armed after everything else' {
  Assert-False ([HangDumpWatchdog.LiveDumpGate]::Armed)
}

try { Remove-Item -LiteralPath $workRoot -Recurse -Force } catch { Write-Host "note: could not remove $workRoot" }

Write-Host ''
Write-Host "$($script:passed) passed, $($script:failures.Count) failed"
if ($script:failures.Count -gt 0) {
  $script:failures | ForEach-Object { Write-Host "  FAIL  $_" }
  exit 1
}
exit 0
