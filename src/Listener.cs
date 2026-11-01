// Optional TCP listener for a monitor on another machine. Off by default.
//   "ping"          -> one line with the current state
//   "<token> dump"  -> asks for a dump (only if a token is configured)
using System;
using System.Collections.Generic;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;

namespace HangDumpWatchdog
{
    public sealed class CommandListener
    {
        readonly ListenerOptions options;
        readonly Func<string> status;
        readonly Func<string, bool> requestDump;
        readonly Logger log;
        readonly HashSet<IPAddress> allowed;
        TcpListener listener;

        public int BoundPort { get; private set; }

        public CommandListener(ListenerOptions options, Func<string> status, Func<string, bool> requestDump, Logger log)
        {
            this.options = options;
            this.status = status;
            this.requestDump = requestDump;
            this.log = log;
            allowed = new HashSet<IPAddress>(options.AllowedClients.Select(IPAddress.Parse));
        }

        public bool IsAllowed(IPAddress address)
        {
            return IPAddress.IsLoopback(address) || allowed.Contains(address);
        }

        public string Handle(IPAddress remote, string command)
        {
            if (command == "ping") return status();
            if (options.Token != "" && TokenMatches(command))
                return requestDump("requested over TCP") ? "ok requested" : "ignored: busy or too soon";
            log.Write("unknown command from " + remote);
            return "?";
        }

        // Constant-time for commands of the right length.
        bool TokenMatches(string command)
        {
            byte[] expected = Encoding.ASCII.GetBytes(options.Token + " dump");
            byte[] actual = Encoding.ASCII.GetBytes(command);
            if (expected.Length != actual.Length) return false;
            int difference = 0;
            for (int i = 0; i < expected.Length; i++) difference |= expected[i] ^ actual[i];
            return difference == 0;
        }

        public bool Start()
        {
            try
            {
                listener = new TcpListener(IPAddress.Parse(options.BindAddress), options.Port);
                listener.Start();
                BoundPort = ((IPEndPoint)listener.LocalEndpoint).Port;
            }
            catch (Exception e)
            {
                log.Write("cannot listen on TCP " + options.Port + ": " + e.Message);
                return false;
            }
            log.Write("listening on TCP " + BoundPort);
            var t = new Thread(Loop);
            t.IsBackground = true;
            t.Name = "listener";
            t.Start();
            return true;
        }

        public void Stop()
        {
            try { if (listener != null) listener.Stop(); } catch { }
        }

        void Loop()
        {
            while (true)
            {
                try
                {
                    using (TcpClient client = listener.AcceptTcpClient())
                    {
                        var endpoint = (IPEndPoint)client.Client.RemoteEndPoint;
                        if (!IsAllowed(endpoint.Address))
                        {
                            log.Write("connection refused from " + endpoint.Address);
                            continue;
                        }
                        client.ReceiveTimeout = 5000;
                        client.SendTimeout = 5000;
                        NetworkStream stream = client.GetStream();
                        var buffer = new byte[256];
                        int read = stream.Read(buffer, 0, buffer.Length);
                        string command = Encoding.ASCII.GetString(buffer, 0, Math.Max(0, read)).Trim();
                        byte[] answer = Encoding.ASCII.GetBytes(Handle(endpoint.Address, command) + "\n");
                        stream.Write(answer, 0, answer.Length);
                    }
                }
                catch (ObjectDisposedException)
                {
                    return;
                }
                catch (SocketException e)
                {
                    if (e.SocketErrorCode == SocketError.Interrupted) return;
                    log.Write("listener: " + e.Message);
                    Thread.Sleep(1000);
                }
                catch (Exception e)
                {
                    log.Write("listener: " + e.Message);
                    Thread.Sleep(1000);
                }
            }
        }
    }
}
