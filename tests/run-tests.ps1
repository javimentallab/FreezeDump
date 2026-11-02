#Requires -Version 7.4
<#
.SYNOPSIS
  Tests for the detection, the configuration, the simulation and the listener. No dependencies.

.DESCRIPTION
  They never request a kernel dump: nothing in here calls the entry points that arm the native call
  (see LiveDumpGate) and only the simulated dump writer is used. No admin rights needed. The only
  processes started are a harmless "cmd /c exit 0" for the real probe and the short pwsh runs that
  check the command line. install.ps1 and uninstall.ps1 only run with -WhatIf and temporary folders.
  The only socket is on the loopback address, on a port picked by Windows.

  Exit code 0 means every test passed.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'A console test runner: its output is for a person to read.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'New-WorkDir only creates folders inside the temporary folder of this run.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Filter is read inside Test-Case, and the unused parameter of the fake dump request is required by its delegate.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPositionalParameters', '', Justification = 'Assert-Equal expected actual reads better without parameter names.')]
param([string]$Filter = '')
$ErrorActionPreference = 'Stop'

$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src\Load-Types.ps1')
. (Join-Path $root 'src\Installer-Helpers.ps1')
. (Join-Path $PSScriptRoot 'ConvertTo-Sarif.ps1')

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

function Assert-Throw {
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

$Parse = { param($Json) [FreezeDump.WatchdogConfig]::Parse($Json, 'C:\Data\Watchdog') }
$NewDetector = { param($Hang = 45, $Max = 2, $Gap = 150) [FreezeDump.HangDetector]::new($Hang, $Max, $Gap) }
$Inf = [double]::PositiveInfinity

Write-Host 'Safety'

Test-Case 'the native dump is not armed when the tests start' {
  Assert-False ([FreezeDump.LiveDumpGate]::Armed)
}

Test-Case 'the gate refuses while it is not armed' {
  Assert-Throw { [FreezeDump.LiveDumpGate]::EnsureArmed() } 'not armed'
}

Test-Case 'only the real entry points can arm the gate: Arm is not public' {
  $arm = [FreezeDump.LiveDumpGate].GetMethod('Arm', [Reflection.BindingFlags]'Public,Static')
  Assert-True ($null -eq $arm)
}

Test-Case 'the native structure keeps its 64-byte layout' {
  Assert-Equal 64 ([FreezeDump.LiveKernelDump]::ControlStructSize)
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
  $clock = [FreezeDump.SystemClock]::new()
  $probe = [FreezeDump.ProcessProbe]::new($clock)
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
  $sample = [FreezeDump.ProcessSampler]::new([FreezeDump.SystemClock]::new()).Sample()
  Assert-True ($sample.ProcessCount -gt 0)
  Assert-True ($sample.RamPercent -gt 0 -and $sample.RamPercent -le 100)
}

Write-Host 'Configuration'

Test-Case 'the defaults are valid and keep extras off' {
  $c = [FreezeDump.WatchdogConfig]::Defaults()
  Assert-Equal 45 $c.HangSeconds
  Assert-False $c.Ntfy.Enabled
  Assert-False $c.Listener.Enabled
}

Test-Case 'config.example.json loads and matches the defaults' {
  $c = [FreezeDump.WatchdogConfig]::Load((Join-Path $root 'config.example.json'))
  $d = [FreezeDump.WatchdogConfig]::Defaults()
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
  Assert-Throw { & $Parse '{ "hangSecond": 60 }' } "unknown setting 'hangSecond'"
  Assert-Throw { & $Parse '{ "ntfy": { "ulr": "x" } }' } "unknown setting 'ntfy.ulr'"
  Assert-Throw { & $Parse '{ "listener": { "tokn": "x" } }' } "unknown setting 'listener.tokn'"
}

Test-Case 'broken JSON and wrong types give a clear error' {
  Assert-Throw { & $Parse '{ nope' } 'not valid JSON'
  Assert-Throw { & $Parse '[]' } 'JSON object'
  Assert-Throw { & $Parse '{ "hangSeconds": "45" }' } 'whole number'
  Assert-Throw { & $Parse '{ "hangSeconds": 45.5 }' } 'whole number'
  Assert-Throw { & $Parse '{ "dataDir": 3 }' } 'must be text'
  Assert-Throw { & $Parse '{ "listener": { "enabled": "yes" } }' } 'true or false'
}

Test-Case 'numbers out of range are rejected' {
  foreach ($case in @(
      @('hangSeconds', 9), @('hangSeconds', 3601), @('probeIntervalSeconds', 0), @('sampleIntervalSeconds', 0),
      @('maxDumpsPerHang', -1), @('maxDumpsPerHang', 21), @('minSecondsBetweenDumps', 29), @('keepDumps', 0),
      @('reserveFiles', -1), @('reserveFiles', 9), @('logRetentionDays', 0))) {
    Assert-Throw { & $Parse ('{ "' + $case[0] + '": ' + $case[1] + ' }') } $case[0]
  }
}

Test-Case 'the probe must run more often than the hang limit' {
  Assert-Throw { & $Parse '{ "hangSeconds": 20, "probeIntervalSeconds": 20 }' } 'lower than'
}

Test-Case 'the data folder must be local and absolute' {
  foreach ($bad in 'relative\\dir', '\\\\server\\share', '\\\\?\\C:\\x', 'C:relative', 'C:\\a\\..\\b', 'C:/x') {
    Assert-Throw { & $Parse ('{ "dataDir": "' + $bad + '" }') } 'dataDir'
  }
  Assert-Equal 'D:\Watchdog' (& $Parse '{ "dataDir": "D:\\Watchdog" }').DataDir
}

Test-Case 'notification URLs are validated' {
  foreach ($bad in 'not a url', 'ftp://ntfy.example.com/topic', 'file:///C:/x', 'https://ntfy.example.com/', 'https://user:pw@ntfy.example.com/topic',
    'http://ntfy.example.com/topic', 'http://203.0.113.5/topic', 'http://172.32.0.1/topic') {
    Assert-Throw { & $Parse ('{ "ntfy": { "url": "' + $bad + '" } }') } 'ntfy.url'
  }
  foreach ($good in 'https://ntfy.example.com/topic', 'http://localhost:8090/topic', 'http://127.0.0.1/topic', 'http://10.0.0.5/topic', 'http://172.16.0.1/topic') {
    Assert-True (& $Parse ('{ "ntfy": { "url": "' + $good + '" } }')).Ntfy.Enabled
  }
}

Test-Case 'a notification token needs a URL and has no spaces' {
  Assert-Throw { & $Parse '{ "ntfy": { "token": "abc" } }' } "'ntfy.url' is empty"
  Assert-Throw { & $Parse '{ "ntfy": { "url": "https://ntfy.example.com/t", "token": "a b" } }' } 'ntfy.token'
}

Test-Case 'listener settings are validated' {
  Assert-Throw { & $Parse '{ "listener": { "port": 80 } }' } 'listener.port'
  Assert-Throw { & $Parse '{ "listener": { "bindAddress": "somehost" } }' } 'bindAddress'
  Assert-Throw { & $Parse '{ "listener": { "allowedClients": ["nope"] } }' } 'allowedClients'
  Assert-Throw { & $Parse '{ "listener": { "token": "short" } }' } 'at least 16'
  Assert-Throw { & $Parse '{ "listener": { "token": "has a space in the middle" } }' } 'listener.token'
  Assert-Throw { & $Parse '{ "listener": { "enabled": true, "bindAddress": "0.0.0.0" } }' } 'allowedClients'
  Assert-True (& $Parse '{ "listener": { "enabled": true } }').Listener.Enabled
}

Test-Case 'tokens never appear in the summary' {
  $c = & $Parse '{ "ntfy": { "url": "https://ntfy.example.com/t", "token": "ntfysecretvalue" }, "listener": { "enabled": true, "token": "listenersecretvalue" } }'
  Assert-False ($c.Summary() -match 'secretvalue')
}

Test-Case 'the notification request is well formed and only sends a token if there is one' {
  $log = [FreezeDump.Logger]::new((New-WorkDir), [FreezeDump.SystemClock]::new(), $false, $true)
  $request = [FreezeDump.NtfyNotifier]::new('https://ntfy.example.com/t', 'tk_abc', $log).BuildRequest('Title', 'Body')
  Assert-Equal 'POST' $request.Method.Method
  Assert-Equal 'https://ntfy.example.com/t' $request.RequestUri.AbsoluteUri
  Assert-Equal 'Bearer tk_abc' ($request.Headers.GetValues('Authorization') -join '')
  Assert-Equal 'Title' ($request.Headers.GetValues('Title') -join '')
  $request = [FreezeDump.NtfyNotifier]::new('https://ntfy.example.com/t', '', $log).BuildRequest('Title', 'Body')
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
    $log = [FreezeDump.Logger]::new((New-WorkDir), [FreezeDump.SystemClock]::new(), $false, $true)
    $received = [FakeHttpServer]::ServeOnce($server)
    [FreezeDump.NtfyNotifier]::new("http://127.0.0.1:$port/test-topic", 'tk_abc', $log).Send('Title text', 'Body text')
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
  $log = [FreezeDump.Logger]::new((New-WorkDir), [FreezeDump.SystemClock]::new(), $false, $true)
  [FreezeDump.NtfyNotifier]::new("http://127.0.0.1:$port/test-topic", 'tk_secret_value', $log).Send('T', 'B')
  Assert-True ((Get-Matching $log.Lines() 'ntfy failed').Count -eq 1)
  Assert-False (($log.Lines() -join ' ') -like '*tk_secret_value*')
}

Test-Case 'no ntfy URL means no notifier that can reach the network' {
  $log = [FreezeDump.Logger]::new((New-WorkDir), [FreezeDump.SystemClock]::new(), $false, $true)
  $notifier = [FreezeDump.Notifiers]::FromConfig((& $Parse '{}'), $log)
  Assert-Equal 'NullNotifier' $notifier.GetType().Name
}

Write-Host 'Simulation'

$Defaults = [FreezeDump.WatchdogConfig]::Defaults()
$Sim = { param($Scenario, $Settings = $Defaults, $Dir = (New-WorkDir)) [FreezeDump.Simulation]::Run($Scenario, $Settings, $Dir, $false) }

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

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class FileModeProbe
{
    [StructLayout(LayoutKind.Sequential)]
    struct IoStatusBlock { public IntPtr Status; public IntPtr Information; }

    [DllImport("ntdll.dll")]
    static extern int NtQueryInformationFile(SafeFileHandle file, out IoStatusBlock status, out uint mode, int length, int infoClass);

    // Class 16 is FileModeInformation, and 0x2 in it is FILE_WRITE_THROUGH.
    public static bool IsWriteThrough(SafeFileHandle file)
    {
        IoStatusBlock status;
        uint mode;
        int result = NtQueryInformationFile(file, out status, out mode, 4, 16);
        if (result != 0) throw new InvalidOperationException("NtQueryInformationFile 0x" + result.ToString("X8"));
        return (mode & 2) != 0;
    }
}
'@

Test-Case 'dump files are written through to disk' {
  $dir = New-WorkDir
  $dump = [FreezeDump.DumpManager]::OpenDumpFile((Join-Path $dir 'dump.dmp'))
  $plain = [IO.FileStream]::new((Join-Path $dir 'plain.dmp'), [IO.FileMode]::Create)
  try {
    Assert-True ([FileModeProbe]::IsWriteThrough($dump.SafeFileHandle)) 'the dump file should be write-through'
    Assert-False ([FileModeProbe]::IsWriteThrough($plain.SafeFileHandle)) 'the probe should tell a plain file apart'
  } finally {
    $dump.Dispose()
    $plain.Dispose()
  }
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
  foreach ($scenario in [FreezeDump.Simulation]::Scenarios()) {
    Assert-False (& $Sim $scenario).RealDumpsArmed $scenario
  }
  Assert-False ([FreezeDump.LiveDumpGate]::Armed)
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
    $r = [FreezeDump.Simulation]::Run('ok', $Defaults, $null, $false)
    Assert-Equal 2 $r.DumpFiles.Count
    Assert-Equal 0 @(Get-ChildItem -LiteralPath $dir -Force).Count 'files appeared in the current folder'
  }
  finally {
    [Environment]::CurrentDirectory = $previous
  }
}

