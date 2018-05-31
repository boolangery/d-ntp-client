module ntp.core;

import std.stdio;
import core.stdc.stdint;
import std.bitmanip: bitfields;
import std.socket;
import core.time;
import std.datetime.systime;

extern(C) {
    struct Timeval_C {
        long	tv_sec;		/* seconds */
        long	tv_usec;	/* and microseconds */
    }

    struct Timex_C {
        int  modes;      /* Mode selector */
        long offset;     /* Time offset; nanoseconds, if STA_NANO
                            status flag is set, otherwise
                            microseconds */
        long freq;       /* Frequency offset; see NOTES for units */
        long maxerror;   /* Maximum error (microseconds) */
        long esterror;   /* Estimated error (microseconds) */
        int  status;     /* Clock command/status */
        long constant;   /* PLL (phase-locked loop) time constant */
        long precision;  /* Clock precision
                            (microseconds, read-only) */
        long tolerance;  /* Clock frequency tolerance (read-only);
                            see NOTES for units */
        Timeval_C time;
                         /* Current time (read-only, except for
                            ADJ_SETOFFSET); upon return, time.tv_usec
                            contains nanoseconds, if STA_NANO status
                            flag is set, otherwise microseconds */
        long tick;       /* Microseconds between clock ticks */
        long ppsfreq;    /* PPS (pulse per second) frequency
                            (read-only); see NOTES for units */
        long jitter;     /* PPS jitter (read-only); nanoseconds, if
                            STA_NANO status flag is set, otherwise
                            microseconds */
        int  shift;      /* PPS interval duration
                            (seconds, read-only) */
        long stabil;     /* PPS stability (read-only);
                            see NOTES for units */
        long jitcnt;     /* PPS count of jitter limit exceeded
                            events (read-only) */
        long calcnt;     /* PPS count of calibration intervals
                            (read-only) */
        long errcnt;     /* PPS count of calibration errors
                            (read-only) */
        long stbcnt;     /* PPS count of stability limit exceeded
                            events (read-only) */
        int tai;         /* TAI offset, as set by previous ADJ_TAI
                            operation (seconds, read-only,
                            since Linux 2.6.26) */
        /* Further padding bytes to allow for future expansion */
    }

    int adjtimex(Timex_C *buf);
}



struct NtpPacket
{
    align(1):
        mixin(bitfields!(
            uint, "mode",  3,
            int,  "vn",    3,
            uint, "li",    2));
        // Eight bits. li, vn, and mode.
        // li.   Two bits.   Leap indicator.
        // vn.   Three bits. Version number of the protocol.
        // mode. Three bits. Client will pick mode 3 for client.

        uint8_t stratum;         // Eight bits. Stratum level of the local clock.
        uint8_t poll;            // Eight bits. Maximum interval between successive messages.
        uint8_t precision;       // Eight bits. Precision of the local clock.

        uint32_t rootDelay;      // 32 bits. Total round trip delay time.
        uint32_t rootDispersion; // 32 bits. Max error aloud from primary clock source.
        uint32_t refId;          // 32 bits. Reference clock identifier.

        uint32_t refTm_s;        // 32 bits. Reference time-stamp seconds.
        uint32_t refTm_f;        // 32 bits. Reference time-stamp fraction of a second.

        uint32_t origTm_s;       // 32 bits. Originate time-stamp seconds.
        uint32_t origTm_f;       // 32 bits. Originate time-stamp fraction of a second.

        uint32_t rxTm_s;         // 32 bits. Received time-stamp seconds.
        uint32_t rxTm_f;         // 32 bits. Received time-stamp fraction of a second.

        uint32_t txTm_s;         // 32 bits and the most important field the client cares about. Transmit time-stamp seconds.
        uint32_t txTm_f;         // 32 bits. Transmit time-stamp fraction of a second.
}  // Total: 384 bits or 48 bytes.

class NtpException: Exception
{
    this(string msg) @safe { super(msg); }
}

