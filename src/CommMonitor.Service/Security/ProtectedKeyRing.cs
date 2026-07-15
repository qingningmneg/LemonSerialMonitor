using System.Collections.Concurrent;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.Win32.SafeHandles;

namespace CommMonitor.Service.Security;

internal interface IProtectedKeyRing
{
    ValueTask<ProtectedKeyMaterial> GetActiveKeyAsync(
        CancellationToken cancellationToken = default);

    ValueTask<ProtectedKeyMaterial> GetKeyAsync(
        string keyId,
        DateTimeOffset now,
        CancellationToken cancellationToken = default);

    ValueTask RetainKeyUntilAsync(
        string keyId,
        DateTimeOffset expiresAtUtc,
        CancellationToken cancellationToken = default);
}

internal sealed record ProtectedKeyMaterial(
    string KeyId,
    ReadOnlyMemory<byte> KeyBytes);

internal enum ProtectedKeyFailure
{
    Retired,
    Unavailable,
}

internal sealed class ProtectedKeyRingException : Exception
{
    public ProtectedKeyRingException(
        ProtectedKeyFailure failure,
        string message,
        Exception? innerException = null)
        : base(message, innerException)
    {
        Failure = failure;
    }

    public ProtectedKeyFailure Failure { get; }
}

internal interface IKeyRingFileSecurityPolicy
{
    void ProtectMetadataDirectory(string path);

    void ProtectKeyRingFile(string path);
}

[SupportedOSPlatform("windows")]
internal sealed class WindowsKeyRingFileSecurityPolicy : IKeyRingFileSecurityPolicy
{
    private static readonly SecurityIdentifier SystemSid =
        new(WellKnownSidType.LocalSystemSid, domainSid: null);
    private static readonly SecurityIdentifier AdministratorsSid =
        new(WellKnownSidType.BuiltinAdministratorsSid, domainSid: null);
    private static readonly HashSet<SecurityIdentifier> TrustedOwners =
        [SystemSid, AdministratorsSid];

    public void ProtectMetadataDirectory(string path)
    {
        ValidateTrustedOwner(path, isDirectory: true);
        new DirectoryInfo(path).SetAccessControl(CreateProtectedDirectorySecurity());
        VerifySecurity(
            new DirectoryInfo(path).GetAccessControl(
                AccessControlSections.Access | AccessControlSections.Owner));
    }

    public void ProtectKeyRingFile(string path)
    {
        ValidateTrustedOwner(path, isDirectory: false);
        new FileInfo(path).SetAccessControl(CreateProtectedFileSecurity());
        VerifySecurity(
            new FileInfo(path).GetAccessControl(
                AccessControlSections.Access | AccessControlSections.Owner));
    }

    internal static FileSecurity CreateProtectedFileSecurity()
    {
        var security = new FileSecurity();
        ConfigureOwnerAndRules(security, InheritanceFlags.None);
        return security;
    }

    internal static DirectorySecurity CreateProtectedDirectorySecurity()
    {
        var security = new DirectorySecurity();
        ConfigureOwnerAndRules(
            security,
            InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit);
        return security;
    }

    private static void ConfigureOwnerAndRules(
        FileSystemSecurity security,
        InheritanceFlags inheritanceFlags)
    {
        security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        security.SetOwner(SystemSid);
        foreach (SecurityIdentifier identity in TrustedOwners)
        {
            security.AddAccessRule(new FileSystemAccessRule(
                identity,
                FileSystemRights.FullControl,
                inheritanceFlags,
                PropagationFlags.None,
                AccessControlType.Allow));
        }
    }

    private static void ValidateTrustedOwner(string path, bool isDirectory)
    {
        FileSystemSecurity security = isDirectory
            ? new DirectoryInfo(path).GetAccessControl(AccessControlSections.Owner)
            : new FileInfo(path).GetAccessControl(AccessControlSections.Owner);
        SecurityIdentifier? owner = security.GetOwner(typeof(SecurityIdentifier)) as SecurityIdentifier;
        if (owner is null || !TrustedOwners.Contains(owner))
        {
            throw new IOException(
                "The protected key-ring object is not owned by SYSTEM or Administrators.");
        }
    }

