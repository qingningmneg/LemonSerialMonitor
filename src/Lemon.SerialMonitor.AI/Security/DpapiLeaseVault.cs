using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using CommMonitor.Core.Ai;

namespace Lemon.SerialMonitor.AI.Security;

internal interface ILeaseDataProtector
{
    byte[] Protect(ReadOnlySpan<byte> plaintext);

    byte[] Unprotect(ReadOnlySpan<byte> ciphertext);
}

internal sealed class CurrentUserLeaseDataProtector : ILeaseDataProtector
{
    private static readonly byte[] Entropy =
        Encoding.UTF8.GetBytes("lemon/ai/lease-vault/v1");

    public byte[] Protect(ReadOnlySpan<byte> plaintext) =>
        ProtectedData.Protect(
            plaintext.ToArray(),
            Entropy,
            DataProtectionScope.CurrentUser);

    public byte[] Unprotect(ReadOnlySpan<byte> ciphertext) =>
        ProtectedData.Unprotect(
            ciphertext.ToArray(),
            Entropy,
            DataProtectionScope.CurrentUser);
}

public sealed class DpapiLeaseVault : ILeaseVault, IDisposable
{
    private const int SchemaVersion = 1;
    private static readonly JsonSerializerOptions JsonOptions = AiJson.CreateOptions();

    private readonly string _path;
    private readonly ILeaseDataProtector _protector;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private bool _disposed;

    public DpapiLeaseVault()
        : this(DefaultPath, new CurrentUserLeaseDataProtector())
    {
    }

