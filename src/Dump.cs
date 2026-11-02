// The native live kernel dump call and everything around it: reserve files, one dump at a
// time, rotation and what to do when a dump fails.
using System;
using System.ComponentModel;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading;

namespace FreezeDump
{
    // Second safety catch next to the simulation: the native call refuses to run until the real
    // entry points in Program arm this gate. Simulations and tests do not call those entry points.
    public static class LiveDumpGate
    {
        static volatile bool armed;

        public static bool Armed { get { return armed; } }

        internal static void Arm() { armed = true; }

        public static void EnsureArmed()
        {
            if (!armed) throw new InvalidOperationException("real kernel dumps are not armed in this process");
        }
    }

    public interface IDumpWriter
    {
        // Writes the dump into an already open file and returns an NTSTATUS (0 means success).
        int Write(FileStream file);
    }

    public sealed class LiveKernelDump : IDumpWriter
    {
        const int SysDbgGetLiveKernelDump = 37;
        const uint LiveSystemDumpCode = 0x161; // LIVE_SYSTEM_DUMP

        // Undocumented structure: layout known from public reverse-engineering notes, see README.
        [StructLayout(LayoutKind.Sequential)]
        struct SYSDBG_LIVEDUMP_CONTROL
        {
            public uint Version;
            public uint BugCheckCode;
            public UIntPtr P1, P2, P3, P4;
            public IntPtr DumpFileHandle;
            public IntPtr CancelEventHandle;
            public uint Flags;
            public uint AddPagesControl;
        }

        [DllImport("ntdll.dll")]
        static extern int NtSystemDebugControl(int command, ref SYSDBG_LIVEDUMP_CONTROL input, int inputLength, IntPtr output, int outputLength, out int returned);

        [StructLayout(LayoutKind.Sequential, Pack = 4)]
        struct TOKEN_PRIVILEGES { public uint Count; public long Luid; public uint Attributes; }

        [DllImport("advapi32.dll", SetLastError = true)]
        static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);

        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern bool LookupPrivilegeValue(string system, string name, out long luid);

        [DllImport("advapi32.dll", SetLastError = true)]
        static extern bool AdjustTokenPrivileges(IntPtr token, bool disableAll, ref TOKEN_PRIVILEGES state, int length, IntPtr previous, IntPtr returned);

        [DllImport("kernel32.dll")]
        static extern IntPtr GetCurrentProcess();

        [DllImport("kernel32.dll")]
        static extern bool CloseHandle(IntPtr handle);

        public static int ControlStructSize { get { return Marshal.SizeOf(typeof(SYSDBG_LIVEDUMP_CONTROL)); } }

        public int Write(FileStream file)
        {
            LiveDumpGate.EnsureArmed();
            var control = new SYSDBG_LIVEDUMP_CONTROL();
            control.Version = 1;
            control.BugCheckCode = LiveSystemDumpCode;
            control.DumpFileHandle = file.SafeFileHandle.DangerousGetHandle();
            control.Flags = 0; // kernel memory only, uncompressed
            int returned;
            return NtSystemDebugControl(SysDbgGetLiveKernelDump, ref control, Marshal.SizeOf(control), IntPtr.Zero, 0, out returned);
        }

