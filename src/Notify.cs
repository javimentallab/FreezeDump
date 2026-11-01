// Optional notifications. Without an ntfy URL in the config nothing leaves the PC.
using System;
using System.Net.Http;
using System.Text;

namespace HangDumpWatchdog
{
    public interface INotifier
    {
        void Send(string title, string message);
    }

    public sealed class NullNotifier : INotifier
    {
        public void Send(string title, string message) { }
    }

    public sealed class NtfyNotifier : INotifier
    {
        readonly string url;
        readonly string token;
        readonly Logger log;

        public NtfyNotifier(string url, string token, Logger log)
        {
            this.url = url;
            this.token = token;
            this.log = log;
        }

        public HttpRequestMessage BuildRequest(string title, string message)
        {
            var request = new HttpRequestMessage(HttpMethod.Post, url);
            if (token != "") request.Headers.TryAddWithoutValidation("Authorization", "Bearer " + token);
            request.Headers.TryAddWithoutValidation("Title", title);
            request.Headers.TryAddWithoutValidation("Priority", "max");
            request.Content = new StringContent(message, Encoding.UTF8, "text/plain");
            return request;
        }

        public void Send(string title, string message)
        {
            try
            {
                using (var handler = new HttpClientHandler { AllowAutoRedirect = false })
                using (var client = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(15) })
                using (HttpRequestMessage request = BuildRequest(title, message))
                using (HttpResponseMessage response = client.Send(request))
                {
                    log.Write("ntfy " + (int)response.StatusCode);
                }
            }
            catch (Exception e)
            {
                log.Write("ntfy failed: " + e.GetType().Name);
            }
        }
    }

    public static class Notifiers
    {
        public static INotifier FromConfig(WatchdogConfig cfg, Logger log)
        {
            if (!cfg.Ntfy.Enabled) return new NullNotifier();
            return new NtfyNotifier(cfg.Ntfy.Url, cfg.Ntfy.Token, log);
        }
    }
}
