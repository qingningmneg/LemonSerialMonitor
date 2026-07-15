using CommMonitor.Core.Ai;

namespace Lemon.SerialMonitor.AI.Security;

public enum LeaseVaultState
{
    Pending,
    Active,
}

public sealed record StoredLease(
    string LeaseId,
    string LeaseSecret,
    string ReservationId,
    string ClientInstanceId,
    string Generation,
    LeaseVaultState State,
    string ExpiresAtUtc,
    string? SessionId,
    string UpdatedUtc);

public interface ILeaseVault
{
    Task<IReadOnlyList<StoredLease>> ReadAllAsync(
        CancellationToken cancellationToken = default);

    Task<StoredLease?> ReadAsync(
        string leaseId,
        CancellationToken cancellationToken = default);

    Task WritePendingAsync(
        PreparedCaptureDto prepared,
        CancellationToken cancellationToken = default);

    Task ActivateAsync(
        ActiveCaptureDto active,
        string reservationId,
        CancellationToken cancellationToken = default);

    Task RemoveAsync(string leaseId, CancellationToken cancellationToken = default);
}
