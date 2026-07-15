using System.Buffers.Binary;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Security.Cryptography;
using System.Text;
using CommMonitor.Core.Ai;
using CommMonitor.Service.Ipc;
using CommMonitor.Service.Security;
using Microsoft.Win32.SafeHandles;

namespace CommMonitor.Service.Sessions;

internal sealed record SessionCatalogItem(
    string SessionId,
    string DisplayName);

internal readonly record struct SessionFileIdentity(
    uint VolumeSerialNumber,
    ulong FileIndex);

internal sealed class ResolvedSession : IDisposable
{
    public ResolvedSession(
        string sessionId,
        string displayName,
        string fullPath,
        SessionFileIdentity identity,
        SafeFileHandle handle)
    {
        SessionId = sessionId;
        DisplayName = displayName;
        FullPath = fullPath;
        Identity = identity;
        Handle = handle;
    }

    public string SessionId { get; }

    public string DisplayName { get; }

    public string FullPath { get; }

    public SessionFileIdentity Identity { get; }

    public SafeFileHandle Handle { get; }

    public void Dispose() => Handle.Dispose();
}

internal sealed class AiSessionException : Exception
{
    public AiSessionException(string code, string message, Exception? innerException = null)
        : base(message, innerException)
    {
        Code = code;
    }

    public string Code { get; }
}

[SupportedOSPlatform("windows")]
internal sealed class SessionCatalog
{
    private const string SessionIdPrefix = "s1";
    private const uint FileReadAttributes = 0x00000080;
    private const uint FileShareRead = 0x00000001;
    private const uint FileShareWrite = 0x00000002;
    private const uint OpenExisting = 3;
    private const uint FileFlagOpenReparsePoint = 0x00200000;
    private const uint FileAttributeReparsePoint = 0x00000400;
    private const uint FileAttributeDirectory = 0x00000010;
    private const uint FileNameNormalized = 0x0;
    private const uint VolumeNameDos = 0x0;
    private static readonly byte[] SessionPurpose =
        Encoding.UTF8.GetBytes("lemon/session-id/v1");

    private readonly ServiceStorageBoundary _storageBoundary;
    private readonly IProtectedKeyRing _keyRing;

    public SessionCatalog(
        ServiceStorageBoundary storageBoundary,
        IProtectedKeyRing keyRing)
    {
        _storageBoundary = storageBoundary ?? throw new ArgumentNullException(nameof(storageBoundary));
        _keyRing = keyRing ?? throw new ArgumentNullException(nameof(keyRing));
    }

    public async ValueTask<IReadOnlyList<SessionCatalogItem>> ListAsync(
        CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        ProtectedKeyMaterial active = await _keyRing.GetActiveKeyAsync(cancellationToken)
            .ConfigureAwait(false);
        byte[] purposeKey = DerivePurposeKey(active.KeyBytes.Span);
        try
        {
            var sessions = new List<SessionCatalogItem>();
            foreach (string path in EnumerateCandidatePaths())
            {
                cancellationToken.ThrowIfCancellationRequested();
                ResolvedSession? candidate = TryOpenCandidate(path, sessionId: string.Empty);
                if (candidate is null)
                {
                    continue;
                }

                using (candidate)
                {
                    string fileName = Path.GetFileName(candidate.FullPath);
                    sessions.Add(new SessionCatalogItem(
                        CreateSessionId(
                            active.KeyId,
                            purposeKey,
                            fileName,
                            candidate.Identity),
                        Path.GetFileNameWithoutExtension(fileName)));
                }
            }

            return sessions;
        }
        finally
        {
            CryptographicOperations.ZeroMemory(purposeKey);
        }
    }

    public async ValueTask<ResolvedSession> ResolveAsync(
        string sessionId,
        CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (!TryParseSessionId(sessionId, out string keyId, out byte[] suppliedTag))
        {
            throw NotFound();
        }

        ProtectedKeyMaterial key;
        try
        {
            key = await _keyRing.GetKeyAsync(keyId, DateTimeOffset.UtcNow, cancellationToken)
                .ConfigureAwait(false);
        }
        catch (Exception exception) when (
            exception is ProtectedKeyRingException or IOException or CryptographicException)
        {
            throw NotFound(exception);
        }

        byte[] purposeKey = DerivePurposeKey(key.KeyBytes.Span);
        try
        {
            foreach (string path in EnumerateCandidatePaths())
            {
                cancellationToken.ThrowIfCancellationRequested();
                ResolvedSession? candidate = TryOpenCandidate(path, sessionId);
                if (candidate is null)
                {
                    continue;
                }

                string fileName = Path.GetFileName(candidate.FullPath);
                byte[] expectedTag = ComputeSessionTag(
                    purposeKey,
                    fileName,
                    candidate.Identity);
                bool matches = CryptographicOperations.FixedTimeEquals(expectedTag, suppliedTag);
                CryptographicOperations.ZeroMemory(expectedTag);
                if (matches)
                {
                    return candidate;
                }

                candidate.Dispose();
            }
        }
        finally
        {
            CryptographicOperations.ZeroMemory(purposeKey);
            CryptographicOperations.ZeroMemory(suppliedTag);
        }

        throw NotFound();
    }

