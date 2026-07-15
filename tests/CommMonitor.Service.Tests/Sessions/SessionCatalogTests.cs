using System.Buffers.Binary;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Text;
using CommMonitor.Core.Ai;
using CommMonitor.Service.Ipc;
using CommMonitor.Service.Security;
using CommMonitor.Service.Sessions;

namespace CommMonitor.Service.Tests.Sessions;

[SupportedOSPlatform("windows")]
public sealed class SessionCatalogTests
{
    [Fact]
    public async Task List_accepts_only_safe_direct_database_children_and_returns_opaque_ids()
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        using var sandbox = new CatalogSandbox();
        File.WriteAllBytes(Path.Combine(sandbox.SessionRoot, "capture.db"), [0x01]);
        File.WriteAllBytes(Path.Combine(sandbox.SessionRoot, "imported.cmsession"), [0x02]);
        File.WriteAllBytes(Path.Combine(sandbox.SessionRoot, "capture.db-wal"), [0x03]);
        File.WriteAllBytes(Path.Combine(sandbox.SessionRoot, "capture.db-shm"), [0x04]);
        File.WriteAllBytes(Path.Combine(sandbox.SessionRoot, "capture.db-journal"), [0x05]);
        File.WriteAllBytes(Path.Combine(sandbox.SessionRoot, "notes.txt"), [0x06]);
        string nested = Directory.CreateDirectory(
            Path.Combine(sandbox.SessionRoot, "nested")).FullName;
        File.WriteAllBytes(Path.Combine(nested, "hidden.db"), [0x07]);

        using ServiceStorageBoundary boundary = sandbox.OpenBoundary();
        ProtectedKeyRing ring = sandbox.CreateKeyRing();
        var catalog = new SessionCatalog(boundary, ring);

        IReadOnlyList<SessionCatalogItem> sessions = await catalog.ListAsync();

        Assert.Equal(["capture", "imported"], sessions.Select(item => item.DisplayName));
        Assert.All(sessions, item =>
        {
            Assert.StartsWith("s1.", item.SessionId, StringComparison.Ordinal);
            Assert.DoesNotContain(sandbox.SessionRoot, item.SessionId, StringComparison.OrdinalIgnoreCase);
            Assert.DoesNotContain(".db", item.SessionId, StringComparison.OrdinalIgnoreCase);
            Assert.DoesNotContain(".cmsession", item.SessionId, StringComparison.OrdinalIgnoreCase);
        });

