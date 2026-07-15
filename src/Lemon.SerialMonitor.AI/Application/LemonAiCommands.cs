using CommMonitor.Core.Ai;
using Lemon.SerialMonitor.AI.Security;
using Lemon.SerialMonitor.AI.Transport;

namespace Lemon.SerialMonitor.AI.Application;

public sealed record CaptureStartResult(
    string LeaseId,
    string ClientInstanceId,
    string Generation,
    string SessionId,
    string CaptureState);

public sealed class LemonAiCommands
{
    private readonly IAiServiceClient _client;
    private readonly ILeaseVault _vault;
    private readonly string _clientInstanceId;

    public LemonAiCommands(IAiServiceClient client, ILeaseVault vault)
        : this(client, vault, Guid.NewGuid().ToString("N"))
    {
    }

    internal LemonAiCommands(
        IAiServiceClient client,
        ILeaseVault vault,
        string clientInstanceId)
    {
        _client = client ?? throw new ArgumentNullException(nameof(client));
        _vault = vault ?? throw new ArgumentNullException(nameof(vault));
        ArgumentException.ThrowIfNullOrWhiteSpace(clientInstanceId);
        _clientInstanceId = clientInstanceId;
    }

    public Task<AiStatusDto> GetStatusAsync(CancellationToken cancellationToken = default) =>
        _client.GetStatusAsync(cancellationToken);

    public Task<IReadOnlyList<AiPortDto>> ListPortsAsync(
        CancellationToken cancellationToken = default) =>
        _client.ListPortsAsync(cancellationToken);

    public async Task<CaptureStartResult> StartCaptureAsync(
        IReadOnlyList<string> deviceIds,
        string? label,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(deviceIds);
        PreparedCaptureDto prepared = await _client.PrepareStartAsync(
            new PrepareCaptureRequest(deviceIds, label, _clientInstanceId),
            cancellationToken).ConfigureAwait(false);
        await _vault.WritePendingAsync(prepared, cancellationToken).ConfigureAwait(false);
        ActiveCaptureDto active = await _client.CommitStartAsync(
            new CommitCaptureRequest(
                prepared.ReservationId,
                prepared.LeaseId,
                prepared.LeaseSecret,
                prepared.ClientInstanceId,
                prepared.Generation),
            cancellationToken).ConfigureAwait(false);
        await _vault.ActivateAsync(
            active,
            prepared.ReservationId,
            cancellationToken).ConfigureAwait(false);
        return Sanitize(active);
    }

    public Task<AiStatusDto> PauseCaptureAsync(
        string leaseId,
        CancellationToken cancellationToken = default) =>
        WithLeaseAsync(leaseId, _client.PauseAsync, removeAfter: false, cancellationToken);

    public Task<AiStatusDto> ResumeCaptureAsync(
        string leaseId,
        CancellationToken cancellationToken = default) =>
        WithLeaseAsync(leaseId, _client.ResumeAsync, removeAfter: false, cancellationToken);

    public Task<AiStatusDto> StopCaptureAsync(
        string leaseId,
        CancellationToken cancellationToken = default) =>
        WithLeaseAsync(leaseId, _client.StopAsync, removeAfter: true, cancellationToken);

    public Task<AiSessionPage> ListSessionsAsync(
        ListSessionsRequest request,
        CancellationToken cancellationToken = default) =>
        _client.ListSessionsAsync(request, cancellationToken);

    public Task<AiEventPage> ReadEventsAsync(
        ReadEventsRequest request,
        CancellationToken cancellationToken = default) =>
        _client.ReadEventsAsync(request, cancellationToken);

    public Task<AiEventPage> WaitEventsAsync(
        WaitEventsRequest request,
        CancellationToken cancellationToken = default) =>
        _client.WaitEventsAsync(request, cancellationToken);

    public Task<AiExportDto> ExportAsync(
        ExportSessionRequest request,
        CancellationToken cancellationToken = default) =>
        _client.ExportAsync(request, cancellationToken);

    public Task<AiSchemaDto> GetSchemaAsync(CancellationToken cancellationToken = default) =>
        _client.GetSchemaAsync(cancellationToken);

    public async Task<IReadOnlyList<CaptureStartResult>> ReconcileAsync(
        CancellationToken cancellationToken = default)
    {
        IReadOnlyList<StoredLease> leases = await _vault.ReadAllAsync(cancellationToken)
            .ConfigureAwait(false);
        var recovered = new List<CaptureStartResult>();
        foreach (StoredLease lease in leases)
        {
            if (lease.State == LeaseVaultState.Pending &&
                DateTimeOffset.TryParse(lease.ExpiresAtUtc, out DateTimeOffset expiresAt) &&
                expiresAt <= DateTimeOffset.UtcNow)
            {
                await _vault.RemoveAsync(lease.LeaseId, cancellationToken).ConfigureAwait(false);
                continue;
            }

            try
            {
                ActiveCaptureDto active = await _client.RecoverLeaseAsync(
                    new RecoverLeaseRequest(
                        lease.LeaseId,
                        lease.LeaseSecret,
                        lease.ClientInstanceId,
                        lease.Generation),
                    cancellationToken).ConfigureAwait(false);
                await _vault.ActivateAsync(
                    active,
                    lease.ReservationId,
                    cancellationToken).ConfigureAwait(false);
                recovered.Add(Sanitize(active));
            }
            catch (LemonAiException exception) when (
                exception.Code is AiErrorCodes.InvalidLease or
                AiErrorCodes.LeaseExpired or
                AiErrorCodes.StartReservationExpired)
            {
                await _vault.RemoveAsync(lease.LeaseId, cancellationToken).ConfigureAwait(false);
            }
        }

        return recovered;
    }

    private async Task<AiStatusDto> WithLeaseAsync(
        string leaseId,
        Func<LeaseProof, CancellationToken, Task<AiStatusDto>> operation,
        bool removeAfter,
        CancellationToken cancellationToken)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(leaseId);
        StoredLease lease = await _vault.ReadAsync(leaseId, cancellationToken)
            .ConfigureAwait(false) ??
            throw new LemonAiException(new AiError(
                AiErrorCodes.InvalidLease,
                "The requested lease is not present in the current user's protected vault.",
                false,
                Guid.NewGuid().ToString("N")));
        var proof = new LeaseProof(
            lease.LeaseId,
            lease.LeaseSecret,
            lease.ClientInstanceId,
            lease.Generation);
        AiStatusDto status = await operation(proof, cancellationToken).ConfigureAwait(false);
        if (removeAfter)
        {
            await _vault.RemoveAsync(leaseId, cancellationToken).ConfigureAwait(false);
        }

        return status;
    }

    private static CaptureStartResult Sanitize(ActiveCaptureDto active) =>
        new(
            active.LeaseId,
            active.ClientInstanceId,
            active.Generation,
            active.SessionId,
            active.CaptureState);
}