    private IEnumerable<string> EnumerateCandidatePaths() =>
        Directory
            .EnumerateFileSystemEntries(
                _storageBoundary.SessionRoot,
                "*",
                SearchOption.TopDirectoryOnly)
            .Where(path => IsAllowedExtension(Path.GetFileName(path)))
            .OrderBy(Path.GetFileName, StringComparer.OrdinalIgnoreCase);

    private ResolvedSession? TryOpenCandidate(string path, string sessionId)
    {
        SafeFileHandle? handle = null;
        try
        {
            string canonicalPath = Path.GetFullPath(path);
            EnsureDirectChild(canonicalPath);
            _storageBoundary.VerifySessionPath(canonicalPath);
            handle = CreateFileW(
                canonicalPath,
                FileReadAttributes,
                FileShareRead | FileShareWrite,
                IntPtr.Zero,
                OpenExisting,
                FileFlagOpenReparsePoint,
                IntPtr.Zero);
            if (handle.IsInvalid)
            {
                int error = Marshal.GetLastWin32Error();
                handle.Dispose();
                handle = null;
                if (error is 2 or 3)
                {
                    return null;
                }

                throw new Win32Exception(error);
            }

            FileAttributeTagInfo attributes = GetAttributeTagInfo(handle, canonicalPath);
            if ((attributes.FileAttributes & FileAttributeReparsePoint) != 0 ||
                (attributes.FileAttributes & FileAttributeDirectory) != 0)
            {
                return DisposeAndReturnNull(ref handle);
            }

            if (!GetFileInformationByHandle(handle, out ByHandleFileInformation information))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }

            if (information.NumberOfLinks != 1)
            {
                return DisposeAndReturnNull(ref handle);
            }

            string resolvedPath = NormalizeFinalPath(GetFinalPath(handle));
            EnsureDirectChild(resolvedPath);
            if (!string.Equals(
                    resolvedPath,
                    canonicalPath,
                    StringComparison.OrdinalIgnoreCase))
            {
                return DisposeAndReturnNull(ref handle);
            }

            string displayName = Path.GetFileNameWithoutExtension(resolvedPath);
            var identity = new SessionFileIdentity(
                information.VolumeSerialNumber,
                ((ulong)information.FileIndexHigh << 32) | information.FileIndexLow);
            var resolved = new ResolvedSession(
                sessionId,
                displayName,
                resolvedPath,
                identity,
                handle);
            handle = null;
            return resolved;
        }
        catch (Exception exception) when (
            exception is IOException or UnauthorizedAccessException or Win32Exception or ArgumentException)
        {
            return null;
        }
        finally
        {
            handle?.Dispose();
        }
    }

    private static ResolvedSession? DisposeAndReturnNull(ref SafeFileHandle? handle)
    {
        handle?.Dispose();
        handle = null;
        return null;
    }

    private void EnsureDirectChild(string path)
    {
        string parent = Path.GetDirectoryName(path) ?? string.Empty;
        if (!string.Equals(
                Path.GetFullPath(parent),
                Path.GetFullPath(_storageBoundary.SessionRoot),
                StringComparison.OrdinalIgnoreCase) ||
            !IsAllowedExtension(Path.GetFileName(path)))
        {
            throw new IOException("The session file is not a safe direct child.");
        }
    }

    private static bool IsAllowedExtension(string fileName)
    {
        string extension = Path.GetExtension(fileName);
        return extension.Equals(".db", StringComparison.OrdinalIgnoreCase) ||
               extension.Equals(".cmsession", StringComparison.OrdinalIgnoreCase);
    }

    private static string CreateSessionId(
        string keyId,
        ReadOnlySpan<byte> purposeKey,
        string fileName,
        SessionFileIdentity identity) =>
        string.Join('.', SessionIdPrefix, keyId, Base64UrlEncode(
            ComputeSessionTag(purposeKey, fileName, identity)));

    private static byte[] ComputeSessionTag(
        ReadOnlySpan<byte> purposeKey,
        string fileName,
        SessionFileIdentity identity)
    {
        string normalizedName = fileName.Normalize(NormalizationForm.FormC).ToUpperInvariant();
        byte[] nameBytes = Encoding.UTF8.GetBytes(normalizedName);
        byte[] identityBytes = new byte[nameBytes.Length + 1 + sizeof(uint) + sizeof(ulong)];
        nameBytes.CopyTo(identityBytes, 0);
        BinaryPrimitives.WriteUInt32LittleEndian(
            identityBytes.AsSpan(nameBytes.Length + 1, sizeof(uint)),
            identity.VolumeSerialNumber);
        BinaryPrimitives.WriteUInt64LittleEndian(
            identityBytes.AsSpan(nameBytes.Length + 1 + sizeof(uint), sizeof(ulong)),
            identity.FileIndex);
        using var hmac = new HMACSHA256(purposeKey.ToArray());
        return hmac.ComputeHash(identityBytes);
    }

    private static byte[] DerivePurposeKey(ReadOnlySpan<byte> masterKey)
    {
        using var hmac = new HMACSHA256(masterKey.ToArray());
        return hmac.ComputeHash(SessionPurpose);
    }

    private static bool TryParseSessionId(
        string sessionId,
        out string keyId,
        out byte[] tag)
    {
        keyId = string.Empty;
        tag = [];
        if (string.IsNullOrWhiteSpace(sessionId))
        {
            return false;
        }

        string[] components = sessionId.Split('.');
        if (components.Length != 3 ||
            !string.Equals(components[0], SessionIdPrefix, StringComparison.Ordinal) ||
            string.IsNullOrWhiteSpace(components[1]) ||
            !TryBase64UrlDecode(components[2], out tag) ||
            tag.Length != 32)
        {
            tag = [];
            return false;
        }

        keyId = components[1];
        return true;
    }

    private static bool TryBase64UrlDecode(string value, out byte[] bytes)
    {
        bytes = [];
        if (value.Length == 0 || value.Length % 4 == 1)
        {
            return false;
        }

        try
        {
            string base64 = value.Replace('-', '+').Replace('_', '/');
            base64 = base64.PadRight(base64.Length + ((4 - base64.Length % 4) % 4), '=');
            bytes = Convert.FromBase64String(base64);
            if (!string.Equals(Base64UrlEncode(bytes), value, StringComparison.Ordinal))
            {
                bytes = [];
                return false;
            }

            return true;
        }
        catch (FormatException)
        {
            return false;
        }
    }

    private static string Base64UrlEncode(ReadOnlySpan<byte> bytes) =>
        Convert.ToBase64String(bytes)
            .TrimEnd('=')
            .Replace('+', '-')
            .Replace('/', '_');

    private static FileAttributeTagInfo GetAttributeTagInfo(
        SafeFileHandle handle,
        string path)
    {
        if (!GetFileInformationByHandleEx(
                handle,
                FileInfoByHandleClass.FileAttributeTagInfo,
                out FileAttributeTagInfo attributes,
                (uint)Marshal.SizeOf<FileAttributeTagInfo>()))
        {
            throw new Win32Exception(
                Marshal.GetLastWin32Error(),
                $"Unable to inspect session file {path}.");
        }

        return attributes;
    }

    private static string GetFinalPath(SafeFileHandle handle)
    {
        var buffer = new StringBuilder(512);
        while (true)
        {
            uint length = GetFinalPathNameByHandleW(
                handle,
                buffer,
                (uint)buffer.Capacity,
                FileNameNormalized | VolumeNameDos);
            if (length == 0)
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }

            if (length < buffer.Capacity)
            {
                return buffer.ToString();
            }

            buffer.Capacity = checked((int)length + 1);
        }
    }

    private static string NormalizeFinalPath(string path)
    {
        const string uncPrefix = @"\\?\UNC\";
        const string devicePrefix = @"\\?\";
        string normalized = path.StartsWith(uncPrefix, StringComparison.OrdinalIgnoreCase)
            ? @"\\" + path[uncPrefix.Length..]
            : path.StartsWith(devicePrefix, StringComparison.OrdinalIgnoreCase)
                ? path[devicePrefix.Length..]
                : path;
        return Path.GetFullPath(normalized);
    }

    private static AiSessionException NotFound(Exception? innerException = null) =>
        new(
            AiErrorCodes.SessionNotFound,
            "The requested session does not exist or is not a safe managed session.",
            innerException);

    private enum FileInfoByHandleClass
    {
        FileAttributeTagInfo = 9,
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct FileAttributeTagInfo
    {
        public uint FileAttributes;
        public uint ReparseTag;
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
    private static extern bool GetFileInformationByHandleEx(
        SafeFileHandle file,
        FileInfoByHandleClass fileInformationClass,
        out FileAttributeTagInfo fileInformation,
        uint bufferSize);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileInformationByHandle(
        SafeFileHandle file,
        out ByHandleFileInformation fileInformation);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetFinalPathNameByHandleW(
        SafeFileHandle file,
        StringBuilder filePath,
        uint filePathLength,
        uint flags);
}
