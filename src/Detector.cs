// Hang detection. Pure logic: it decides, it never acts, so it can be tested without a hang.
namespace FreezeDump
{
    public struct DetectorDecision
    {
        public bool HangStarted;
        public bool Recovered;
        public bool RequestDump;
        public int DumpNumber;
    }

    public sealed class HangDetector
    {
        readonly int hangSeconds;
        readonly int maxDumpsPerHang;
        readonly int minSecondsBetweenDumps;

        public bool Hung { get; private set; }
        public int DumpsThisHang { get; private set; }

        public HangDetector(int hangSeconds, int maxDumpsPerHang, int minSecondsBetweenDumps)
        {
            this.hangSeconds = hangSeconds;
            this.maxDumpsPerHang = maxDumpsPerHang;
            this.minSecondsBetweenDumps = minSecondsBetweenDumps;
        }

        public DetectorDecision Tick(double probePendingSeconds, bool probeRunning, bool dumpRunning, double secondsSinceLastDump)
        {
            var d = new DetectorDecision();
            if (probePendingSeconds > hangSeconds)
            {
                if (!Hung)
                {
                    Hung = true;
                    DumpsThisHang = 0;
                    d.HangStarted = true;
                }
                if (DumpsThisHang < maxDumpsPerHang && !dumpRunning && secondsSinceLastDump >= minSecondsBetweenDumps)
                {
                    DumpsThisHang++;
                    d.RequestDump = true;
                    d.DumpNumber = DumpsThisHang;
                }
            }
            else if (Hung && !probeRunning)
            {
                Hung = false;
                d.Recovered = true;
            }
            return d;
        }
    }
}