    internal DpapiLeaseVault(string path, ILeaseDataProtector protector)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        _path = Path.GetFullPath(path);
        _protector = protector ?? throw new ArgumentNullException(nameof(protector));
    }

    public static string DefaultPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "LemonSerialMonitor",
        "AI",
        "leases.json");

    public async Task<IReadOnlyList<StoredLease>> ReadAllAsync(
        CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            return (await ReadDocumentUnderGateAsync(cancellationToken).ConfigureAwait(false))
                .Leases
                .OrderBy(static lease => lease.LeaseId, StringComparer.Ordinal)
                .ToArray();
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task<StoredLease?> ReadAsync(
        string leaseId,
        CancellationToken cancellationToken = default)
    {
        ValidateIdentifier(leaseId, nameof(leaseId));
        IReadOnlyList<StoredLease> leases = await ReadAllAsync(cancellationToken)
            .ConfigureAwait(false);
        return leases.SingleOrDefault(lease => string.Equals(
            lease.LeaseId,
            leaseId,
            StringComparison.Ordinal));
    }

    public Task WritePendingAsync(
        PreparedCaptureDto prepared,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(prepared);
        ValidateIdentifier(prepared.LeaseId, nameof(prepared.LeaseId));
        ValidateIdentifier(prepared.ReservationId, nameof(prepared.ReservationId));
        ValidateIdentifier(prepared.ClientInstanceId, nameof(prepared.ClientInstanceId));
        ValidateSecret(prepared.LeaseSecret);
        _ = DateTimeOffset.Parse(prepared.ExpiresAtUtc, null, System.Globalization.DateTimeStyles.RoundtripKind);
        var lease = new StoredLease(
            prepared.LeaseId,
            prepared.LeaseSecret,
            prepared.ReservationId,
            prepared.ClientInstanceId,
            prepared.Generation,
            LeaseVaultState.Pending,
            prepared.ExpiresAtUtc,
            null,
            DateTimeOffset.UtcNow.ToString("O"));
        return MutateAsync(
            leases => Upsert(leases, lease),
            cancellationToken);
    }

    public Task ActivateAsync(
        ActiveCaptureDto active,
        string reservationId,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(active);
        ValidateIdentifier(active.LeaseId, nameof(active.LeaseId));
        ValidateIdentifier(reservationId, nameof(reservationId));
        ValidateIdentifier(active.ClientInstanceId, nameof(active.ClientInstanceId));
        ValidateSecret(active.LeaseSecret);
        var lease = new StoredLease(
            active.LeaseId,
            active.LeaseSecret,
            reservationId,
            active.ClientInstanceId,
            active.Generation,
            LeaseVaultState.Active,
            DateTimeOffset.MaxValue.ToString("O"),
            active.SessionId,
            DateTimeOffset.UtcNow.ToString("O"));
        return MutateAsync(
            leases => Upsert(leases, lease),
            cancellationToken);
    }

    public Task RemoveAsync(string leaseId, CancellationToken cancellationToken = default)
    {
        ValidateIdentifier(leaseId, nameof(leaseId));
        return MutateAsync(
            leases => leases
                .Where(lease => !string.Equals(
                    lease.LeaseId,
                    leaseId,
                    StringComparison.Ordinal))
                .ToList(),
            cancellationToken);
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        _gate.Dispose();
    }

    private async Task MutateAsync(
        Func<List<StoredLease>, List<StoredLease>> mutation,
        CancellationToken cancellationToken)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            VaultDocument current = await ReadDocumentUnderGateAsync(cancellationToken)
                .ConfigureAwait(false);
            List<StoredLease> leases = mutation(current.Leases.ToList());
            await WriteDocumentUnderGateAsync(
                new VaultDocument(SchemaVersion, leases),
                cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _gate.Release();
        }
    }

    private async Task<VaultDocument> ReadDocumentUnderGateAsync(
        CancellationToken cancellationToken)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (!File.Exists(_path))
        {
            return new VaultDocument(SchemaVersion, []);
        }

        try
        {
            byte[] envelopeBytes = await File.ReadAllBytesAsync(_path, cancellationToken)
                .ConfigureAwait(false);
            VaultEnvelope envelope = JsonSerializer.Deserialize<VaultEnvelope>(
                envelopeBytes,
                JsonOptions) ?? throw new InvalidDataException("The lease vault envelope is null.");
            if (envelope.SchemaVersion != SchemaVersion ||
                string.IsNullOrWhiteSpace(envelope.CiphertextBase64))
            {
                throw new InvalidDataException("The lease vault envelope is unsupported.");
            }

            byte[] ciphertext = Convert.FromBase64String(envelope.CiphertextBase64);
            byte[] plaintext = _protector.Unprotect(ciphertext);
            try
            {
                VaultDocument document = JsonSerializer.Deserialize<VaultDocument>(
                    plaintext,
                    JsonOptions) ?? throw new InvalidDataException("The lease vault is null.");
                if (document.SchemaVersion != SchemaVersion)
                {
                    throw new InvalidDataException("The lease vault schema is unsupported.");
                }

                ValidateDocument(document);
                return document;
            }
            finally
            {
                CryptographicOperations.ZeroMemory(plaintext);
                CryptographicOperations.ZeroMemory(ciphertext);
            }
        }
        catch (Exception exception) when (
            exception is JsonException or
            FormatException or
            CryptographicException or
            ArgumentException)
        {
            throw new InvalidDataException("The protected AI lease vault is corrupt.", exception);
        }
    }

    private async Task WriteDocumentUnderGateAsync(
        VaultDocument document,
        CancellationToken cancellationToken)
    {
        string directory = Path.GetDirectoryName(_path) ??
            throw new IOException("The lease vault path does not have a parent directory.");
        Directory.CreateDirectory(directory);
        ApplyPrivateDirectoryAcl(directory);

        byte[] plaintext = JsonSerializer.SerializeToUtf8Bytes(document, JsonOptions);
        byte[] ciphertext = _protector.Protect(plaintext);
        try
        {
            var envelope = new VaultEnvelope(
                SchemaVersion,
                "DPAPI-CurrentUser",
                Convert.ToBase64String(ciphertext));
            byte[] encoded = JsonSerializer.SerializeToUtf8Bytes(envelope, JsonOptions);
            string temporary = Path.Combine(
                directory,
                $".{Path.GetFileName(_path)}.{Guid.NewGuid():N}.tmp");
            try
            {
                await using (var stream = new FileStream(
                                 temporary,
                                 FileMode.CreateNew,
                                 FileAccess.Write,
                                 FileShare.None,
                                 4096,
                                 FileOptions.Asynchronous | FileOptions.WriteThrough))
                {
                    await stream.WriteAsync(encoded, cancellationToken).ConfigureAwait(false);
                    await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
                    stream.Flush(flushToDisk: true);
                }

                ApplyPrivateFileAcl(temporary);
                File.Move(temporary, _path, overwrite: true);
                ApplyPrivateFileAcl(_path);
            }
            finally
            {
                if (File.Exists(temporary))
                {
                    File.Delete(temporary);
                }
            }
        }
        finally
        {
            CryptographicOperations.ZeroMemory(plaintext);
            CryptographicOperations.ZeroMemory(ciphertext);
        }
    }

    private static List<StoredLease> Upsert(
        List<StoredLease> leases,
        StoredLease replacement)
    {
        leases.RemoveAll(lease => string.Equals(
            lease.LeaseId,
            replacement.LeaseId,
            StringComparison.Ordinal));
        leases.Add(replacement);
        return leases;
    }

    private static void ValidateDocument(VaultDocument document)
    {
        if (document.Leases.Count > 32)
        {
            throw new InvalidDataException("The lease vault contains too many records.");
        }

        var ids = new HashSet<string>(StringComparer.Ordinal);
        foreach (StoredLease lease in document.Leases)
        {
            ValidateIdentifier(lease.LeaseId, nameof(lease.LeaseId));
            ValidateIdentifier(lease.ReservationId, nameof(lease.ReservationId));
            ValidateIdentifier(lease.ClientInstanceId, nameof(lease.ClientInstanceId));
            ValidateSecret(lease.LeaseSecret);
            if (!ids.Add(lease.LeaseId))
            {
                throw new InvalidDataException("The lease vault contains duplicate lease IDs.");
            }
        }
    }

    private static void ValidateIdentifier(string value, string name)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(value, name);
        if (value.Length > 256 || value.Any(char.IsControl))
        {
            throw new ArgumentException($"{name} is invalid.", name);
        }
    }

    private static void ValidateSecret(string value)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(value);
        if (value.Length > 8192)
        {
            throw new ArgumentException("The lease secret is too long.");
        }
    }

    private static void ApplyPrivateDirectoryAcl(string path)
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        SecurityIdentifier user = WindowsIdentity.GetCurrent().User ??
            throw new InvalidOperationException("The current process does not have a user SID.");
        var security = new DirectorySecurity();
        security.SetAccessRuleProtection(true, false);
        security.SetOwner(user);
        security.AddAccessRule(new FileSystemAccessRule(
            user,
            FileSystemRights.FullControl,
            InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit,
            PropagationFlags.None,
            AccessControlType.Allow));
        security.AddAccessRule(new FileSystemAccessRule(
            new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null),
            FileSystemRights.FullControl,
            InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit,
            PropagationFlags.None,
            AccessControlType.Allow));
        new DirectoryInfo(path).SetAccessControl(security);
    }

    private static void ApplyPrivateFileAcl(string path)
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        SecurityIdentifier user = WindowsIdentity.GetCurrent().User ??
            throw new InvalidOperationException("The current process does not have a user SID.");
        var security = new FileSecurity();
        security.SetAccessRuleProtection(true, false);
        security.SetOwner(user);
        security.AddAccessRule(new FileSystemAccessRule(
            user,
            FileSystemRights.FullControl,
            AccessControlType.Allow));
        security.AddAccessRule(new FileSystemAccessRule(
            new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null),
            FileSystemRights.FullControl,
            AccessControlType.Allow));
        new FileInfo(path).SetAccessControl(security);
    }

    private sealed record VaultEnvelope(
        int SchemaVersion,
        string Protection,
        string CiphertextBase64);

    private sealed record VaultDocument(
        int SchemaVersion,
        IReadOnlyList<StoredLease> Leases);
}
