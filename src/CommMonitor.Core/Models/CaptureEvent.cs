using System.Collections.Immutable;

namespace CommMonitor.Core.Models;

public sealed record CaptureEvent(
    long Sequence,
    long QpcTicks,
    ulong DeviceId,
    int ProcessId,
    CaptureKind Kind,
    uint IoctlCode,
    int NtStatus,
    int RequestedLength,
    int CompletedLength,
    CaptureFlags Flags,
    ImmutableArray<byte> Payload)
{
    public long WireSequence { get; init; } = Sequence;
    public string PortName { get; init; } = string.Empty;
    public string ProcessName { get; init; } = string.Empty;
    public DateTimeOffset Timestamp { get; init; }
}
