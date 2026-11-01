// Settings: defaults, JSON parsing and validation. Nothing in here touches the system.
using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Text.Json;

namespace HangDumpWatchdog
{
    public sealed class ConfigException : Exception
    {
        public ConfigException(string message) : base(message) { }
    }

    public sealed class NtfyOptions
    {
        public string Url = "";
        public string Token = "";
        public bool Enabled { get { return Url != ""; } }
    }

    public sealed class ListenerOptions
    {
        public const int MinTokenLength = 16;

        public bool Enabled = false;
        public string BindAddress = "127.0.0.1";
        public int Port = 47999;
        public string[] AllowedClients = new string[0];
        public string Token = "";
    }

    public sealed class WatchdogConfig
    {
        public string DataDir = "";
        public int HangSeconds = 45;
        public int ProbeIntervalSeconds = 10;
        public int SampleIntervalSeconds = 5;
        public int MaxDumpsPerHang = 2;
        public int MinSecondsBetweenDumps = 150;
        public int KeepDumps = 4;
        public int ReserveFiles = 2;
        public int LogRetentionDays = 30;
        public NtfyOptions Ntfy = new NtfyOptions();
        public ListenerOptions Listener = new ListenerOptions();

        public string LogDir { get { return Path.Combine(DataDir, "logs"); } }
        public string DumpDir { get { return Path.Combine(DataDir, "dumps"); } }

        public static string DefaultDataDir()
        {
            return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "HangDumpWatchdog");
        }

        public static string DefaultConfigPath()
        {
            return Path.Combine(DefaultDataDir(), "config.json");
        }

        public static WatchdogConfig Defaults()
        {
            var c = new WatchdogConfig();
            c.DataDir = DefaultDataDir();
            c.Validate();
            return c;
        }

        // A relative or empty "dataDir" is not allowed in the file; empty means "next to this file".
        public static WatchdogConfig Load(string path)
        {
            string full = Path.GetFullPath(path);
            string json;
            try { json = File.ReadAllText(full); }
            catch (Exception e) { throw new ConfigException("cannot read config file: " + e.Message); }
            return Parse(json, Path.GetDirectoryName(full));
        }

        public static WatchdogConfig Parse(string json, string defaultDataDir)
        {
            var options = new JsonDocumentOptions { CommentHandling = JsonCommentHandling.Skip, AllowTrailingCommas = true };
            JsonDocument doc;
            try { doc = JsonDocument.Parse(json, options); }
            catch (JsonException e) { throw new ConfigException("config is not valid JSON: " + e.Message); }
            using (doc)
            {
                if (doc.RootElement.ValueKind != JsonValueKind.Object) throw new ConfigException("config must be a JSON object");
                var c = new WatchdogConfig();
                foreach (JsonProperty p in doc.RootElement.EnumerateObject())
                {
                    switch (p.Name)
                    {
                        case "dataDir": c.DataDir = Str(p); break;
                        case "hangSeconds": c.HangSeconds = Int(p); break;
                        case "probeIntervalSeconds": c.ProbeIntervalSeconds = Int(p); break;
                        case "sampleIntervalSeconds": c.SampleIntervalSeconds = Int(p); break;
                        case "maxDumpsPerHang": c.MaxDumpsPerHang = Int(p); break;
                        case "minSecondsBetweenDumps": c.MinSecondsBetweenDumps = Int(p); break;
                        case "keepDumps": c.KeepDumps = Int(p); break;
                        case "reserveFiles": c.ReserveFiles = Int(p); break;
                        case "logRetentionDays": c.LogRetentionDays = Int(p); break;
                        case "ntfy": ParseNtfy(p, c.Ntfy); break;
                        case "listener": ParseListener(p, c.Listener); break;
                        default: throw new ConfigException("unknown setting '" + p.Name + "'");
                    }
                }
                if (c.DataDir == "") c.DataDir = string.IsNullOrEmpty(defaultDataDir) ? DefaultDataDir() : defaultDataDir;
                c.DataDir = Environment.ExpandEnvironmentVariables(c.DataDir);
                c.Validate();
                return c;
            }
        }