Test-Case 'a relative simulation folder is refused' {
  Assert-Throw { [FreezeDump.Simulation]::Run('ok', $Defaults, 'relative\dir', $false) } 'absolute path'
}

Test-Case 'an unknown scenario is refused' {
  Assert-Throw { [FreezeDump.Simulation]::Run('nope', $Defaults, (New-WorkDir), $false) } 'unknown scenario'
}

Test-Case 'a sampler that stops is reported, a slow but regular one is not' {
  # The check runs every 30 s and the limit is 30 s or three sampling intervals, whichever is longer.
  foreach ($case in @(@(5, 60, $true), @(60, 170, $false), @(60, 215, $true))) {
    $settings = & $Parse ('{ "sampleIntervalSeconds": ' + $case[0] + ' }')
    $settings = $settings.CopyForSimulation((New-WorkDir))
    New-Item -ItemType Directory -Path $settings.LogDir, $settings.DumpDir | Out-Null
    $clock = [FreezeDump.ManualClock]::new([DateTime]'2026-01-01')
    $log = [FreezeDump.Logger]::new($settings.LogDir, $clock, $false, $true)
    $dumps = [FreezeDump.DumpManager]::new($settings, $clock, $log, [FreezeDump.SimulatedDumpWriter]::new([FreezeDump.SimulatedDumpMode]::Failure, $clock), [FreezeDump.NullNotifier]::new())
    $probe = [FreezeDump.ScriptedProbe]::new($clock, 1e9, 1e9)
    $watchdog = [FreezeDump.Watchdog]::new($settings, $clock, $log, $probe, [FreezeDump.SimulatedSampler]::new(), $dumps)
    foreach ($second in 1..$case[1]) { $clock.Advance(1); $watchdog.Step() }
    $reported = (Get-Matching $log.Lines() 'SAMPLER STUCK').Count -gt 0
    Assert-Equal $case[2] $reported "interval $($case[0]) s, $($case[1]) s without a sample"
  }
}

