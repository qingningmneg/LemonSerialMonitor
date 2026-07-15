using CommMonitor.Core.Models;

namespace CommMonitor.Core.Sessions;

public interface ISessionStore
{
    Task InitializeAsync(CancellationToken cancellationToken = default);

    Task<int> GetSchemaVersionAsync(CancellationToken cancellationToken = default);

    Task<long> GetLastSequenceAsync(CancellationToken cancellationToken = default);

    Task<long> CountRunsAsync(CancellationToken cancellationToken = default);

    Task UpsertRunAsync(
        CaptureRunRecord run,
        CancellationToken cancellationToken = default);

    Task<IReadOnlyList<CaptureRunRecord>> ReadRunsAsync(
        CancellationToken cancellationToken = default);

    Task<IReadOnlyList<IntegrityMarker>> ReadMarkersAsync(
        string runId,
        CancellationToken cancellationToken = default);

    Task<IReadOnlyList<CaptureEvent>> AppendBatchAsync(
        PersistBatch batch,
        CancellationToken cancellationToken = default);

    Task<IReadOnlyList<CaptureEvent>> AppendAsync(
        IReadOnlyList<CaptureEvent> events,
        CancellationToken cancellationToken = default);

    Task<IReadOnlyList<CaptureEvent>> ReadAfterAsync(
        long sequence,
        int limit,
        CancellationToken cancellationToken = default);

    Task ClearAsync(CancellationToken cancellationToken = default);
}
