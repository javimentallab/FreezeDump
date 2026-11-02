// Shared building blocks: clocks, the write-through logger, number formatting and the data folders.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;

namespace FreezeDump
{
    // Dumps hold kernel memory and logs say what was running, so only SYSTEM and Administrators can
    // reach them, wherever the config puts them. Only the "logs" and "dumps" folders are locked, not
    // "dataDir" itself: that can be any folder on the PC, even one that holds other things.
    public static class DataFolders
    {
        public static bool ProcessIsElevated()
        {
            using (WindowsIdentity identity = WindowsIdentity.GetCurrent())
                return new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator);
        }

        // Creates the folders and returns a line for the log. An elevated process keeps its access,
        // through Administrators. One that is not elevated would lock itself out of its own log, and
        // can not request a dump anyway, so it leaves the rights as they are.
        // If a folder can not be locked this throws: the caller must not write a dump in there.
        public static string Prepare(bool elevated, params string[] folders)
        {
            foreach (string folder in folders)
            {
                try
                {
                    Directory.CreateDirectory(folder);
                    if (elevated) Restrict(folder);
                }
                catch (Exception e)
                {
                    // No inner exception: the startup error shows the innermost message only.
                    throw new InvalidOperationException("cannot prepare " + folder + ": " + e.Message);
                }
            }
            return elevated
                ? "data folders restricted to SYSTEM and Administrators"
                : "data folders NOT restricted: this process is not elevated";
        }

        static void Restrict(string folder)
        {
            var security = new DirectorySecurity();
            security.SetAccessRuleProtection(true, false);
            foreach (WellKnownSidType sid in new[] { WellKnownSidType.LocalSystemSid, WellKnownSidType.BuiltinAdministratorsSid })
            {
                security.AddAccessRule(new FileSystemAccessRule(
                    new SecurityIdentifier(sid, null),
                    FileSystemRights.FullControl,
                    InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit,
                    PropagationFlags.None,
                    AccessControlType.Allow));
            }
            new DirectoryInfo(folder).SetAccessControl(security);
        }
    }

    public interface IClock
    {
        DateTime Now { get; }

        // Monotonic seconds: not affected by clock changes or daylight saving.
        double Seconds { get; }
    }

    public sealed class SystemClock : IClock
    {
        readonly Stopwatch watch = Stopwatch.StartNew();
        public DateTime Now { get { return DateTime.Now; } }
        public double Seconds { get { return watch.Elapsed.TotalSeconds; } }
    }

    // Virtual time for the simulation and the tests: it only moves when told to.
    public sealed class ManualClock : IClock
    {
        readonly DateTime start;
        readonly object gate = new object();
        double seconds;

        public ManualClock(DateTime start) { this.start = start; }

        public DateTime Now { get { lock (gate) return start.AddSeconds(seconds); } }
        public double Seconds { get { lock (gate) return seconds; } }
        public void Advance(double by) { lock (gate) seconds += by; }
    }

    public static class Fmt
    {
        public static readonly CultureInfo Inv = CultureInfo.InvariantCulture;

        public static string Size(long bytes)
        {
            if (bytes >= 1048576) return (bytes / 1048576).ToString(Inv) + " MB";
            if (bytes >= 1024) return (bytes / 1024).ToString(Inv) + " KB";
            return bytes.ToString(Inv) + " B";
        }

        public static string F0(double v) { return v.ToString("F0", Inv); }
        public static string F1(double v) { return v.ToString("F1", Inv); }
    }

    public sealed class Logger
    {
        readonly string dir;
        readonly IClock clock;
        readonly bool echo;
        readonly object gate = new object();
        readonly List<string> lines = new List<string>();
        readonly bool capture;

        public Logger(string dir, IClock clock, bool echoToConsole, bool captureLines)
        {
            this.dir = dir;
            this.clock = clock;
            echo = echoToConsole;
            capture = captureLines;
        }

        public void Write(string message)
        {
            DateTime now = clock.Now;
            string line = now.ToString("HH:mm:ss.fff", Fmt.Inv) + " " + message;
            lock (gate)
            {
                if (capture) lines.Add(line);
                if (echo) Console.Out.WriteLine(line);
                try
                {
                    string file = Path.Combine(dir, now.ToString("yyyy-MM-dd", Fmt.Inv) + ".log");
                    // WriteThrough: the line has to survive a reset with the power button.
                    using (var fs = new FileStream(file, FileMode.Append, FileAccess.Write, FileShare.ReadWrite, 4096, FileOptions.WriteThrough))
                    {
                        byte[] bytes = Encoding.UTF8.GetBytes(line + "\r\n");
                        fs.Write(bytes, 0, bytes.Length);
                    }
                }
                catch
                {
                    // Logging must never take the watchdog down.
                }
            }
        }

        public List<string> Lines()
        {
            lock (gate) return new List<string>(lines);
        }
    }
}