        static void ParseNtfy(JsonProperty parent, NtfyOptions n)
        {
            RequireObject(parent);
            foreach (JsonProperty p in parent.Value.EnumerateObject())
            {
                switch (p.Name)
                {
                    case "url": n.Url = Str(p); break;
                    case "token": n.Token = Str(p); break;
                    default: throw new ConfigException("unknown setting 'ntfy." + p.Name + "'");
                }
            }
        }

        static void ParseListener(JsonProperty parent, ListenerOptions l)
        {
            RequireObject(parent);
            foreach (JsonProperty p in parent.Value.EnumerateObject())
            {
                switch (p.Name)
                {
                    case "enabled":
                        if (p.Value.ValueKind != JsonValueKind.True && p.Value.ValueKind != JsonValueKind.False)
                            throw new ConfigException("'listener.enabled' must be true or false");
                        l.Enabled = p.Value.GetBoolean();
                        break;
                    case "bindAddress": l.BindAddress = Str(p); break;
                    case "port": l.Port = Int(p); break;
                    case "token": l.Token = Str(p); break;
                    case "allowedClients":
                        if (p.Value.ValueKind != JsonValueKind.Array) throw new ConfigException("'listener.allowedClients' must be a list");
                        var list = new List<string>();
                        foreach (JsonElement e in p.Value.EnumerateArray())
                        {
                            if (e.ValueKind != JsonValueKind.String) throw new ConfigException("'listener.allowedClients' must only contain text");
                            list.Add(e.GetString());
                        }
                        l.AllowedClients = list.ToArray();
                        break;
                    default: throw new ConfigException("unknown setting 'listener." + p.Name + "'");
                }
            }
        }

        static void RequireObject(JsonProperty p)
        {
            if (p.Value.ValueKind != JsonValueKind.Object) throw new ConfigException("'" + p.Name + "' must be an object");
        }

        static string Str(JsonProperty p)
        {
            if (p.Value.ValueKind != JsonValueKind.String) throw new ConfigException("'" + p.Name + "' must be text");
            return p.Value.GetString();
        }

        static int Int(JsonProperty p)
        {
            int v;
            if (p.Value.ValueKind != JsonValueKind.Number || !p.Value.TryGetInt32(out v))
                throw new ConfigException("'" + p.Name + "' must be a whole number");
            return v;
        }

        public void Validate()
        {
            Range("hangSeconds", HangSeconds, 10, 3600);
            Range("probeIntervalSeconds", ProbeIntervalSeconds, 1, 600);
            Range("sampleIntervalSeconds", SampleIntervalSeconds, 1, 3600);
            Range("maxDumpsPerHang", MaxDumpsPerHang, 0, 20);
            Range("minSecondsBetweenDumps", MinSecondsBetweenDumps, 30, 86400);
            Range("keepDumps", KeepDumps, 1, 100);
            Range("reserveFiles", ReserveFiles, 0, 8);
            Range("logRetentionDays", LogRetentionDays, 1, 3650);
            if (ProbeIntervalSeconds >= HangSeconds)
                throw new ConfigException("'probeIntervalSeconds' must be lower than 'hangSeconds'");
            ValidateDataDir(DataDir);
            ValidateNtfy(Ntfy);
            ValidateListener(Listener);
        }

        static void Range(string name, int value, int min, int max)
        {
            if (value < min || value > max)
                throw new ConfigException("'" + name + "' must be between " + min + " and " + max + " (got " + value + ")");
        }

        // Kernel dumps stay on a local drive: no relative paths and no network or device paths.
        static void ValidateDataDir(string dir)
        {
            bool driveRooted = dir.Length >= 3 && ((dir[0] >= 'A' && dir[0] <= 'Z') || (dir[0] >= 'a' && dir[0] <= 'z')) && dir[1] == ':' && dir[2] == '\\';
            if (!driveRooted) throw new ConfigException("'dataDir' must be an absolute path on a local drive, like D:\\Watchdog");
            foreach (string part in dir.Split('\\'))
                if (part == "..") throw new ConfigException("'dataDir' must not contain '..'");
        }