        // Returns "ok" or the reason. Error 1300 means the process is not elevated.
        public static string EnableDebugPrivilege()
        {
            IntPtr token;
            if (!OpenProcessToken(GetCurrentProcess(), 0x28 /* ADJUST_PRIVILEGES | QUERY */, out token))
                return "OpenProcessToken error " + Marshal.GetLastWin32Error();
            try
            {
                long luid;
                if (!LookupPrivilegeValue(null, "SeDebugPrivilege", out luid))
                    return "LookupPrivilegeValue error " + Marshal.GetLastWin32Error();
                var state = new TOKEN_PRIVILEGES { Count = 1, Luid = luid, Attributes = 2 /* ENABLED */ };
                AdjustTokenPrivileges(token, false, ref state, Marshal.SizeOf(state), IntPtr.Zero, IntPtr.Zero);
                int error = Marshal.GetLastWin32Error();
                return error == 0 ? "ok" : "AdjustTokenPrivileges error " + error;
            }
            finally { CloseHandle(token); }
        }
    }

    public sealed class DumpManager
    {
        public const string StageCreating = "creating the file";
        public const string StageNative = "inside NtSystemDebugControl";
        public const string StageClosing = "closing the file";
        public const string StageRenaming = "renaming";
        public const int StuckAfterSeconds = 30;

        readonly WatchdogConfig cfg;
        readonly IClock clock;
        readonly Logger log;
        readonly IDumpWriter writer;
        readonly INotifier notifier;
        readonly FileStream[] reserves;
        readonly object reserveGate = new object();
        readonly object requestGate = new object();
        readonly ManualResetEventSlim idle = new ManualResetEventSlim(true);

        volatile int running;
        volatile string stage = "";
        volatile string lastResult = "none";
        volatile bool abandoned;
        double startedAt;
        double lastDumpAt = double.NegativeInfinity;
        bool stuckReported;

        public int Requests { get; private set; }

        // The simulation keeps its output in order by sending notifications from the calling thread.
        public bool InlineNotifications { get; set; }

        public DumpManager(WatchdogConfig cfg, IClock clock, Logger log, IDumpWriter writer, INotifier notifier)
        {
            this.cfg = cfg;
            this.clock = clock;
            this.log = log;
            this.writer = writer;
            this.notifier = notifier;
            reserves = new FileStream[cfg.ReserveFiles];
        }

        public bool Running { get { return running == 1; } }
        public string Stage { get { return stage; } }
        public string LastResult { get { return lastResult; } }

        public double SecondsSinceLastDump
        {
            get { lock (requestGate) return clock.Seconds - lastDumpAt; }
        }

        public double RunningForSeconds
        {
            get { lock (requestGate) return running == 1 ? clock.Seconds - startedAt : 0; }
        }

        public int ReservesOpen
        {
            get { lock (reserveGate) return reserves.Count(r => r != null); }
        }

        public bool TryRequest(string why)
        {
            lock (requestGate)
            {
                if (running == 1)
                {
                    log.Write("DUMP already in progress, ignoring (" + why + ")");
                    return false;
                }
                if (clock.Seconds - lastDumpAt < cfg.MinSecondsBetweenDumps)
                {
                    log.Write("DUMP too soon after the previous one, ignoring (" + why + ")");
                    return false;
                }
                running = 1;
                idle.Reset();
                lastDumpAt = clock.Seconds;
                startedAt = lastDumpAt;
                stuckReported = false;
                Requests++;
            }
            var t = new Thread(() => Work(why));
            t.IsBackground = true;
            t.Name = "dump";
            t.Start();
            return true;
        }

        // True once per dump, when it has been running for too long.
        public bool TakeStuckAlert()
        {
            lock (requestGate)
            {
                if (running != 1 || stuckReported || clock.Seconds - startedAt <= StuckAfterSeconds) return false;
                stuckReported = true;
                return true;
            }
        }

        public void Notify(string title, string message)
        {
            if (InlineNotifications) { SafeSend(title, message); return; }
            var t = new Thread(() => SafeSend(title, message));
            t.IsBackground = true;
            t.Name = "notify";
            t.Start();
        }

        void SafeSend(string title, string message)
        {
            try { notifier.Send(title, message); }
            catch (Exception e) { log.Write("notification failed: " + e.Message); }
        }

        string ReservePath(int i) { return Path.Combine(cfg.DumpDir, "reserve-" + (i + 1) + ".dmp"); }

        // Written through to disk: in a real hang the threads that write cached files to disk were
        // stuck on NTFS locks, and only part of a cached dump had reached the disk at the reset.
        public static FileStream OpenDumpFile(string path)
        {
            return new FileStream(path, FileMode.Create, FileAccess.ReadWrite, FileShare.Read, 4096, FileOptions.WriteThrough);
        }

        void Work(string why)
        {
            string finalPath = Path.Combine(cfg.DumpDir, "hang-" + clock.Now.ToString("yyyyMMdd-HHmmss", Fmt.Inv) + ".dmp");
            string path = null;
            FileStream fs = null;
            lock (reserveGate)
            {
                for (int i = 0; i < reserves.Length && fs == null; i++)
                {
                    if (reserves[i] != null)
                    {
                        fs = reserves[i];
                        path = ReservePath(i);
                        reserves[i] = null;
                    }
                }
            }

            double began = clock.Seconds;
            string status;
            string shortStatus;
            long length = 0;
            try
            {
                if (fs != null)
                {
                    log.Write("DUMP requested (" + why + ") -> " + Path.GetFileName(path) + " (reserve already open)");
                }
                else
                {
                    path = finalPath;
                    log.Write("DUMP requested (" + why + ") -> " + Path.GetFileName(path) + " (NO reserve: creating the file now)");
                    stage = StageCreating;
                    fs = OpenDumpFile(path);
                }
                stage = StageNative;
                int ntstatus = writer.Write(fs);
                status = "0x" + ntstatus.ToString("X8", Fmt.Inv);
                shortStatus = status;
                stage = StageClosing;
                try { length = fs.Length; } catch { }
            }
            catch (Exception e)
            {
                status = "EXC " + e.GetType().Name + ": " + e.Message;
                shortStatus = e.GetType().Name;
            }
            finally
            {
                try { if (fs != null) fs.Dispose(); } catch { }
            }

            if (abandoned)
            {
                // Only the simulated power cut gets here: the file stays exactly as it was.
                stage = "";
                running = 0;
                idle.Set();
                return;
            }

            string size = Fmt.Size(length);
            lastResult = clock.Now.ToString("HH:mm:ss", Fmt.Inv) + " " + shortStatus + " " + size;
            log.Write("DUMP finished: status " + status + ", " + size + ", " + Fmt.F1(clock.Seconds - began) + " s");
            bool ok = status == "0x00000000" && length > 0;

            // The notification first, it does not touch the disk; the rename after it could block.
            if (ok) SafeSend("Kernel dump saved", "Kernel dump saved (" + size + "). Reason: " + why + ". You can power-cycle the PC now if it is stuck.");
            else SafeSend("Kernel dump FAILED", "Status " + shortStatus + ". Reason: " + why + ".");

            stage = StageRenaming;
            if (path != finalPath)
            {
                if (ok)
                {
                    try
                    {
                        File.Move(path, finalPath);
                        log.Write("DUMP renamed to " + Path.GetFileName(finalPath));
                    }
                    catch (Exception e)
                    {
                        log.Write("DUMP could not be renamed, it stays as " + Path.GetFileName(path) + ": " + e.Message);
                    }
                }
                else
                {
                    try { if (length == 0) File.Delete(path); } catch { }
                }
            }
            else if (!ok)
            {
                try { if (length == 0 && path != null) File.Delete(path); } catch { }
            }
            if (ok) Purge();
            stage = "";
            running = 0;
            PrepareReserves();
            idle.Set();
        }

        // Keeps the dump files open in advance, so writing a dump does not depend on being able
        // to create a file during the hang. A reserve that holds data is what a dump left behind
        // when the PC was reset before it could be renamed: it is kept instead of overwritten.
        public void PrepareReserves()
        {
            for (int i = 0; i < reserves.Length; i++)
            {
                lock (reserveGate) { if (reserves[i] != null) continue; }
                string path = ReservePath(i);
                try
                {
                    var info = new FileInfo(path);
                    if (info.Exists && info.Length > 0)
                    {
                        string stamp = info.LastWriteTime.ToString("yyyyMMdd-HHmmss", Fmt.Inv);
                        string target = Path.Combine(cfg.DumpDir, "hang-" + stamp + "-rescued.dmp");
                        if (File.Exists(target)) target = Path.Combine(cfg.DumpDir, "hang-" + stamp + "-rescued-" + (i + 1) + ".dmp");
                        long length = info.Length;
                        File.Move(path, target);
                        log.Write("reserve with data from an earlier run rescued -> " + Path.GetFileName(target) + " (" + Fmt.Size(length) + ")");
                    }
                    FileStream fs = OpenDumpFile(path);
                    lock (reserveGate) reserves[i] = fs;
                }
                catch (Exception e)
                {
                    log.Write("cannot prepare " + Path.GetFileName(path) + ": " + e.Message);
                }
            }
            log.Write("dump reserves open: " + ReservesOpen + "/" + reserves.Length);
        }

        public void Purge()
        {
            try
            {
                var oldDumps = new DirectoryInfo(cfg.DumpDir).GetFiles("hang-*.dmp")
                    .OrderByDescending(x => x.LastWriteTimeUtc).ThenByDescending(x => x.Name).Skip(cfg.KeepDumps);
                foreach (FileInfo old in oldDumps)
                {
                    log.Write("deleting old dump " + old.Name);
                    old.Delete();
                }
                DateTime limit = clock.Now.AddDays(-cfg.LogRetentionDays);
                foreach (FileInfo old in new DirectoryInfo(cfg.LogDir).GetFiles("*.log").Where(x => x.LastWriteTime < limit))
                    old.Delete();
            }
            catch (Exception e)
            {
                log.Write("purge failed: " + e.Message);
            }
        }

        public bool WaitIdle(int milliseconds) { return idle.Wait(milliseconds); }

        // Simulation only: makes a blocked dump end as if the power had been cut.
        internal void Abandon() { abandoned = true; }

        public void CloseReserves()
        {
            lock (reserveGate)
            {
                for (int i = 0; i < reserves.Length; i++)
                {
                    if (reserves[i] == null) continue;
                    try { reserves[i].Dispose(); } catch { }
                    reserves[i] = null;
                }
            }
        }
    }
}
