import std.stdio;
import std.socket;
import std.experimental.logger;
import ntp.core;


// https://os.mbed.com/users/SolderSplashLabs/code/NTPClient/file/240ec02c4bc3/NTPClient.cpp/
void main()
{
    sharedLog = new FileLogger(stdout);

    auto ntpServers = [
        "0.fr.pool.ntp.org",
        "1.fr.pool.ntp.org",
        "2.fr.pool.ntp.org",
        "3.fr.pool.ntp.org"
    ];

    auto ntpClient = new NtpClient(ntpServers);
    ntpClient.initialize();
    ntpClient.run();
}
