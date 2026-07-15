using System.Security.Cryptography;

namespace CommMonitor.Service.Security;

/// <summary>
/// Process-local key material for the explicit fake-source development mode only.
/// Production driver mode always uses the LocalMachine-protected disk key ring.
/// </summary>
internal sealed class EphemeralProtectedKeyRing : IProtectedKeyRing, IDisposable
{
    private readonly byte[] _key = RandomNumberGenerator.GetBytes(32);
    private readonly string _keyId = "development-" + Guid.NewGuid().ToString("N");
    private bool _disposed;

    public ValueTask<ProtectedKeyMaterial> GetActiveKeyAsync(
        CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        ObjectDisposedException.ThrowIf(_disposed, this);
        return ValueTask.FromResult(new ProtectedKeyMaterial(_keyId, _key));
    }

    public ValueTask<ProtectedKeyMaterial> GetKeyAsync(
        string keyId,
        DateTimeOffset now,
        CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (!string.Equals(keyId, _keyId, StringComparison.Ordinal))
        {
            throw new ProtectedKeyRingException(
                ProtectedKeyFailure.Unavailable,
                "The development key is not available in this service process.");
        }

        return ValueTask.FromResult(new ProtectedKeyMaterial(_keyId, _key));
    }

    public ValueTask RetainKeyUntilAsync(
        string keyId,
        DateTimeOffset expiresAtUtc,
        CancellationToken cancellationToken = default)
    {
        _ = GetKeyAsync(keyId, DateTimeOffset.UtcNow, cancellationToken);
        return ValueTask.CompletedTask;
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        CryptographicOperations.ZeroMemory(_key);
        _disposed = true;
    }
}