        foreach (SessionCatalogItem item in sessions)
        {
            using ResolvedSession resolved = await catalog.ResolveAsync(item.SessionId);
            Assert.False(resolved.Handle.IsInvalid);
            Assert.Equal(item.DisplayName, Path.GetFileNameWithoutExtension(resolved.FullPath));
            Assert.Equal(sandbox.SessionRoot, Path.GetDirectoryName(resolved.FullPath));
        }
    }

    [Fact]
    public async Task Session_ids_survive_service_restart_with_the_same_protected_key()
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        using var sandbox = new CatalogSandbox();
        File.WriteAllBytes(Path.Combine(sandbox.SessionRoot, "stable.db"), [0x01]);
        using ServiceStorageBoundary boundary = sandbox.OpenBoundary();

        var firstCatalog = new SessionCatalog(
            boundary,
            sandbox.CreateKeyRing());
        string firstId = Assert.Single(await firstCatalog.ListAsync()).SessionId;

        var restartedCatalog = new SessionCatalog(
            boundary,
            sandbox.CreateKeyRing());
        string restartedId = Assert.Single(await restartedCatalog.ListAsync()).SessionId;

        Assert.Equal(firstId, restartedId);
    }

    [Fact]
    public async Task List_keeps_an_active_database_opened_for_writing_visible()
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        using var sandbox = new CatalogSandbox();
        string sessionPath = Path.Combine(sandbox.SessionRoot, "active.db");
        File.WriteAllBytes(sessionPath, [0x01]);
        using ServiceStorageBoundary boundary = sandbox.OpenBoundary();
        boundary.VerifySessionPath(sessionPath);
        await using var writer = new FileStream(
            sessionPath,
            FileMode.Open,
            FileAccess.ReadWrite,
            FileShare.ReadWrite);
        var catalog = new SessionCatalog(
            boundary,
            sandbox.CreateKeyRing());

        SessionCatalogItem session = Assert.Single(await catalog.ListAsync());

        Assert.Equal("active", session.DisplayName);
    }

    [Fact]
    public async Task List_and_resolve_reject_a_prepositioned_hard_link()
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        using var sandbox = new CatalogSandbox();
        string sessionPath = Path.Combine(sandbox.SessionRoot, "linked.db");
        string outsidePath = Path.Combine(sandbox.OutsideRoot, "outside.db");
        File.WriteAllBytes(outsidePath, [0xAA, 0xBB]);
        CreateHardLink(sessionPath, outsidePath);
        using ServiceStorageBoundary boundary = sandbox.OpenBoundary();
        var catalog = new SessionCatalog(
            boundary,
            sandbox.CreateKeyRing());

        IReadOnlyList<SessionCatalogItem> sessions = await catalog.ListAsync();

        Assert.Empty(sessions);
        Assert.Equal(new byte[] { 0xAA, 0xBB }, File.ReadAllBytes(outsidePath));
    }

    [Fact]
    public async Task Resolve_rejects_a_file_reparse_point_substituted_after_listing()
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        using var sandbox = new CatalogSandbox();
        string sessionPath = Path.Combine(sandbox.SessionRoot, "linked.db");
        string outsidePath = Path.Combine(sandbox.OutsideRoot, "outside.db");
        File.WriteAllBytes(sessionPath, [0x01]);
        File.WriteAllBytes(outsidePath, [0x99]);
        using ServiceStorageBoundary boundary = sandbox.OpenBoundary();
        var catalog = new SessionCatalog(
            boundary,
            sandbox.CreateKeyRing());
        string sessionId = Assert.Single(await catalog.ListAsync()).SessionId;
        File.Delete(sessionPath);
        sandbox.CreateJunction("linked.db", sandbox.OutsideRoot);

        AiSessionException exception = await Assert.ThrowsAsync<AiSessionException>(async () =>
            await catalog.ResolveAsync(sessionId));

        Assert.Equal(AiErrorCodes.SessionNotFound, exception.Code);
        Assert.Equal(new byte[] { 0x99 }, File.ReadAllBytes(outsidePath));
    }

    [Fact]
    public async Task Resolve_rejects_tampered_identifiers_and_files_removed_after_listing()
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        using var sandbox = new CatalogSandbox();
        string sessionPath = Path.Combine(sandbox.SessionRoot, "capture.db");
        File.WriteAllBytes(sessionPath, [0x01]);
        using ServiceStorageBoundary boundary = sandbox.OpenBoundary();
        var catalog = new SessionCatalog(
            boundary,
            sandbox.CreateKeyRing());
        string sessionId = Assert.Single(await catalog.ListAsync()).SessionId;

        AiSessionException tampered = await Assert.ThrowsAsync<AiSessionException>(async () =>
            await catalog.ResolveAsync(MutateLastCharacter(sessionId)));
        Assert.Equal(AiErrorCodes.SessionNotFound, tampered.Code);

        File.Delete(sessionPath);
        AiSessionException missing = await Assert.ThrowsAsync<AiSessionException>(async () =>
            await catalog.ResolveAsync(sessionId));
        Assert.Equal(AiErrorCodes.SessionNotFound, missing.Code);
    }

    [Fact]
    public async Task Replacing_a_session_file_changes_its_id_and_invalidates_old_continuity()
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        using var sandbox = new CatalogSandbox();
        string sessionPath = Path.Combine(sandbox.SessionRoot, "capture.db");
        File.WriteAllBytes(sessionPath, [0x01]);
        using ServiceStorageBoundary boundary = sandbox.OpenBoundary();
        var catalog = new SessionCatalog(
            boundary,
            sandbox.CreateKeyRing());
        string originalId = Assert.Single(await catalog.ListAsync()).SessionId;
        File.Delete(sessionPath);
        File.WriteAllBytes(sessionPath, [0x02]);

        string replacementId = Assert.Single(await catalog.ListAsync()).SessionId;

        Assert.NotEqual(originalId, replacementId);
        AiSessionException exception = await Assert.ThrowsAsync<AiSessionException>(async () =>
            await catalog.ResolveAsync(originalId));
        Assert.Equal(AiErrorCodes.SessionNotFound, exception.Code);
    }

    private static string MutateLastCharacter(string value)
    {
        char replacement = value[^1] == 'A' ? 'B' : 'A';
        return value[..^1] + replacement;
    }

    private static void CreateHardLink(string linkPath, string existingPath)
    {
        if (!CreateHardLinkW(linkPath, existingPath, IntPtr.Zero))
        {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CreateHardLinkW(
        string fileName,
        string existingFileName,
        IntPtr securityAttributes);

    private sealed class CatalogSandbox : IDisposable
    {
        private readonly List<string> _junctions = [];

        public CatalogSandbox()
        {
            Root = Path.Combine(
                Path.GetTempPath(),
                $"lemon-session-catalog-{Guid.NewGuid():N}");
            SessionRoot = Path.Combine(Root, "Sessions");
            ExportRoot = Path.Combine(Root, "Exports");
            MetadataRoot = Path.Combine(Root, "CoreMetadata");
            OutsideRoot = Path.Combine(Root, "Outside");
            Directory.CreateDirectory(SessionRoot);
            Directory.CreateDirectory(ExportRoot);
            Directory.CreateDirectory(MetadataRoot);
            Directory.CreateDirectory(OutsideRoot);
            SecurityOptions = new InstallSecurityOptions
            {
                CoreRootMetadataPath = MetadataRoot,
                AuthorizedUserSid = System.Security.Principal.WindowsIdentity.GetCurrent().User!.Value,
            };
        }

        public string Root { get; }

        public string SessionRoot { get; }

        public string ExportRoot { get; }

        public string MetadataRoot { get; }

        public string OutsideRoot { get; }

        public InstallSecurityOptions SecurityOptions { get; }

        public ProtectedKeyRing CreateKeyRing() =>
            new(SecurityOptions, new PermissiveTestFileSecurityPolicy());

        public ServiceStorageBoundary OpenBoundary() =>
            ServiceStorageBoundary.Open(Root, SessionRoot, ExportRoot);

        public void CreateJunction(string leafName, string target)
        {
            string path = Path.Combine(SessionRoot, leafName);
            Directory.CreateDirectory(path);
            Junction.Create(path, target);
            _junctions.Add(path);
        }

        public void Dispose()
        {
            foreach (string junction in _junctions)
            {
                if (Directory.Exists(junction))
                {
                    Directory.Delete(junction);
                }
            }

            if (File.Exists(Path.Combine(SessionRoot, "linked.db")))
            {
                File.Delete(Path.Combine(SessionRoot, "linked.db"));
            }

            if (Directory.Exists(Root))
            {
                Directory.Delete(Root, recursive: true);
            }
        }
    }

    private sealed class PermissiveTestFileSecurityPolicy : IKeyRingFileSecurityPolicy
    {
        public void ProtectMetadataDirectory(string path)
        {
        }

        public void ProtectKeyRingFile(string path)
        {
        }
    }

    private static class Junction
    {
        private const uint GenericWrite = 0x40000000;
        private const uint FileShareRead = 0x00000001;
        private const uint FileShareWrite = 0x00000002;
        private const uint FileShareDelete = 0x00000004;
        private const uint OpenExisting = 3;
        private const uint FileFlagOpenReparsePoint = 0x00200000;
        private const uint FileFlagBackupSemantics = 0x02000000;
        private const uint FsctlSetReparsePoint = 0x000900A4;
        private const uint IoReparseTagMountPoint = 0xA0000003;

        public static void Create(string junctionPath, string targetPath)
        {
            string fullTarget = Path.GetFullPath(targetPath).TrimEnd(Path.DirectorySeparatorChar);
            string substituteName = @"\??\" + fullTarget;
            byte[] substituteBytes = Encoding.Unicode.GetBytes(substituteName);
            byte[] printBytes = Encoding.Unicode.GetBytes(fullTarget);
            int pathBufferLength = substituteBytes.Length + 2 + printBytes.Length + 2;
            ushort reparseDataLength = checked((ushort)(8 + pathBufferLength));
            byte[] buffer = new byte[8 + reparseDataLength];

            BinaryPrimitives.WriteUInt32LittleEndian(buffer.AsSpan(0, 4), IoReparseTagMountPoint);
            BinaryPrimitives.WriteUInt16LittleEndian(buffer.AsSpan(4, 2), reparseDataLength);
            BinaryPrimitives.WriteUInt16LittleEndian(buffer.AsSpan(8, 2), 0);
            BinaryPrimitives.WriteUInt16LittleEndian(
                buffer.AsSpan(10, 2),
                checked((ushort)substituteBytes.Length));
            BinaryPrimitives.WriteUInt16LittleEndian(
                buffer.AsSpan(12, 2),
                checked((ushort)(substituteBytes.Length + 2)));
            BinaryPrimitives.WriteUInt16LittleEndian(
                buffer.AsSpan(14, 2),
                checked((ushort)printBytes.Length));
            substituteBytes.CopyTo(buffer, 16);
            printBytes.CopyTo(buffer, 16 + substituteBytes.Length + 2);

            using Microsoft.Win32.SafeHandles.SafeFileHandle handle = CreateFileW(
                junctionPath,
                GenericWrite,
                FileShareRead | FileShareWrite | FileShareDelete,
                IntPtr.Zero,
                OpenExisting,
                FileFlagOpenReparsePoint | FileFlagBackupSemantics,
                IntPtr.Zero);
            if (handle.IsInvalid)
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }

            if (!DeviceIoControl(
                    handle,
                    FsctlSetReparsePoint,
                    buffer,
                    buffer.Length,
                    IntPtr.Zero,
                    0,
                    out _,
                    IntPtr.Zero))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern Microsoft.Win32.SafeHandles.SafeFileHandle CreateFileW(
            string fileName,
            uint desiredAccess,
            uint shareMode,
            IntPtr securityAttributes,
            uint creationDisposition,
            uint flagsAndAttributes,
            IntPtr templateFile);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool DeviceIoControl(
            Microsoft.Win32.SafeHandles.SafeFileHandle device,
            uint ioControlCode,
            byte[] inputBuffer,
            int inputBufferSize,
            IntPtr outputBuffer,
            int outputBufferSize,
            out int bytesReturned,
            IntPtr overlapped);
    }
}
