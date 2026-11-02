// Runs the real detection, reserve and rotation code on a virtual clock with a pretend hang.
// No kernel dump is requested, no process is started, nothing leaves the PC, and the output
// only has made-up data, because the system sample, the probe and the dump writer are all fakes.
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;

namespace FreezeDump
{
    public sealed class ScriptedProbe : IProbe
    {
        readonly IClock clock;
        readonly double hangFrom;
        readonly double hangUntil;
        double startedAt;
        double finishesAt = double.NegativeInfinity;
        double lastMs = -1;
        int kicks;

        public ScriptedProbe(IClock clock, double hangFrom, double hangUntil)
        {
            this.clock = clock;
            this.hangFrom = hangFrom;
            this.hangUntil = hangUntil;
        }

        public bool Running { get { return clock.Seconds < finishesAt; } }
        public double PendingSeconds { get { return Running ? clock.Seconds - startedAt : 0; } }
        public string LastError { get { return ""; } }

        public double LastMs { get { return lastMs; } }

        public void Kick()
        {
            if (Running) return;
            kicks++;
            startedAt = clock.Seconds;
            bool hung = startedAt >= hangFrom && startedAt < hangUntil;
            finishesAt = hung ? hangUntil : startedAt; // a healthy probe ends within the same virtual instant
            lastMs = hung ? (hangUntil - startedAt) * 1000.0 : 40 + (kicks * 7) % 17;
        }
    }

    public sealed class SimulatedSampler : ISampler
    {
        int count;

        public SampleData Sample()
        {
            count++;
            var d = new SampleData();
            d.RamPercent = 41 + count % 3;
            d.IdleSeconds = count % 4;
            d.ProcessCount = 212 + count % 5;
            d.Cpu = "demo-app(4120)=" + (9 + count % 6) + "% demo-db(2204)=" + (2 + count % 3) + "%";
            d.Changes = count % 6 == 0 ? "+demo-job -demo-job" : "";
            return d;
        }
    }

    public enum SimulatedDumpMode { Success, Failure, Stuck }

    public sealed class SimulatedDumpWriter : IDumpWriter
    {
        const string Marker = "SIMULATED: this file is not a kernel dump.\r\n";
        public const int FailureStatus = unchecked((int)0xC0000022); // STATUS_ACCESS_DENIED

        readonly SimulatedDumpMode mode;
        readonly ManualClock clock;
        readonly ManualResetEventSlim entered = new ManualResetEventSlim(false);
        readonly ManualResetEventSlim release = new ManualResetEventSlim(false);

        public SimulatedDumpWriter(SimulatedDumpMode mode, ManualClock clock)
        {
            this.mode = mode;
            this.clock = clock;
        }

        public int Write(FileStream file)
        {
            if (mode == SimulatedDumpMode.Failure)
            {
                return FailureStatus;
            }

            byte[] body = Encoding.ASCII.GetBytes(string.Concat(Enumerable.Repeat(Marker, 100)));
            file.Write(body, 0, body.Length);
            file.Flush();

            if (mode == SimulatedDumpMode.Stuck)
            {
                entered.Set();
                release.Wait();
                throw new IOException("simulated power cut");
            }

            clock.Advance(2); // a real dump freezes the PC for about this long
            return 0;
        }

        public bool WaitEntered(int milliseconds) { return entered.Wait(milliseconds); }
        public void Release() { release.Set(); }
    }

    public sealed class RecordingNotifier : INotifier
    {
        readonly Logger log;
        readonly List<string> sent = new List<string>();

        public RecordingNotifier(Logger log) { this.log = log; }

        public void Send(string title, string message)
        {
            lock (sent) sent.Add(title + ": " + message);
            log.Write("notification (simulated): " + title);
        }

        public List<string> Sent()
        {
            lock (sent) return new List<string>(sent);
        }
    }

    public sealed class SimulationResult
    {
        public string Scenario;
        public List<string> Lines = new List<string>();
        public List<string> Notifications = new List<string>();
        public List<string> DumpFiles = new List<string>();
        public List<string> OtherFiles = new List<string>();
        public int DumpRequests;
        public bool FinalHung;
        public bool RealDumpsArmed;
    }

    public static class Simulation
    {
        public const string ScenarioOk = "ok";
        public const string ScenarioFails = "dump-fails";
        public const string ScenarioStuck = "dump-stuck";

