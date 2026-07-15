using CommMonitor.Core.Ai;

namespace Lemon.SerialMonitor.AI.Transport;

public interface IAiServiceClient : IAsyncDisposable
{
    Task<AiStatusDto> GetStatusAsync(CancellationToken cancellationToken = default);

    Task<IReadOnlyList<AiPortDto>> ListPortsAsync(
        CancellationToken cancellationToken = default);

    Task<PreparedCaptureDto> PrepareStartAsync(
        PrepareCaptureRequest request,
        CancellationToken cancellationToken = default);

    Task<ActiveCaptureDto> CommitStartAsync(
        CommitCaptureRequest request,
        CancellationToken cancellationToken = default);

    Task<ActiveCaptureDto> RecoverLeaseAsync(
        RecoverLeaseRequest request,
        CancellationToken cancellationToken = default);

    Task<AiStatusDto> PauseAsync(
        LeaseProof request,
        CancellationToken cancellationToken = default);

    Task<AiStatusDto> ResumeAsync(
        LeaseProof request,
        CancellationToken cancellationToken = default);

    Task<AiStatusDto> StopAsync(
        LeaseProof request,
        CancellationToken cancellationToken = default);

    Task<AiSessionPage> ListSessionsAsync(
        ListSessionsRequest request,
        CancellationToken cancellationToken = default);

    Task<AiEventPage> ReadEventsAsync(
        ReadEventsRequest request,
        CancellationToken cancellationToken = default);

    Task<AiEventPage> WaitEventsAsync(
        WaitEventsRequest request,
        CancellationToken cancellationToken = default);

    Task<AiExportDto> ExportAsync(
        ExportSessionRequest request,
        CancellationToken cancellationToken = default);

    Task<AiSchemaDto> GetSchemaAsync(CancellationToken cancellationToken = default);
}

public sealed class LemonAiException : Exception
{
    public LemonAiException(AiError error)
        : base(error?.Message)
    {
        Error = error ?? throw new ArgumentNullException(nameof(error));
    }

    public AiError Error { get; }

    public string Code => Error.Code;

    public bool Retryable => Error.Retryable;

    public string CorrelationId => Error.CorrelationId;
}