        static void ValidateNtfy(NtfyOptions n)
        {
            if (n.Token != "" && !IsPrintableToken(n.Token)) throw new ConfigException("'ntfy.token' has spaces or control characters");
            if (n.Url == "")
            {
                if (n.Token != "") throw new ConfigException("'ntfy.token' is set but 'ntfy.url' is empty");
                return;
            }
            Uri u;
            if (!Uri.TryCreate(n.Url, UriKind.Absolute, out u)) throw new ConfigException("'ntfy.url' is not a valid URL");
            if (u.Scheme != Uri.UriSchemeHttps && u.Scheme != Uri.UriSchemeHttp) throw new ConfigException("'ntfy.url' must use https");
            if (u.UserInfo != "") throw new ConfigException("'ntfy.url' must not contain a user or password; use 'ntfy.token'");
            if (u.AbsolutePath.Trim('/') == "") throw new ConfigException("'ntfy.url' must include the topic, like https://ntfy.example.com/my-topic");
            if (u.Scheme == Uri.UriSchemeHttp && !IsLocalAddress(u.Host))
                throw new ConfigException("'ntfy.url' can only use plain http for a loopback or private LAN address");
        }

        static void ValidateListener(ListenerOptions l)
        {
            Range("listener.port", l.Port, 1024, 65535);
            IPAddress bind;
            if (!IPAddress.TryParse(l.BindAddress, out bind)) throw new ConfigException("'listener.bindAddress' is not an IP address");
            foreach (string c in l.AllowedClients)
            {
                IPAddress ignored;
                if (!IPAddress.TryParse(c, out ignored)) throw new ConfigException("'listener.allowedClients' has an invalid IP address: " + c);
            }
            if (l.Token != "")
            {
                if (!IsPrintableToken(l.Token)) throw new ConfigException("'listener.token' has spaces or control characters");
                if (l.Token.Length < ListenerOptions.MinTokenLength)
                    throw new ConfigException("'listener.token' must have at least " + ListenerOptions.MinTokenLength + " characters");
            }
            if (l.Enabled && !IPAddress.IsLoopback(bind) && l.AllowedClients.Length == 0)
                throw new ConfigException("'listener.allowedClients' is empty, so nobody could connect to 'listener.bindAddress'");
        }

        static bool IsPrintableToken(string s)
        {
            foreach (char ch in s) if (ch <= ' ' || ch > '~') return false;
            return true;
        }

        public static bool IsLocalAddress(string host)
        {
            if (string.Equals(host, "localhost", StringComparison.OrdinalIgnoreCase)) return true;
            IPAddress ip;
            if (!IPAddress.TryParse(host.Trim('[', ']'), out ip)) return false;
            if (IPAddress.IsLoopback(ip)) return true;
            byte[] b = ip.GetAddressBytes();
            if (b.Length != 4) return ip.IsIPv6LinkLocal || ip.IsIPv6SiteLocal;
            return b[0] == 10 || (b[0] == 172 && b[1] >= 16 && b[1] <= 31) || (b[0] == 192 && b[1] == 168);
        }

        // For the startup log line. Tokens must never appear here.
        public string Summary()
        {
            return "hang after " + HangSeconds + " s, probe every " + ProbeIntervalSeconds + " s, up to " + MaxDumpsPerHang +
                   " dumps per hang, keeping " + KeepDumps + ", notifications " + (Ntfy.Enabled ? "on" : "off") +
                   ", listener " + (Listener.Enabled ? "on" : "off");
        }

        public WatchdogConfig CopyForSimulation(string dataDir)
        {
            if (!Path.IsPathFullyQualified(dataDir)) throw new ArgumentException("the simulation folder must be an absolute path");
            var c = (WatchdogConfig)MemberwiseClone();
            c.DataDir = dataDir;
            c.Ntfy = new NtfyOptions();
            c.Listener = new ListenerOptions();
            return c;
        }
    }
}
