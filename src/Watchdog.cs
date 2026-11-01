// The main loop and the real entry points. Each part runs on its own thread, so one of them
// getting stuck does not stop the others.
using System;
using System.IO;
using System.Text;
using System.Threading;

namespace HangDumpWatchdog
{
    public sealed class Watchdog
    {
        readonly WatchdogConfig cfg;
        readonly IClock clock;
        readonly Logger log;
        readonly IProbe probe;
        readonly ISampler sampler;
        readonly DumpManager dumps;
        readonly HangDetector detector;
        long tick;
        double lastBeat;

        public Watchdog(WatchdogConfig cfg, IClock clock, Logger log, IProbe probe, ISampler sampler, DumpManager dumps)
        {
            this.cfg = cfg;
            this.clock = clock;
            this.log = log;
            this.probe = probe;
            this.sampler = sampler;
            this.dumps = dumps;
            detector = new HangDetector(cfg.HangSeconds, cfg.MaxDumpsPerHang, cfg.MinSecondsBetweenDumps);
            lastBeat = clock.Seconds;
        }

        public bool Hung { get { return detector.Hung; } }

        public void Start(int processId, string debugPrivilege)
        {
            log.Write("=== HangDumpWatchdog " + Program.Version + " starting, pid " + processId + ", SeDebugPrivilege: " + debugPrivilege);
            log.Write(cfg.Summary());
            dumps.Purge();
            dumps.PrepareReserves();
        }

        // One second of the main loop.
        public void Step()
        {
            tick++;
            if (tick % cfg.ProbeIntervalSeconds == 0) probe.Kick();

            double pending = probe.PendingSeconds;
            DetectorDecision d = detector.Tick(pending, probe.Running, dumps.Running, dumps.SecondsSinceLastDump);
            if (d.HangStarted)
                log.Write("HANG: the probe has not been able to create a process for " + Fmt.F0(pending) + " s");
            if (d.RequestDump)
                dumps.TryRequest("probe stuck " + Fmt.F0(pending) + " s (" + d.DumpNumber + "/" + cfg.MaxDumpsPerHang + ")");
            if (d.Recovered)
                log.Write("RECOVERED: the probe can create processes again");

            if (dumps.TakeStuckAlert())
            {
                string where = "'" + dumps.Stage + "'";
                log.Write("DUMP STUCK: " + Fmt.F0(dumps.RunningForSeconds) + " s so far in step " + where);
                dumps.Notify("Kernel dump stuck", "The dump has been running for over " + DumpManager.StuckAfterSeconds + " s, in step " + where + ". It may never finish.");
            }

            double beatAge = clock.Seconds - Volatile.Read(ref lastBeat);
            if (beatAge > Math.Max(30, cfg.SampleIntervalSeconds * 3) && tick % 30 == 0)
                log.Write("SAMPLER STUCK: last sample " + Fmt.F0(beatAge) + " s ago");
        }

        public void SampleOnce()
        {
            string line;
            try { line = FormatSample(sampler.Sample(), probe); }
            catch (Exception e) { line = "sample failed: " + e.Message; }
            Volatile.Write(ref lastBeat, clock.Seconds);
            log.Write(line);
        }

        public static string FormatSample(SampleData d, IProbe probe)
        {
            var sb = new StringBuilder();
            sb.Append("ram=").Append(d.RamPercent).Append("% idle=").Append(d.IdleSeconds).Append("s probe=");
            if (probe.Running) sb.Append("PEND ").Append(Fmt.F0(probe.PendingSeconds)).Append('s');
            else if (probe.LastMs < 0) sb.Append("none");
            else sb.Append(Fmt.F0(probe.LastMs)).Append("ms");
            if (probe.LastError != "") sb.Append(" probeError=").Append(probe.LastError);
            sb.Append(" procs=").Append(d.ProcessCount).Append(" cpu: ").Append(d.Cpu);
            if (!string.IsNullOrEmpty(d.Changes)) sb.Append(" | ").Append(d.Changes);
            return sb.ToString();
        }