class NtpSocketException: NtpException
{
    this(string msg) @safe { super(msg); }
}

/// Extension method to throw socket errors
private void throwError(Socket socket) @safe
{
    auto status = socket.getErrorText();
    if (status != "Success")
        throw new NtpSocketException(status);
}


class NtpClient
{
    import std.experimental.logger;
    import core.sys.posix.arpa.inet;
    import std.math: pow;
    import core.time;
    import core.thread: Thread;

    private Address _bindAddress;
    private Socket _socket;
    private string[] _servers;
    private int _serverInUse;

    this(string[] servers, ushort listenPort=123, bool ipv6=false)
    {
        _servers = servers;
        if (ipv6)
            _bindAddress = new Internet6Address(Internet6Address.ADDR_ANY, listenPort);
        else
            _bindAddress = new InternetAddress(InternetAddress.ADDR_ANY, listenPort);

        _socket = new Socket(_bindAddress.addressFamily, SocketType.DGRAM, ProtocolType.UDP);
    }

    void initialize()
    {
       _socket.bind(_bindAddress);
       _socket.throwError();
    }

    void run()
    {
        while (true) {
            try
            {
                auto pollInterval = pollServer();
                infof("poll interval is set to: %s", pollInterval);
                info("going to sleep...");
                Thread.sleep(pollInterval);
            }
            catch (Exception e)
            {
                warningf("error while polling server %s: %s", _servers[_serverInUse], e.msg);
                selectNextServer();
            }
        }
    }

    private Duration pollServer()
    {
        auto host = _servers[_serverInUse];
        auto server = new InternetAddress(host, 123);

        // connect to server
        infof("polling server %s", server);
        _socket.connect(server);
        _socket.throwError();

        // send ntp request
        auto ntpRequest = createNtpRequest();
        void[] sendBuffer = (&ntpRequest)[0..1];
        trace(sendBuffer);
        _socket.send(sendBuffer);
        _socket.throwError();

        // receive
        ubyte[48] buffer;
        Address from;
        auto length = _socket.receiveFrom(buffer, from);

        tracef("received %s byte datagram from %s", length, from);
        trace(buffer);

        // parse buffer to ntp packet
        auto ntpResponse = *cast(NtpPacket*) buffer.ptr;

        // These two fields contain the time-stamp seconds as the packet left the NTP server.
        // The number of seconds correspond to the seconds passed since 1900.
        // ntohl() converts the bit/byte order from the network's to host's "endianness".
        ntpResponse.txTm_s = ntohl( ntpResponse.txTm_s ); // Time-stamp seconds.
        ntpResponse.txTm_f = ntohl( ntpResponse.txTm_f ); // Time-stamp fraction of a second.

        this.adjustTime(ntpResponse);

        // compute poll interval (log2 value)
        int pollInterval = cast(int) pow(2, ntpResponse.poll); // in seconds
        return pollInterval.seconds;
    }

    private void adjustTime(const NtpPacket packet) @safe
    {
        // Extract the 32 bits that represent the time-stamp seconds (since NTP epoch) from when the packet left the server.
        // Subtract 70 years worth of seconds from the seconds since 1900.
        // This leaves the seconds since the UNIX epoch of 1970.
        // (1900)------------------(1970)**************************************(Time Packet Left the Server)
        time_t txTm = cast(time_t) (packet.txTm_s - 2208988800UL);

        auto time = SysTime(unixTimeToStdTime(txTm));
        info(time);
    }

    private void selectNextServer() @safe
    {
        _serverInUse++;
        if (_serverInUse > _servers.length -1)
            _serverInUse = 0;
        infof("selecting next server: %s", _servers[_serverInUse]);
    }

    private NtpPacket createNtpRequest() @safe
    {
        NtpPacket packet;
        packet.li = 0;
        packet.vn = 3;
        packet.mode = 3;
        return packet;
    }
}
