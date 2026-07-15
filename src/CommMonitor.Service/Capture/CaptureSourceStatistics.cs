using CommMonitor.Core.Models;

namespace CommMonitor.Service.Capture;

public interface ICaptureSourceStatisticsProvider
{
    ValueTask<CaptureSourceStatistics> GetStatisticsAsync(
        CancellationToken cancellationToken);
}

public sealed record CaptureSourceStatistics(
    bool StatsKnown,
    uint Queued,
    CaptureState State,
    ulong Dropped,
    ulong Sequence,
    DateTimeOffset SampledAtUtc,
    string? UnavailableReason)
{
    public static CaptureSourceStatistics Unknown(
        string unavailableReason,
        DateTimeOffset sampledAtUtc)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(unavailableReason);
        return new CaptureSourceStatistics(
            false,
            0,
            CaptureState.Stopped,
            0,
            0,
            sampledAtUtc,
            unavailableReason);
    }
}

public sealed record CaptureSnapshot(
    CaptureState State,
    long Generation,
    string? RunId,
    string? SessionId,
    string? OwnerType,
    string? OwnerSid,
    long LastCommittedSequence,
    CaptureSourceStatistics Statistics,
    ulong DriverDropped,
    long ServiceDropped,
    long TruncationCount,
    bool StatsKnown,
    bool CleanShutdown,
    string? EndReason)
{
    public long CommittedThroughSequence => LastCommittedSequence;

    public bool TruncationSeen => TruncationCount > 0;

    public bool Complete =>
        StatsKnown &&
        DriverDropped == 0 &&
        ServiceDropped == 0 &&
        TruncationCount == 0 &&
        CleanShutdown;
}
