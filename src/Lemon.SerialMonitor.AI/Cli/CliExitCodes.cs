namespace Lemon.SerialMonitor.AI.Cli;

public static class CliExitCodes
{
    public const int Success = 0;
    public const int InvalidArguments = 2;
    public const int AccessOrProtocol = 3;
    public const int ServiceUnavailable = 4;
    public const int ConflictOrLease = 5;
    public const int IntegrityOrData = 6;
    public const int TimeoutOrCancelled = 7;
    public const int Unexpected = 10;
}