Test-Case 'simulation output has no false alarms' {
  foreach ($scenario in [FreezeDump.Simulation]::Scenarios()) {
    Assert-Equal 0 (Get-Matching (& $Sim $scenario).Lines 'SAMPLER STUCK').Count $scenario
  }
}

Test-Case 'dump requests are limited by the manager as well' {
  $dir = New-WorkDir
  $settings = $Defaults.CopyForSimulation($dir)
  New-Item -ItemType Directory -Path $settings.LogDir, $settings.DumpDir | Out-Null
  $clock = [FreezeDump.ManualClock]::new([DateTime]'2026-01-01')
  $log = [FreezeDump.Logger]::new($settings.LogDir, $clock, $false, $true)
  $writer = [FreezeDump.SimulatedDumpWriter]::new([FreezeDump.SimulatedDumpMode]::Success, $clock)
  $dumps = [FreezeDump.DumpManager]::new($settings, $clock, $log, $writer, [FreezeDump.NullNotifier]::new())
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
  $log = [FreezeDump.Logger]::new((New-WorkDir), [FreezeDump.SystemClock]::new(), $false, $true)
  $status = [Func[string]] { 'pong test' }
  $dump = [Func[string, bool]] { param($why) $script:dumpCalls++; $true }
  [FreezeDump.CommandListener]::new($Options, $status, $dump, $log)
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
  $options = [FreezeDump.ListenerOptions]::new()
  $options.Port = 0
  $log = [FreezeDump.Logger]::new((New-WorkDir), [FreezeDump.SystemClock]::new(), $false, $true)
  # A status that does not need a PowerShell runspace on the listener thread.
  $clock = [FreezeDump.ManualClock]::new([DateTime]'2026-01-01')
  $settings = $Defaults.CopyForSimulation((New-WorkDir))
  $dumps = [FreezeDump.DumpManager]::new($settings, $clock, $log, [FreezeDump.SimulatedDumpWriter]::new([FreezeDump.SimulatedDumpMode]::Failure, $clock), [FreezeDump.NullNotifier]::new())
  $probe = [FreezeDump.ScriptedProbe]::new($clock, 1e9, 1e9)
  $watchdog = [FreezeDump.Watchdog]::new($settings, $clock, $log, $probe, [FreezeDump.SimulatedSampler]::new(), $dumps)
  $listener = [FreezeDump.CommandListener]::new($options, [Func[string]]$watchdog.Status, [Func[string, bool]]$dumps.TryRequest, $log)
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
  $script = 'C:\Program Files\FreezeDump\src\watchdog.ps1'
  Assert-True (Test-IsWatchdogCommandLine -ScriptPath $script -CommandLine '"C:\pwsh.exe" -File "C:\Program Files\FreezeDump\src\watchdog.ps1" -ConfigPath "x"')
  Assert-True (Test-IsWatchdogCommandLine -ScriptPath $script -CommandLine 'pwsh -File C:/Program Files/FreezeDump/src/watchdog.ps1')
  Assert-False (Test-IsWatchdogCommandLine -ScriptPath $script -CommandLine 'pwsh -File "D:\other\src\watchdog.ps1"')
  Assert-False (Test-IsWatchdogCommandLine -ScriptPath $script -CommandLine 'pwsh -File "C:\Program Files\FreezeDump\src\watchdog.ps1.bak"')
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

Test-Case 'the uninstaller finds a dataDir set in the installed config, and only that' {
  $loader = Join-Path $root 'src\Load-Types.ps1'
  $data = New-WorkDir
  Assert-True ($null -eq (Get-ConfiguredDataDir -DataDir $data -LoadTypesScript $loader)) 'no config'
  $config = Join-Path $data 'config.json'
  Set-Content -LiteralPath $config -Value '{}'
  Assert-True ($null -eq (Get-ConfiguredDataDir -DataDir $data -LoadTypesScript $loader)) 'no dataDir set'
  Set-Content -LiteralPath $config -Value ('{ "dataDir": "' + $data.Replace('\', '\\') + '" }')
  Assert-True ($null -eq (Get-ConfiguredDataDir -DataDir $data -LoadTypesScript $loader)) 'the same folder'
  Set-Content -LiteralPath $config -Value '{ "dataDir": "D:\\Elsewhere" }'
  Assert-Equal 'D:\Elsewhere' (Get-ConfiguredDataDir -DataDir $data -LoadTypesScript $loader)
}

Test-Case 'a config that can not be read does not stop the uninstaller' {
  $data = New-WorkDir
  Set-Content -LiteralPath (Join-Path $data 'config.json') -Value '{ nope'
  $found = Get-ConfiguredDataDir -DataDir $data -LoadTypesScript (Join-Path $root 'src\Load-Types.ps1') 3>$null
  Assert-True ($null -eq $found)
}

$NewOwnDataDir = {
  $own = New-WorkDir
  New-Item -ItemType Directory -Path (Join-Path $own 'dumps'), (Join-Path $own 'logs') | Out-Null
  $own
}

Test-Case 'an own dataDir loses only what the program wrote' {
  $own = & $NewOwnDataDir
  $written = 'dumps\hang-20260101-010101.dmp', 'dumps\hang-20260101-010101-rescued.dmp', 'dumps\hang-20260101-010101-rescued-2.dmp',
    'dumps\test-20260101-010101.dmp', 'dumps\reserve-1.dmp', 'logs\2026-01-01.log'
  $foreign = 'dumps\important.dmp', 'dumps\hang-notes.dmp', 'logs\other.log', 'photo.jpg'
  foreach ($name in $written + $foreign) { Set-Content -LiteralPath (Join-Path $own $name) -Value 'x' }
  Remove-WatchdogFile -Folder $own -Confirm:$false
  foreach ($name in $written) { Assert-False (Test-Path -LiteralPath (Join-Path $own $name)) "$name should be gone" }
  foreach ($name in $foreign) { Assert-True (Test-Path -LiteralPath (Join-Path $own $name)) "$name should stay" }
}

Test-Case 'an own dataDir left empty goes as well' {
  $own = & $NewOwnDataDir
  Set-Content -LiteralPath (Join-Path $own 'logs\2026-01-01.log') -Value 'x'
  Remove-WatchdogFile -Folder $own -Confirm:$false
  Assert-False (Test-Path -LiteralPath $own)
}

Write-Host 'Data folders'

function Get-AllowedSid {
  param($Security)
  return ($Security.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) |
      ForEach-Object { $_.IdentityReference.Value } | Sort-Object -Unique) -join ','
}

# Hands a locked folder back, so that it can be deleted without admin rights.
function Restore-FolderAccess {
  param([string[]]$Path)
  $me = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  foreach ($folder in $Path) {
    if (Test-Path -LiteralPath $folder) { & icacls.exe $folder /grant "*${me}:(OI)(CI)F" | Out-Null }
  }
}

Test-Case 'an elevated start locks logs and dumps with what they hold, and Administrators stay in' {
  $data = New-WorkDir
  $logs = Join-Path $data 'logs'
  $dumps = Join-Path $data 'dumps'
  New-Item -ItemType Directory -Path $logs | Out-Null
  $old = Join-Path $logs 'old.log'
  Set-Content -LiteralPath $old -Value 'x'
  try {
    $line = [FreezeDump.DataFolders]::Prepare($true, [string[]]@($logs, $dumps))
    Assert-True ($line -like 'data folders restricted*') $line
    $folders = @(
      [IO.FileSystemAclExtensions]::GetAccessControl([IO.DirectoryInfo]::new($logs)),
      [IO.FileSystemAclExtensions]::GetAccessControl([IO.DirectoryInfo]::new($dumps))
    )
    foreach ($security in $folders) {
      Assert-Equal 'S-1-5-18,S-1-5-32-544' (Get-AllowedSid $security)
      Assert-True $security.AreAccessRulesProtected 'it must not inherit from the parent folder'
      $administrators = $security.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) |
        Where-Object { $_.IdentityReference.Value -eq 'S-1-5-32-544' }
      Assert-Equal 'FullControl' $administrators.FileSystemRights.ToString()
      Assert-Equal 'ContainerInherit, ObjectInherit' $administrators.InheritanceFlags.ToString()
    }
    Assert-Equal 'S-1-5-18,S-1-5-32-544' (Get-AllowedSid ([IO.FileSystemAclExtensions]::GetAccessControl([IO.FileInfo]::new($old))))
  }
  finally { Restore-FolderAccess -Path $logs, $dumps }
}

Test-Case 'dataDir itself and what else it holds are left alone' {
  $data = New-WorkDir
  $logs = Join-Path $data 'logs'
  $keep = Join-Path $data 'keep.txt'
  Set-Content -LiteralPath $keep -Value 'mine'
  try {
    [void][FreezeDump.DataFolders]::Prepare($true, [string[]]@($logs))
    Assert-False ([IO.FileSystemAclExtensions]::GetAccessControl([IO.DirectoryInfo]::new($data)).AreAccessRulesProtected)
    Assert-Equal 'mine' (Get-Content -LiteralPath $keep -Raw).Trim()
  }
  finally { Restore-FolderAccess -Path $logs }
}

Test-Case 'without elevation the rights stay as they are, so the process can still write its log' {
  $logs = Join-Path (New-WorkDir) 'logs'
  $line = [FreezeDump.DataFolders]::Prepare($false, [string[]]@($logs))
  Assert-True ($line -like '*NOT restricted*') $line
  Assert-False ([IO.FileSystemAclExtensions]::GetAccessControl([IO.DirectoryInfo]::new($logs)).AreAccessRulesProtected)
  Set-Content -LiteralPath (Join-Path $logs 'today.log') -Value 'x'
}

Test-Case 'a folder that can not be prepared stops the start, with the reason' {
  $notAFolder = Join-Path (New-WorkDir) 'file'
  Set-Content -LiteralPath $notAFolder -Value 'x'
  Assert-Throw { [FreezeDump.DataFolders]::Prepare($true, [string[]]@($notAFolder)) } 'cannot prepare'
}

Test-Case 'the process knows whether it is elevated' {
  Assert-Equal (Test-IsAdministrator) ([FreezeDump.DataFolders]::ProcessIsElevated())
}

Test-Case 'every real entry point prepares its folders and none creates them on its own' {
  $code = Get-Content -LiteralPath (Join-Path $root 'src\Watchdog.cs') -Raw
  Assert-False ($code -match 'Directory\.CreateDirectory')
  Assert-Equal 3 ([regex]::Matches($code, 'DataFolders\.Prepare\(DataFolders\.ProcessIsElevated\(\)').Count)
}

Write-Host 'Command line (separate pwsh processes)'

$Watchdog = Join-Path $root 'src\watchdog.ps1'
$Run = {
  param([string[]]$Arguments)
  $output = & (Join-Path $PSHOME 'pwsh') -NoProfile -NonInteractive -File $Watchdog @Arguments 2>&1
  [pscustomobject]@{ Code = $LASTEXITCODE; Text = ($output -join "`n") }
}

# Always with -WhatIf: these tests must not be able to install or uninstall anything.
$RunWhatIf = {
  param([string]$Script, [string[]]$Arguments)
  $output = & (Join-Path $PSHOME 'pwsh') -NoProfile -NonInteractive -File (Join-Path $root $Script) -WhatIf @Arguments 2>&1
  [pscustomobject]@{ Code = $LASTEXITCODE; Text = ($output -join "`n") }
}

Test-Case 'install.ps1 -WhatIf changes nothing and says so' {
  $work = New-WorkDir
  $program = Join-Path $work 'program'
  $data = Join-Path $work 'data'
  $r = & $RunWhatIf 'install.ps1' @('-InstallDir', $program, '-DataDir', $data)
  Assert-Equal 0 $r.Code $r.Text
  Assert-True ($r.Text -like '*Nothing was changed*') $r.Text
  Assert-False ($r.Text -like '*next logon*') 'nothing was registered, so nothing starts at the next logon'
  Assert-False (Test-Path -LiteralPath $program)
  Assert-False (Test-Path -LiteralPath $data)
}

Test-Case 'install.ps1 locks only the logs and dumps of an own dataDir' {
  $work = New-WorkDir
  $data = Join-Path $work 'data'
  $own = Join-Path $work 'own'
  New-Item -ItemType Directory -Path $data | Out-Null
  Set-Content -LiteralPath (Join-Path $data 'config.json') -Value ('{ "dataDir": "' + $own.Replace('\', '\\') + '" }')
  $r = & $RunWhatIf 'install.ps1' @('-InstallDir', (Join-Path $work 'program'), '-DataDir', $data)
  Assert-Equal 0 $r.Code $r.Text
  Assert-True $r.Text.Contains("`"$own\logs`"") $r.Text
  Assert-True $r.Text.Contains("`"$own\dumps`"") $r.Text
  Assert-False $r.Text.Contains("`"$own`"") 'the folder itself can hold other things'
  Assert-False (Test-Path -LiteralPath $own)
}

Test-Case 'uninstall.ps1 -WhatIf -RemoveData changes nothing and lists the logs and dumps of an own dataDir' {
  $work = New-WorkDir
  $data = Join-Path $work 'data'
  $own = & $NewOwnDataDir
  New-Item -ItemType Directory -Path $data | Out-Null
  Set-Content -LiteralPath (Join-Path $data 'config.json') -Value ('{ "dataDir": "' + $own.Replace('\', '\\') + '" }')
  $dump = Join-Path $own 'dumps\hang-20260101-010101.dmp'
  $foreign = Join-Path $own 'dumps\important.dmp'
  Set-Content -LiteralPath $dump -Value 'x'
  Set-Content -LiteralPath $foreign -Value 'x'
  $r = & $RunWhatIf 'uninstall.ps1' @('-RemoveData', '-InstallDir', (Join-Path $work 'program'), '-DataDir', $data)
  Assert-Equal 0 $r.Code $r.Text
  Assert-True $r.Text.Contains($dump) $r.Text
  Assert-False $r.Text.Contains($foreign) $r.Text
  Assert-True (Test-Path -LiteralPath $dump)
  Assert-True (Test-Path -LiteralPath (Join-Path $data 'config.json'))
}

Test-Case 'without -RemoveData the uninstaller says where the logs and dumps of an own dataDir stay' {
  $work = New-WorkDir
  $data = Join-Path $work 'data'
  New-Item -ItemType Directory -Path $data | Out-Null
  Set-Content -LiteralPath (Join-Path $data 'config.json') -Value '{ "dataDir": "D:\\Elsewhere" }'
  $r = & $RunWhatIf 'uninstall.ps1' @('-InstallDir', (Join-Path $work 'program'), '-DataDir', $data)
  Assert-Equal 0 $r.Code $r.Text
  Assert-True ($r.Text -like '*also in D:\Elsewhere*') $r.Text
}

Test-Case 'install.ps1 and the installed copy of the watchdog work in one console' {
  $work = New-WorkDir
  $copy = Join-Path $work 'installed'
  New-Item -ItemType Directory -Path $copy | Out-Null
  Copy-Item -LiteralPath (Join-Path $root 'src') -Destination $copy -Recurse
  $install = Join-Path $root 'install.ps1'
  $installedWatchdog = Join-Path $copy 'src\watchdog.ps1'
  $command = "& '$install' -WhatIf -InstallDir '$work\program' -DataDir '$work\data' | Out-Null; & '$installedWatchdog' -ShowVersion"
  $output = (& (Join-Path $PSHOME 'pwsh') -NoProfile -NonInteractive -Command $command 2>&1) -join "`n"
  Assert-True ($output -like "*FreezeDump $([FreezeDump.Program]::Version)*") $output
}

Test-Case 'a downloaded copy runs only after Unblock-File, as the README says' {
  if ((Get-ExecutionPolicy -Scope MachinePolicy) -ne 'Undefined') { return }
  $copy = New-WorkDir
  Copy-Item -LiteralPath (Join-Path $root 'src') -Destination $copy -Recurse
  foreach ($file in Get-ChildItem -LiteralPath $copy -Recurse -File) {
    Set-Content -LiteralPath $file.FullName -Stream Zone.Identifier -Value "[ZoneTransfer]`r`nZoneId=3"
  }
  $script = Join-Path $copy 'src\watchdog.ps1'
  $version = "*FreezeDump $([FreezeDump.Program]::Version)*"
  $blocked = (& (Join-Path $PSHOME 'pwsh') -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File $script -ShowVersion 2>&1) -join "`n"
  Assert-False ($blocked -like $version) 'a file from the internet should have been refused'
  Get-ChildItem -LiteralPath $copy -Recurse -File | Unblock-File
  $unblocked = (& (Join-Path $PSHOME 'pwsh') -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File $script -ShowVersion 2>&1) -join "`n"
  Assert-True ($unblocked -like $version) $unblocked
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

Test-Case 'no command is glued to its first argument' {
  foreach ($file in $repoFiles | Where-Object Extension -eq '.ps1') {
    $lines = Get-Matching (Get-Content -LiteralPath $file.FullName) '\bWrite-(Output|Host|Warning)["'']'
    Assert-Equal 0 $lines.Count "$($file.Name): $($lines -join ' / ')"
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
  Assert-True ($line -like "## ``[$([FreezeDump.Program]::Version)``]*") "changelog says: $line"
}

Test-Case 'the workflows limit permissions and avoid pull_request_target' {
  foreach ($workflow in Get-ChildItem -LiteralPath (Join-Path $root '.github\workflows') -Filter '*.yml') {
    $text = Get-Content -LiteralPath $workflow.FullName -Raw
    Assert-True ($text -match '(?m)^permissions:') "$($workflow.Name) has no permissions block"
    Assert-False ($text -match 'pull_request_target') $workflow.Name
  }
}

Test-Case 'every Action is pinned to a full commit, with its version in a comment' {
  foreach ($workflow in Get-ChildItem -LiteralPath (Join-Path $root '.github\workflows') -Filter '*.yml') {
    foreach ($line in Get-Content -LiteralPath $workflow.FullName | Where-Object { $_ -match '^\s*(- )?uses:' }) {
      Assert-True ($line -match '@[0-9a-f]{40} # v\d') "$($workflow.Name): $line"
    }
  }
}

Test-Case 'Trivy fails on HIGH or CRITICAL and its image goes by digest' {
  $text = Get-Content -LiteralPath (Join-Path $root '.github\workflows\trivy.yml') -Raw
  Assert-True ($text -match '--severity CRITICAL,HIGH\s+\\\s+--exit-code 1')
  Assert-False ($text -match '--exit-code 0')
  $images = [regex]::Matches($text, 'ghcr\.io/aquasecurity/trivy\S*')
  Assert-True ($images.Count -gt 0)
  foreach ($image in $images) { Assert-True ($image.Value -match '@sha256:[0-9a-f]{64}$') $image.Value }
}

Test-Case 'the PowerShell scripts are analyzed in CI and the results reach GitHub Security' {
  $text = Get-Content -LiteralPath (Join-Path $root '.github\workflows\psscriptanalyzer.yml') -Raw
  Assert-True ($text -match 'tests/run-analyzer\.ps1 .*-SarifPath analyzer-results\.sarif')
  Assert-True ($text -match 'upload-sarif@')
  Assert-True ($text -match 'sarif_file: analyzer-results\.sarif')
  Assert-True ($text -match 'Save-Module -Name PSScriptAnalyzer -RequiredVersion \d') 'the version must be fixed'
}

Test-Case 'analyzer results become SARIF with relative paths and the right levels' {
  $results = @(
    [pscustomobject]@{ ScriptPath = 'C:\Some\Repo\src\a.ps1'; RuleName = 'RuleA'; Severity = 'Warning'; Message = 'first'; Line = 3; Column = 5 },
    [pscustomobject]@{ ScriptPath = 'C:\Some\Repo\b.ps1'; RuleName = 'RuleB'; Severity = 'Information'; Message = 'second'; Line = 0; Column = 0 },
    [pscustomobject]@{ ScriptPath = 'D:\Elsewhere\c.ps1'; RuleName = 'RuleA'; Severity = 'ParseError'; Message = 'third'; Line = 1; Column = 1 }
  )
  $json = ConvertTo-AnalyzerSarif -Results $results -Root 'C:\Some\Repo' -ToolVersion '1.2.3'
  $sarif = $json | ConvertFrom-Json
  Assert-Equal '2.1.0' $sarif.version
  $run = $sarif.runs[0]
  Assert-Equal '1.2.3' $run.tool.driver.version
  Assert-Equal 'RuleA,RuleB' (@($run.tool.driver.rules | ForEach-Object id) -join ',')
  Assert-Equal 'warning,note,error' (@($run.results | ForEach-Object level) -join ',')
  Assert-Equal 'src/a.ps1' $run.results[0].locations[0].physicalLocation.artifactLocation.uri
  Assert-Equal 3 $run.results[0].locations[0].physicalLocation.region.startLine
  Assert-Equal 1 $run.results[1].locations[0].physicalLocation.region.startLine 'SARIF lines start at 1'
  Assert-Equal 'c.ps1' $run.results[2].locations[0].physicalLocation.artifactLocation.uri
  Assert-False ($json -like '*Elsewhere*') 'no local path in the report'
}

Test-Case 'no analyzer results is still valid SARIF' {
  $sarif = ConvertTo-AnalyzerSarif -Results @() -Root 'C:\Some\Repo' -ToolVersion '1.2.3' | ConvertFrom-Json
  Assert-Equal 0 @($sarif.runs[0].results).Count
}

Test-Case 'scripts started by hand require PowerShell 7.4, and the READMEs say so' {
  foreach ($script in 'install.ps1', 'uninstall.ps1', 'src\watchdog.ps1', 'tests\run-tests.ps1', 'tests\run-analyzer.ps1') {
    Assert-Equal '#Requires -Version 7.4' (Get-Content -LiteralPath (Join-Path $root $script) -TotalCount 1) $script
  }
  $readmes = @{
    'README.md'    = Get-Content -LiteralPath (Join-Path $root 'README.md') -Raw
    'README.es.md' = Get-Content -LiteralPath (Join-Path $root 'README.es.md') -Raw
  }
  foreach ($name in $readmes.Keys) { Assert-True ($readmes[$name] -match 'PowerShell 7\.4') $name }
}

$ReadmeEn = Get-Content -LiteralPath (Join-Path $root 'README.md')
$ReadmeEs = Get-Content -LiteralPath (Join-Path $root 'README.es.md')

Test-Case 'both READMEs have the same structure and the same commands' {
  foreach ($pattern in '^#', '^\|', '^```', '^\| *-', '^> ') {
    Assert-Equal (Get-Matching $ReadmeEn $pattern).Count (Get-Matching $ReadmeEs $pattern).Count "lines matching $pattern"
  }
  $commands = {
    param($Lines)
    (Get-Matching $Lines '^(\.\\|pwsh |git |cd |printf |Get-ChildItem |Copy-Item )') | ForEach-Object { ($_ -replace '\s+#.*$', '').Trim() }
  }
  Assert-Equal ((& $commands $ReadmeEn) -join "`n") ((& $commands $ReadmeEs) -join "`n")
}

Test-Case 'both READMEs say how to get the code and what to do with a ZIP' {
  foreach ($readme in @($ReadmeEn, $ReadmeEs)) {
    Assert-Equal 1 (Get-Matching $readme '^git clone https://github\.com/javimentallab/FreezeDump$').Count
    Assert-Equal 1 (Get-Matching $readme '^Get-ChildItem -Recurse -File \| Unblock-File$').Count
  }
}

Test-Case 'both READMEs run the installed watchdog in a new process' {
  foreach ($readme in @($ReadmeEn, $ReadmeEs)) {
    Assert-Equal 1 (Get-Matching $readme '^pwsh -File "\$env:ProgramFiles\\FreezeDump\\src\\watchdog\.ps1" -TestDump$').Count
    Assert-Equal 0 (Get-Matching $readme '^& ').Count
  }
}

Test-Case 'both READMEs explain -ReplaceConfig and what -RemoveData does in an own dataDir' {
  foreach ($readme in @($ReadmeEn, $ReadmeEs)) {
    Assert-True ((Get-Matching $readme '-ReplaceConfig').Count -ge 1)
    Assert-True ((Get-Matching $readme '`dataDir`, `-RemoveData`').Count -ge 1)
  }
}

Test-Case 'the tests never call the entry points that arm the native call' {
  $text = Get-Content -LiteralPath $PSCommandPath -Raw
  foreach ($entry in ('::Run' + 'Forever'), ('::Run' + 'TestDump')) {
    Assert-False $text.Contains($entry) $entry
  }
}

Test-Case 'local config, logs and dumps are ignored by git' {
  $ignore = Get-Content -LiteralPath (Join-Path $root '.gitignore')
  foreach ($entry in 'config.json', 'logs/', 'dumps/', '*.dmp') {
    Assert-True ($ignore -contains $entry) "$entry is missing from .gitignore"
  }
}

Test-Case 'the native dump is still not armed after everything else' {
  Assert-False ([FreezeDump.LiveDumpGate]::Armed)
}

try { Remove-Item -LiteralPath $workRoot -Recurse -Force } catch { Write-Host "note: could not remove $workRoot" }

Write-Host ''
Write-Host "$($script:passed) passed, $($script:failures.Count) failed"
if ($script:failures.Count -gt 0) {
  $script:failures | ForEach-Object { Write-Host "  FAIL  $_" }
  exit 1
}
exit 0
