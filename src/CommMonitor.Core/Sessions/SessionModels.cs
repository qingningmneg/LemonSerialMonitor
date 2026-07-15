using System.Globalization;
using System.Text.Json;
using CommMonitor.Core.Ai;
using CommMonitor.Core.Models;

namespace CommMonitor.Core.Sessions;

public sealed record DriverStatsSnapshot(
    bool StatsKnown, uint Queued, CaptureState State, ulong Dropped,
    ulong Sequence, DateTimeOffset SampledAtUtc, string? UnavailableReason);

public sealed record CaptureRunRecord(
    string RunId, string SessionId, long Generation, string ServiceInstanceId,
    string OwnerType, string OwnerSid, IReadOnlyList<string> SelectedDeviceIds,
    long StartAfterSequence, long? EndSequence,
    DateTimeOffset StartedUtc, DateTimeOffset? StoppedUtc,
    DriverStatsSnapshot StartStats, DriverStatsSnapshot? EndStats,
    long ServiceDropped, long TruncationCount, bool StatsKnown,
    bool CleanShutdown, string? EndReason);

public sealed record IntegrityMarker(
    long? MarkerId, string RunId, long Generation, string MarkerType,
    DateTimeOffset OccurredUtc, long AfterSequence, long CountDelta, string Code);

public sealed record PersistBatch(
    IReadOnlyList<CaptureEvent> Events,
    IReadOnlyList<IntegrityMarker> Markers);

public sealed record SessionEventQuery(
    long AfterSequence, int Limit, IReadOnlyList<ulong>? DeviceIds,
    IReadOnlyList<CaptureKind>? Kinds, DateTimeOffset? FromUtc,
    DateTimeOffset? ToUtc);

public sealed record SessionEventPage(
    IReadOnlyList<CaptureEvent> Events, long ScannedThroughSequence,
    bool HasMore, int SchemaVersion, bool StatsKnown,
    IReadOnlyList<string> IntegrityCodes,
    IReadOnlyList<CaptureRunRecord> Runs,
    IReadOnlyList<IntegrityMarker> Markers);

public interface IReadOnlySessionReader
{
    Task<int> GetSchemaVersionAsync(CancellationToken cancellationToken = default);

    Task<SessionEventPage> ReadAsync(
        SessionEventQuery query,
        CancellationToken cancellationToken = default);

    Task<IReadOnlyList<CaptureEvent>> ReadAfterAsync(
        long sequence,
        int limit,
        CancellationToken cancellationToken = default);

    Task<IReadOnlyList<CaptureRunRecord>> ReadRunsAsync(
        CancellationToken cancellationToken = default);

    Task<IReadOnlyList<IntegrityMarker>> ReadMarkersAsync(
        string runId,
        CancellationToken cancellationToken = default);
}

internal static class SessionRecordSerialization
{
    public static string SerializeSelectedDeviceIds(IReadOnlyList<string> deviceIds)
    {
        ArgumentNullException.ThrowIfNull(deviceIds);
        return JsonSerializer.Serialize(NormalizeDeviceIds(deviceIds), AiJson.CreateOptions());
    }

    public static IReadOnlyList<string> DeserializeSelectedDeviceIds(string json)
    {
        string[] deviceIds = JsonSerializer.Deserialize<string[]>(json, AiJson.CreateOptions())
            ?? throw new JsonException("Selected device IDs cannot be null.");
        return NormalizeDeviceIds(deviceIds);
    }

    public static string SerializeStats(DriverStatsSnapshot stats)
    {
        ArgumentNullException.ThrowIfNull(stats);
        return JsonSerializer.Serialize(stats, AiJson.CreateOptions());
    }

    public static DriverStatsSnapshot DeserializeStats(string json) =>
        JsonSerializer.Deserialize<DriverStatsSnapshot>(json, AiJson.CreateOptions())
        ?? throw new JsonException("Driver statistics cannot be null.");

    public static string FormatUtc(DateTimeOffset value) =>
        value.ToUniversalTime().ToString("O", CultureInfo.InvariantCulture);

    public static DateTimeOffset ParseUtc(string value) =>
        DateTimeOffset.Parse(
            value,
            CultureInfo.InvariantCulture,
            DateTimeStyles.RoundtripKind);

    private static string[] NormalizeDeviceIds(IReadOnlyList<string> deviceIds)
    {
        var normalized = new string[deviceIds.Count];
        for (int index = 0; index < deviceIds.Count; index++)
        {
            string? deviceId = deviceIds[index];
            if (string.IsNullOrWhiteSpace(deviceId)
                || !ulong.TryParse(
                    deviceId,
                    NumberStyles.AllowHexSpecifier,
                    CultureInfo.InvariantCulture,
                    out ulong value))
            {
                throw new ArgumentException(
                    $"Device ID at index {index} must be an unsigned hexadecimal value.",
                    nameof(deviceIds));
            }

            normalized[index] = value.ToString("X16", CultureInfo.InvariantCulture);
        }

        return normalized;
    }
}