    private static void VerifySecurity(FileSystemSecurity security)
    {
        SecurityIdentifier? owner = security.GetOwner(typeof(SecurityIdentifier)) as SecurityIdentifier;
        if (!security.AreAccessRulesProtected ||
            owner is null ||
            !TrustedOwners.Contains(owner))
        {
            throw new IOException("The protected key-ring security descriptor is invalid.");
        }

        FileSystemAccessRule[] rules = security
            .GetAccessRules(
                includeExplicit: true,
                includeInherited: true,
                typeof(SecurityIdentifier))
            .Cast<FileSystemAccessRule>()
            .ToArray();
        foreach (FileSystemAccessRule rule in rules)
        {
            if (rule.AccessControlType != AccessControlType.Allow ||
                rule.IdentityReference is not SecurityIdentifier identity ||
                !TrustedOwners.Contains(identity) ||
                (rule.FileSystemRights & FileSystemRights.FullControl) !=
                FileSystemRights.FullControl)
            {
                throw new IOException(
                    "The protected key-ring ACL grants access outside SYSTEM and Administrators.");
            }
        }

        foreach (SecurityIdentifier identity in TrustedOwners)
        {
            if (!rules.Any(rule =>
                    rule.AccessControlType == AccessControlType.Allow &&
                    identity.Equals(rule.IdentityReference) &&
                    (rule.FileSystemRights & FileSystemRights.FullControl) ==
                    FileSystemRights.FullControl))
            {
                throw new IOException(
                    "The protected key-ring ACL is missing a required trusted principal.");
            }
        }
    }
}

[SupportedOSPlatform("windows")]
internal sealed class ProtectedKeyRing : IProtectedKeyRing
{
    private const int CurrentVersion = 1;
    private const int KeyLengthBytes = 32;
    private const uint FileReadAttributes = 0x00000080;
    private const uint FileShareRead = 0x00000001;
    private const uint FileShareWrite = 0x00000002;
    private const uint OpenExisting = 3;
    private const uint FileFlagOpenReparsePoint = 0x00200000;
    private const uint FileAttributeReparsePoint = 0x00000400;
    private const uint FileAttributeDirectory = 0x00000010;
    private static readonly TimeSpan MaximumReceiptLifetime = TimeSpan.FromDays(90);
    private static readonly byte[] ProtectionEntropy =
        Encoding.UTF8.GetBytes("lemon/key-ring/v1");
    private static readonly ConcurrentDictionary<string, SemaphoreSlim> FileGates =
        new(StringComparer.OrdinalIgnoreCase);
    private static readonly JsonSerializerOptions JsonOptions = CreateJsonOptions();

    private readonly string _metadataPath;
    private readonly string _path;
    private readonly SemaphoreSlim _fileGate;
    private readonly IKeyRingFileSecurityPolicy _fileSecurityPolicy;

    public ProtectedKeyRing(InstallSecurityOptions options)
        : this(options, new WindowsKeyRingFileSecurityPolicy())
    {
    }

    internal ProtectedKeyRing(
        InstallSecurityOptions options,
        IKeyRingFileSecurityPolicy fileSecurityPolicy)
    {
        ArgumentNullException.ThrowIfNull(options);
        ArgumentNullException.ThrowIfNull(fileSecurityPolicy);
        options.Validate();
        _path = options.KeyRingPath;
        _metadataPath = Path.GetDirectoryName(_path)!;
        _fileGate = FileGates.GetOrAdd(_path, static _ => new SemaphoreSlim(1, 1));
        _fileSecurityPolicy = fileSecurityPolicy;
    }