        // The answer to "ping". Goes over the network: state only, no paths or settings.
        public string Status()
        {
            string dump = dumps.Running
                ? "RUNNING-" + Fmt.F0(dumps.RunningForSeconds) + "s(" + dumps.Stage + ")"
                : dumps.LastResult;
            return "pong " + clock.Now.ToString("HH:mm:ss", Fmt.Inv) +
                   " beat=" + Fmt.F0(clock.Seconds - Volatile.Read(ref lastBeat)) + "s" +
                   " probe_pending=" + Fmt.F0(probe.PendingSeconds) + "s" +
                   " probe_last=" + Fmt.F0(probe.LastMs) + "ms" +
                   " hung=" + Hung + " dump=" + dump;
        }
    }

    // The only entry points that can request a real dump. Neither the simulation nor the tests call them.
    public static class Program
    {
        public const string Version = "0.1.0";
        const string MutexName = @"Global\HangDumpWatchdog";
        static Mutex instance;

        public const int ExitAlreadyRunning = 3;

        // Blocks forever. It only returns if another instance already holds the mutex.
        public static int RunForever(WatchdogConfig cfg)
        {
            Directory.CreateDirectory(cfg.LogDir);
            Directory.CreateDirectory(cfg.DumpDir);
            IClock clock = new SystemClock();
            var log = new Logger(cfg.LogDir, clock, false, false);

            bool owner = false;
            try { instance = new Mutex(true, MutexName, out owner); }
            catch (UnauthorizedAccessException) { owner = false; }
            if (!owner)
            {
                log.Write("another instance is already running, exiting");
                return ExitAlreadyRunning;
            }

            LiveDumpGate.Arm();
            string privilege = LiveKernelDump.EnableDebugPrivilege();
            var dumps = new DumpManager(cfg, clock, log, new LiveKernelDump(), Notifiers.FromConfig(cfg, log));
            var watchdog = new Watchdog(cfg, clock, log, new ProcessProbe(clock), new ProcessSampler(clock), dumps);
            watchdog.Start(Environment.ProcessId, privilege);

            if (cfg.Listener.Enabled)
                new CommandListener(cfg.Listener, watchdog.Status, dumps.TryRequest, log).Start();

            var sampling = new Thread(() =>
            {
                while (true)
                {
                    watchdog.SampleOnce();
                    Thread.Sleep(cfg.SampleIntervalSeconds * 1000);
                }
            });
            sampling.IsBackground = true;
            sampling.Name = "sampler";
            sampling.Start();

            while (true)
            {
                Thread.Sleep(1000);
                watchdog.Step();
            }
        }

        // One real dump on request, to check that this PC supports it. The caller asks for confirmation.
        public static string RunTestDump(WatchdogConfig cfg)
        {
            Directory.CreateDirectory(cfg.DumpDir);
            string privilege = LiveKernelDump.EnableDebugPrivilege();
            string path = Path.Combine(cfg.DumpDir, "test-" + DateTime.Now.ToString("yyyyMMdd-HHmmss", Fmt.Inv) + ".dmp");
            LiveDumpGate.Arm();
            var watch = System.Diagnostics.Stopwatch.StartNew();
            int status;
            long length;
            using (var fs = new FileStream(path, FileMode.Create, FileAccess.ReadWrite, FileShare.Read))
            {
                status = new LiveKernelDump().Write(fs);
                length = fs.Length;
            }
            return "SeDebugPrivilege: " + privilege + "\nstatus 0x" + status.ToString("X8", Fmt.Inv) + ", " + Fmt.Size(length) + ", " +
                   Fmt.F1(watch.Elapsed.TotalSeconds) + " s -> " + path;
        }

        public static string SendTestNotification(WatchdogConfig cfg)
        {
            if (!cfg.Ntfy.Enabled) return "notifications are off: 'ntfy.url' is empty";
            Directory.CreateDirectory(cfg.LogDir);
            var log = new Logger(cfg.LogDir, new SystemClock(), true, false);
            new NtfyNotifier(cfg.Ntfy.Url, cfg.Ntfy.Token, log).Send("HangDumpWatchdog test", "If you can read this, notifications work.");
            return "test notification attempted (the line above has the result)";
        }
    }
}
