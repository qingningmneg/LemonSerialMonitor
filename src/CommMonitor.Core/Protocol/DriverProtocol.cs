namespace CommMonitor.Core.Protocol;

public static class DriverProtocol
{
    public const uint Magic = 0x4E4F4D43;
    public const ushort Version = 1;
    public const ushort HeaderSize = 68;
    public const int MaxPayload = 4096;
    public const int MaxBatchBytes = 64 * 1024;

    // FILE_DEVICE_UNKNOWN, METHOD_BUFFERED, FILE_READ_DATA | FILE_WRITE_DATA.
    public const uint GetVersionIoControlCode = 0x0022E000;
    public const uint SetConfigIoControlCode = 0x0022E004;
    public const uint GetBatchIoControlCode = 0x0022E008;
    public const uint GetStatsIoControlCode = 0x0022E00C;

    public const int VersionInfoSize = 12;
    public const int ConfigPrefixSize = 8;
    public const int StatsSize = 24;
    public const int MaxSelectedDevices = 64;
}