    public async ValueTask<ProtectedKeyMaterial> GetActiveKeyAsync(
        CancellationToken cancellationToken = default)
    {
        await _fileGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            PersistedKeyRing state = await LoadOrCreateAsync(cancellationToken)
                .ConfigureAwait(false);
            if (PruneExpiredRetiredKeys(state, DateTimeOffset.UtcNow))
            {
                await SaveAsync(state, cancellationToken).ConfigureAwait(false);
            }

            PersistedKey active = state.Keys.SingleOrDefault(key =>
                    string.Equals(key.KeyId, state.ActiveKeyId, StringComparison.Ordinal) &&
                    key.Status == PersistedKeyStatus.Active) ??
                throw new InvalidDataException("The protected key ring has no active key.");
            return Unprotect(active);
        }
        finally
        {
            _fileGate.Release();
        }
    }

    public async ValueTask<ProtectedKeyMaterial> GetKeyAsync(
        string keyId,
        DateTimeOffset now,
        CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(keyId);
        await _fileGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            PersistedKeyRing state = await LoadOrCreateAsync(cancellationToken)
                .ConfigureAwait(false);
            if (PruneExpiredRetiredKeys(state, now))
            {
                await SaveAsync(state, cancellationToken).ConfigureAwait(false);
            }

            PersistedKey? key = state.Keys.SingleOrDefault(candidate =>
                string.Equals(candidate.KeyId, keyId, StringComparison.Ordinal));
            if (key is null)
            {
                throw new ProtectedKeyRingException(
                    ProtectedKeyFailure.Unavailable,
                    "The requested signing key is unavailable.");
            }

            if (key.Status == PersistedKeyStatus.EmergencyRetired)
            {
                throw new ProtectedKeyRingException(
                    ProtectedKeyFailure.Retired,
                    "The requested signing key was retired for an emergency.");
            }

            return Unprotect(key);
        }
        finally
        {
            _fileGate.Release();
        }
    }

    public async ValueTask RetainKeyUntilAsync(
        string keyId,
        DateTimeOffset expiresAtUtc,
        CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(keyId);
        await _fileGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            PersistedKeyRing state = await LoadOrCreateAsync(cancellationToken)
                .ConfigureAwait(false);
            if (PruneExpiredRetiredKeys(state, DateTimeOffset.UtcNow))
            {
                await SaveAsync(state, cancellationToken).ConfigureAwait(false);
            }

            PersistedKey key = state.Keys.SingleOrDefault(candidate =>
                    string.Equals(candidate.KeyId, keyId, StringComparison.Ordinal)) ??
                throw new ProtectedKeyRingException(
                    ProtectedKeyFailure.Unavailable,
                    "The signing key disappeared before its retention was recorded.");
            if (key.Status == PersistedKeyStatus.EmergencyRetired)
            {
                throw new ProtectedKeyRingException(
                    ProtectedKeyFailure.Retired,
                    "The signing key was retired before its retention was recorded.");
            }

            if (key.RetainUntilUtc is null || expiresAtUtc > key.RetainUntilUtc.Value)
            {
                key.RetainUntilUtc = expiresAtUtc;
                await SaveAsync(state, cancellationToken).ConfigureAwait(false);
            }
        }
        finally
        {
            _fileGate.Release();
        }
    }

    public async ValueTask<ProtectedKeyMaterial> RotateAsync(
        DateTimeOffset now,
        CancellationToken cancellationToken = default)
    {
        await _fileGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            PersistedKeyRing state = await LoadOrCreateAsync(cancellationToken)
                .ConfigureAwait(false);
            _ = PruneExpiredRetiredKeys(state, now);
            PersistedKey active = state.Keys.Single(key =>
                string.Equals(key.KeyId, state.ActiveKeyId, StringComparison.Ordinal));
            active.Status = PersistedKeyStatus.Retired;
            DateTimeOffset conservativeRetention = now + MaximumReceiptLifetime;
            if (active.RetainUntilUtc is null ||
                conservativeRetention > active.RetainUntilUtc.Value)
            {
                active.RetainUntilUtc = conservativeRetention;
            }

            (PersistedKey persisted, ProtectedKeyMaterial material) = CreateKey(now);
            state.Keys.Add(persisted);
            state.ActiveKeyId = persisted.KeyId;
            await SaveAsync(state, cancellationToken).ConfigureAwait(false);
            return material;
        }
        finally
        {
            _fileGate.Release();
        }
    }

    public async ValueTask EmergencyRetireAsync(
        string keyId,
        DateTimeOffset now,
        CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(keyId);
        await _fileGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            PersistedKeyRing state = await LoadOrCreateAsync(cancellationToken)
                .ConfigureAwait(false);
            _ = PruneExpiredRetiredKeys(state, now);
            PersistedKey key = state.Keys.SingleOrDefault(candidate =>
                    string.Equals(candidate.KeyId, keyId, StringComparison.Ordinal)) ??
                throw new ProtectedKeyRingException(
                    ProtectedKeyFailure.Unavailable,
                    "The requested signing key is unavailable.");
            DateTimeOffset tombstoneExpiry = now + MaximumReceiptLifetime;
            if (key.RetainUntilUtc is null || tombstoneExpiry > key.RetainUntilUtc.Value)
            {
                key.RetainUntilUtc = tombstoneExpiry;
            }

            key.Status = PersistedKeyStatus.EmergencyRetired;
            key.ProtectedKey = null;
            if (string.Equals(state.ActiveKeyId, keyId, StringComparison.Ordinal))
            {
                (PersistedKey replacement, _) = CreateKey(now);
                state.Keys.Add(replacement);
                state.ActiveKeyId = replacement.KeyId;
            }

            await SaveAsync(state, cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _fileGate.Release();
        }
    }

    private async ValueTask<PersistedKeyRing> LoadOrCreateAsync(
        CancellationToken cancellationToken)
    {
        EnsureMetadataDirectory();
        if (!File.Exists(_path))
        {
            (PersistedKey active, _) = CreateKey(DateTimeOffset.UtcNow);
            var created = new PersistedKeyRing
            {
                Version = CurrentVersion,
                ActiveKeyId = active.KeyId,
                Keys = [active],
            };
            await SaveAsync(created, cancellationToken).ConfigureAwait(false);
            return created;
        }

        ValidateKeyRingFile();
        await using var stream = new FileStream(
            _path,
            FileMode.Open,
            FileAccess.Read,
            FileShare.Read,
            bufferSize: 4096,
            FileOptions.Asynchronous | FileOptions.SequentialScan);
        PersistedKeyRing state = await JsonSerializer.DeserializeAsync<PersistedKeyRing>(
                stream,
                JsonOptions,
                cancellationToken)
            .ConfigureAwait(false) ??
            throw new InvalidDataException("The protected key ring is empty.");
        ValidateState(state);
        return state;
    }

    private async ValueTask SaveAsync(
        PersistedKeyRing state,
        CancellationToken cancellationToken)
    {
        ValidateState(state);
        EnsureMetadataDirectory();
        string temporaryPath = Path.Combine(
            _metadataPath,
            $".{InstallSecurityOptions.KeyRingFileName}.{Guid.NewGuid():N}.tmp");
        try
        {
            await using (var stream = new FileStream(
                             temporaryPath,
                             FileMode.CreateNew,
                             FileAccess.Write,
                             FileShare.None,
                             bufferSize: 4096,
                             FileOptions.Asynchronous | FileOptions.WriteThrough))
            {
                await JsonSerializer.SerializeAsync(
                        stream,
                        state,
                        JsonOptions,
                        cancellationToken)
                    .ConfigureAwait(false);
                await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
                stream.Flush(flushToDisk: true);
            }

            ProtectKeyRingFile(temporaryPath);
            File.Move(temporaryPath, _path, overwrite: true);
            ProtectKeyRingFile(_path);
        }
        finally
        {
            if (File.Exists(temporaryPath))
            {
                File.Delete(temporaryPath);
            }
        }
    }

    private void EnsureMetadataDirectory()
    {
        EnsureNoReparsePointsInExistingChain(_metadataPath);
        Directory.CreateDirectory(_metadataPath);
        EnsureNoReparsePointsInExistingChain(_metadataPath);
        ProtectMetadataDirectory(_metadataPath);
    }

    private void ValidateKeyRingFile()
    {
        using SafeFileHandle handle = CreateFileW(
            _path,
            FileReadAttributes,
            FileShareRead | FileShareWrite,
            IntPtr.Zero,
            OpenExisting,
            FileFlagOpenReparsePoint,
            IntPtr.Zero);
        if (handle.IsInvalid)
        {
            throw new IOException(
                "The protected key ring cannot be opened safely.",
                new Win32Exception(Marshal.GetLastWin32Error()));
        }

        if (!GetFileInformationByHandle(handle, out ByHandleFileInformation information))
        {
            throw new IOException(
                "The protected key ring cannot be inspected safely.",
                new Win32Exception(Marshal.GetLastWin32Error()));
        }

        if ((information.FileAttributes & FileAttributeReparsePoint) != 0 ||
            (information.FileAttributes & FileAttributeDirectory) != 0 ||
            information.NumberOfLinks != 1)
        {
            throw new IOException(
                "The protected key ring path is not a unique regular file.");
        }

        ProtectKeyRingFile(_path);
    }

    private void ProtectMetadataDirectory(string path)
    {
        try
        {
            _fileSecurityPolicy.ProtectMetadataDirectory(path);
        }
        catch (InvalidOperationException exception)
        {
            throw new IOException(
                "The protected key-ring directory security could not be persisted.",
                exception);
        }
    }

    private void ProtectKeyRingFile(string path)
    {
        try
        {
            _fileSecurityPolicy.ProtectKeyRingFile(path);
        }
        catch (InvalidOperationException exception)
        {
            throw new IOException(
                "The protected key-ring file security could not be persisted.",
                exception);
        }
    }

    private static void EnsureNoReparsePointsInExistingChain(string path)
    {
        string canonicalPath = Path.GetFullPath(path);
        string root = Path.GetPathRoot(canonicalPath) ??
            throw new IOException("The key-ring metadata path has no filesystem root.");
        string current = root;
        foreach (string component in Path.GetRelativePath(root, canonicalPath).Split(
                     [Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar],
                     StringSplitOptions.RemoveEmptyEntries))
        {
            current = Path.Combine(current, component);
            if (!Directory.Exists(current) && !File.Exists(current))
            {
                break;
            }

            FileAttributes attributes = File.GetAttributes(current);
            if ((attributes & FileAttributes.ReparsePoint) != 0)
            {
                throw new IOException("The key-ring metadata path contains a reparse point.");
            }

            if ((attributes & FileAttributes.Directory) == 0)
            {
                throw new IOException("The key-ring metadata path contains a non-directory component.");
            }
        }
    }

    private static ProtectedKeyMaterial Unprotect(PersistedKey key)
    {
        if (string.IsNullOrWhiteSpace(key.ProtectedKey))
        {
            throw new ProtectedKeyRingException(
                ProtectedKeyFailure.Unavailable,
                "The requested signing key has no protected material.");
        }

        try
        {
            byte[] protectedBytes = Convert.FromBase64String(key.ProtectedKey);
            byte[] rawKey = ProtectedData.Unprotect(
                protectedBytes,
                ProtectionEntropy,
                DataProtectionScope.LocalMachine);
            if (rawKey.Length != KeyLengthBytes)
            {
                CryptographicOperations.ZeroMemory(rawKey);
                throw new CryptographicException("The protected signing key has an invalid length.");
            }

            return new ProtectedKeyMaterial(key.KeyId, rawKey);
        }
        catch (Exception exception) when (
            exception is FormatException or CryptographicException)
        {
            throw new ProtectedKeyRingException(
                ProtectedKeyFailure.Unavailable,
                "The protected signing key cannot be recovered.",
                exception);
        }
    }

    private static (PersistedKey Persisted, ProtectedKeyMaterial Material) CreateKey(
        DateTimeOffset createdAtUtc)
    {
        byte[] rawKey = RandomNumberGenerator.GetBytes(KeyLengthBytes);
        try
        {
            string keyId = Base64UrlEncode(RandomNumberGenerator.GetBytes(16));
            byte[] protectedKey = ProtectedData.Protect(
                rawKey,
                ProtectionEntropy,
                DataProtectionScope.LocalMachine);
            var persisted = new PersistedKey
            {
                KeyId = keyId,
                CreatedAtUtc = createdAtUtc,
                Status = PersistedKeyStatus.Active,
                ProtectedKey = Convert.ToBase64String(protectedKey),
            };
            return (
                persisted,
                new ProtectedKeyMaterial(keyId, rawKey.ToArray()));
        }
        finally
        {
            CryptographicOperations.ZeroMemory(rawKey);
        }
    }

    private static void ValidateState(PersistedKeyRing state)
    {
        if (state.Version != CurrentVersion ||
            string.IsNullOrWhiteSpace(state.ActiveKeyId) ||
            state.Keys.Count == 0 ||
            state.Keys.Select(key => key.KeyId).Distinct(StringComparer.Ordinal).Count() !=
            state.Keys.Count ||
            state.Keys.Count(key => key.Status == PersistedKeyStatus.Active) != 1 ||
            !state.Keys.Any(key =>
                key.Status == PersistedKeyStatus.Active &&
                string.Equals(key.KeyId, state.ActiveKeyId, StringComparison.Ordinal)))
        {
            throw new InvalidDataException("The protected key ring state is invalid.");
        }

        foreach (PersistedKey key in state.Keys)
        {
            if (string.IsNullOrWhiteSpace(key.KeyId) ||
                (key.Status != PersistedKeyStatus.Active && key.RetainUntilUtc is null) ||
                (key.Status != PersistedKeyStatus.EmergencyRetired &&
                 string.IsNullOrWhiteSpace(key.ProtectedKey)))
            {
                throw new InvalidDataException("The protected key ring contains an invalid key.");
            }
        }
    }

    private static bool PruneExpiredRetiredKeys(
        PersistedKeyRing state,
        DateTimeOffset now)
    {
        int removed = state.Keys.RemoveAll(key =>
            key.Status != PersistedKeyStatus.Active &&
            key.RetainUntilUtc is { } retainUntilUtc &&
            now >= retainUntilUtc);
        return removed != 0;
    }

    private static JsonSerializerOptions CreateJsonOptions() => new(JsonSerializerDefaults.Web)
    {
        WriteIndented = true,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
    };

    private static string Base64UrlEncode(ReadOnlySpan<byte> bytes) =>
        Convert.ToBase64String(bytes)
            .TrimEnd('=')
            .Replace('+', '-')
            .Replace('/', '_');

    private sealed class PersistedKeyRing
    {
        public int Version { get; set; }

        public string ActiveKeyId { get; set; } = string.Empty;

        public List<PersistedKey> Keys { get; set; } = [];
    }

    private sealed class PersistedKey
    {
        public string KeyId { get; set; } = string.Empty;

        public DateTimeOffset CreatedAtUtc { get; set; }

        public DateTimeOffset? RetainUntilUtc { get; set; }

        public PersistedKeyStatus Status { get; set; }

        public string? ProtectedKey { get; set; }
    }

    [JsonConverter(typeof(JsonStringEnumConverter<PersistedKeyStatus>))]
    private enum PersistedKeyStatus
    {
        Active,
        Retired,
        EmergencyRetired,
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct FileTime
    {
        public uint LowDateTime;
        public uint HighDateTime;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ByHandleFileInformation
    {
        public uint FileAttributes;
        public FileTime CreationTime;
        public FileTime LastAccessTime;
        public FileTime LastWriteTime;
        public uint VolumeSerialNumber;
        public uint FileSizeHigh;
        public uint FileSizeLow;
        public uint NumberOfLinks;
        public uint FileIndexHigh;
        public uint FileIndexLow;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFileW(
        string fileName,
        uint desiredAccess,
        uint shareMode,
        IntPtr securityAttributes,
        uint creationDisposition,
        uint flagsAndAttributes,
        IntPtr templateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileInformationByHandle(
        SafeFileHandle file,
        out ByHandleFileInformation fileInformation);
}
