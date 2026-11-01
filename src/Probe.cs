// The health check (start a console process and wait for it) and the periodic system sample.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading;

namespace HangDumpWatchdog
{
    public interface IProbe
    {
        void Kick();
        bool Running { get; }
        double PendingSeconds { get; }
        double LastMs { get; }
        string LastError { get; }
    }

    // Starts "cmd.exe /c exit 0" and measures how long it takes. It runs on its own thread, so
    // when process creation blocks only that thread blocks and the pending time keeps growing.
    public sealed class ProcessProbe : IProbe
    {
        readonly IClock clock;
        readonly string cmdPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "cmd.exe");
        volatile int running;
        double startedAt;
        double lastMs = -1;
        volatile string lastError = "";

        public ProcessProbe(IClock clock) { this.clock = clock; }

        public bool Running { get { return running == 1; } }
        public double LastMs { get { return Volatile.Read(ref lastMs); } }
        public string LastError { get { return lastError; } }

        public double PendingSeconds
        {
            get { return running == 1 ? clock.Seconds - Volatile.Read(ref startedAt) : 0; }
        }

        public void Kick()
        {
            if (running == 1) return;
            Volatile.Write(ref startedAt, clock.Seconds);
            running = 1;
            var t = new Thread(() =>
            {
                try
                {
                    var psi = new ProcessStartInfo(cmdPath, "/c exit 0") { UseShellExecute = false, CreateNoWindow = true };
                    using (Process p = Process.Start(psi)) { p.WaitForExit(); }
                    Volatile.Write(ref lastMs, (clock.Seconds - Volatile.Read(ref startedAt)) * 1000.0);
                    lastError = "";
                }
                catch (Exception e)
                {
                    lastError = e.GetType().Name + ": " + e.Message;
                }
                running = 0;
            });
            t.IsBackground = true;
            t.Name = "probe";
            t.Start();
        }
    }

    public struct SampleData
    {
        public int RamPercent;
        public long IdleSeconds;
        public int ProcessCount;
        public string Cpu;
        public string Changes;
    }

    public interface ISampler
    {
        SampleData Sample();
    }

    // What goes in the log every few seconds: memory, input idle time, top CPU, started and ended processes.
    public sealed class ProcessSampler : ISampler
    {
        [StructLayout(LayoutKind.Sequential)]
        struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }

        [DllImport("user32.dll")]
        static extern bool GetLastInputInfo(ref LASTINPUTINFO info);

        [StructLayout(LayoutKind.Sequential)]
        struct MEMORYSTATUSEX
        {
            public uint dwLength, dwMemoryLoad;
            public ulong total, avail, totalPage, availPage, totalVirtual, availVirtual, availExtended;
        }

        [DllImport("kernel32.dll")]
        static extern bool GlobalMemoryStatusEx(ref MEMORYSTATUSEX status);

        readonly IClock clock;
        Dictionary<int, string> previous = new Dictionary<int, string>();
        Dictionary<int, TimeSpan> previousCpu = new Dictionary<int, TimeSpan>();
        double previousAt;

        public ProcessSampler(IClock clock)
        {
            this.clock = clock;
            previousAt = clock.Seconds;
        }

        public SampleData Sample()
        {
            double now = clock.Seconds;
            double elapsed = now - previousAt;
            previousAt = now;
            var current = new Dictionary<int, string>();
            var cpu = new Dictionary<int, TimeSpan>();
            var top = new List<KeyValuePair<double, string>>();
            foreach (Process p in Process.GetProcesses())
            {
                try
                {
                    current[p.Id] = p.ProcessName;
                    TimeSpan used;
                    try { used = p.TotalProcessorTime; } catch { continue; }
                    cpu[p.Id] = used;
                    TimeSpan before;
                    if (previousCpu.TryGetValue(p.Id, out before) && elapsed > 0)
                    {
                        double percent = (used - before).TotalSeconds / elapsed / Environment.ProcessorCount * 100;
                        if (percent >= 1)
                            top.Add(new KeyValuePair<double, string>(percent, p.ProcessName + "(" + p.Id + ")=" + Fmt.F0(percent) + "%"));
                    }
                }
                catch { }
                finally { p.Dispose(); }
            }

            var data = new SampleData();
            var input = new LASTINPUTINFO { cbSize = 8 };
            data.IdleSeconds = GetLastInputInfo(ref input) ? ((uint)Environment.TickCount - input.dwTime) / 1000 : -1;
            var memory = new MEMORYSTATUSEX { dwLength = (uint)Marshal.SizeOf(typeof(MEMORYSTATUSEX)) };
            GlobalMemoryStatusEx(ref memory);
            data.RamPercent = (int)memory.dwMemoryLoad;
            data.ProcessCount = current.Count;
            data.Cpu = string.Join(" ", top.OrderByDescending(x => x.Key).Take(5).Select(x => x.Value));
            data.Changes = "";
            if (previous.Count > 0)
            {
                var started = current.Where(x => !previous.ContainsKey(x.Key)).Select(x => "+" + x.Value);
                var ended = previous.Where(x => !current.ContainsKey(x.Key)).Select(x => "-" + x.Value);
                data.Changes = string.Join(" ", started.Concat(ended).Take(30));
            }
            previous = current;
            previousCpu = cpu;
            return data;
        }
    }
}