        const int HangStartsAt = 20;
        const int ShownSampleEvery = 30;
        const int SimulatedPid = 4242;
        static readonly DateTime VirtualStart = new DateTime(2026, 3, 14, 3, 12, 0);

        public static string[] Scenarios() { return new[] { ScenarioOk, ScenarioFails, ScenarioStuck }; }

        // workDir: where the simulated files go. Empty means a temporary folder, deleted at the end.
        // (Empty and not only null: PowerShell turns $null into "" when it calls a .NET method.)
        public static SimulationResult Run(string scenario, WatchdogConfig settings, string workDir, bool echoToConsole)
        {
            if (Array.IndexOf(Scenarios(), scenario) < 0)
                throw new ArgumentException("unknown scenario: " + scenario);

            bool temporary = string.IsNullOrEmpty(workDir);
            string dir = temporary ? Path.Combine(Path.GetTempPath(), "FreezeDump-sim-" + Guid.NewGuid().ToString("N")) : workDir;
            WatchdogConfig cfg = settings.CopyForSimulation(dir);
            cfg.SampleIntervalSeconds = ShownSampleEvery;
            Directory.CreateDirectory(cfg.LogDir);
            Directory.CreateDirectory(cfg.DumpDir);

            var clock = new ManualClock(VirtualStart);
            var log = new Logger(cfg.LogDir, clock, echoToConsole, true);
            var notifier = new RecordingNotifier(log);
            var result = new SimulationResult { Scenario = scenario };

            SimulatedDumpMode mode = scenario == ScenarioFails ? SimulatedDumpMode.Failure
                                   : scenario == ScenarioStuck ? SimulatedDumpMode.Stuck
                                   : SimulatedDumpMode.Success;
            var writer = new SimulatedDumpWriter(mode, clock);
            var dumps = new DumpManager(cfg, clock, log, writer, notifier) { InlineNotifications = true };

            bool stuck = mode == SimulatedDumpMode.Stuck;
            int hangEndsAt = stuck ? int.MaxValue : HangStartsAt + cfg.HangSeconds + cfg.MinSecondsBetweenDumps + 45;
            int totalSteps = stuck ? HangStartsAt + cfg.HangSeconds + 60 : hangEndsAt + 20;

            var watchdog = new Watchdog(cfg, clock, log, new ScriptedProbe(clock, HangStartsAt, hangEndsAt), new SimulatedSampler(), dumps);
            watchdog.Start(SimulatedPid, "not used in a simulation");

            for (int step = 1; step <= totalSteps; step++)
            {
                clock.Advance(1);
                if (step == HangStartsAt) log.Write("[simulation] process creation hangs from now on");
                watchdog.Step();
                if (dumps.Running)
                {
                    if (stuck) writer.WaitEntered(10000);
                    else dumps.WaitIdle(10000);
                }
                if (step % cfg.SampleIntervalSeconds == 0) watchdog.SampleOnce();
            }

            result.FinalHung = watchdog.Hung;
            result.DumpRequests = dumps.Requests;

            if (stuck)
            {
                log.Write("[simulation] the dump never returns; power button pressed, next boot follows");
                dumps.Abandon();
                writer.Release();
                dumps.WaitIdle(10000);
                dumps.CloseReserves();

                string partial = Path.Combine(cfg.DumpDir, "reserve-1.dmp");
                if (File.Exists(partial)) File.SetLastWriteTime(partial, clock.Now);
                clock.Advance(60);

                var nextBoot = new DumpManager(cfg, clock, log, new SimulatedDumpWriter(SimulatedDumpMode.Success, clock), notifier) { InlineNotifications = true };
                new Watchdog(cfg, clock, log, new ScriptedProbe(clock, double.MaxValue, double.MaxValue), new SimulatedSampler(), nextBoot)
                    .Start(SimulatedPid, "not used in a simulation");
                nextBoot.CloseReserves();
            }
            else
            {
                dumps.CloseReserves();
            }

            result.Lines = log.Lines();
            result.Notifications = notifier.Sent();
            foreach (FileInfo f in new DirectoryInfo(cfg.DumpDir).GetFiles().OrderBy(x => x.Name))
            {
                if (f.Name.StartsWith("hang-", StringComparison.Ordinal)) result.DumpFiles.Add(f.Name);
                else result.OtherFiles.Add(f.Name);
            }
            result.RealDumpsArmed = LiveDumpGate.Armed;

            if (temporary)
            {
                try { Directory.Delete(dir, true); } catch { }
            }
            return result;
        }
    }
}
