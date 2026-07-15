using System.Buffers.Binary;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using CommMonitor.Core.Sessions;
using CommMonitor.Service.Capture;
using CommMonitor.Service.Ipc;
using CommMonitor.Service.Ports;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Win32.SafeHandles;

namespace CommMonitor.Service.Tests.Ipc;

[SupportedOSPlatform("windows")]
public sealed class ServiceStorageSecurityTests
{
    [Fact]
    public async Task Constructor_rejects_a_session_root_junction_before_it_can_escape()
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        using var sandbox = new StorageSandbox();
        string outside = sandbox.CreateDirectory("outside");
        string sessionJunction = sandbox.CreateJunction("Sessions", outside);
        (CaptureCoordinator coordinator, FakeCaptureSource source) = CreateCoordinator();
        PipeServer? server = null;

        try
        {
            Exception? exception = Record.Exception(() =>
                server = CreateServer(coordinator, source, sessionJunction));

            Assert.IsAssignableFrom<IOException>(exception);
            Assert.Empty(Directory.EnumerateFileSystemEntries(outside));
        }
        finally
        {
            server?.Dispose();
            await coordinator.DisposeAsync();
        }
    }

    [Fact]
    public async Task Constructor_rejects_an_export_root_junction_before_it_can_escape()
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        using var sandbox = new StorageSandbox();
        string sessionRoot = sandbox.CreateDirectory("Sessions");
        string outside = sandbox.CreateDirectory("outside");
        string exportJunction = sandbox.CreateJunction("Exports", outside);
        (CaptureCoordinator coordinator, FakeCaptureSource source) = CreateCoordinator();
        PipeServer? server = null;

        try
        {
            Exception? exception = Record.Exception(() =>
                server = CreateServer(coordinator, source, sessionRoot, exportJunction));

            Assert.IsAssignableFrom<IOException>(exception);
            Assert.Empty(Directory.EnumerateFileSystemEntries(outside));
        }
        finally
        {
            server?.Dispose();
            await coordinator.DisposeAsync();
        }
    }

    [Fact]
    public async Task Constructor_protects_the_managed_root_acl_and_keeps_trusted_ownership()
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        using var sandbox = new StorageSandbox();
        string sessionRoot = sandbox.CreateDirectory("Managed");
        (CaptureCoordinator coordinator, FakeCaptureSource source) = CreateCoordinator();
        PipeServer? server = null;

        try
        {
            server = CreateServer(coordinator, source, sessionRoot);

            DirectorySecurity security = new DirectoryInfo(sessionRoot).GetAccessControl(
                AccessControlSections.Access | AccessControlSections.Owner);
            Assert.True(security.AreAccessRulesProtected);

            var trustedSids = new HashSet<SecurityIdentifier>
            {
                new(WellKnownSidType.LocalSystemSid, domainSid: null),
                new(WellKnownSidType.BuiltinAdministratorsSid, domainSid: null),
                WindowsIdentity.GetCurrent().User!,
            };
            SecurityIdentifier owner = Assert.IsType<SecurityIdentifier>(
                security.GetOwner(typeof(SecurityIdentifier)));
            Assert.Contains(owner, trustedSids);

            AuthorizationRuleCollection rules = security.GetAccessRules(
                includeExplicit: true,
                includeInherited: false,
                typeof(SecurityIdentifier));
            foreach (FileSystemAccessRule rule in rules.Cast<FileSystemAccessRule>())
            {
                if (rule.AccessControlType == AccessControlType.Allow &&
                    (rule.FileSystemRights & DangerousWriteRights) != 0)
                {
                    Assert.Contains((SecurityIdentifier)rule.IdentityReference, trustedSids);
                }
            }
        }
        finally
        {
            server?.Dispose();
            await coordinator.DisposeAsync();
        }
    }

    [Fact]
    public async Task Open_server_handle_prevents_the_managed_root_from_being_swapped()
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        using var sandbox = new StorageSandbox();
        string sessionRoot = sandbox.CreateDirectory("Managed");
        string movedPath = Path.Combine(sandbox.Root, "Moved");
        (CaptureCoordinator coordinator, FakeCaptureSource source) = CreateCoordinator();
        PipeServer? server = null;

        try
        {
            server = CreateServer(coordinator, source, sessionRoot);

            Exception? exception = Record.Exception(() =>
                Directory.Move(sessionRoot, movedPath));

            Assert.IsAssignableFrom<IOException>(exception);
            Assert.True(Directory.Exists(sessionRoot));
            Assert.False(Directory.Exists(movedPath));
        }
        finally
        {
            server?.Dispose();
            await coordinator.DisposeAsync();

            if (Directory.Exists(movedPath) && !Directory.Exists(sessionRoot))
            {
                Directory.Move(movedPath, sessionRoot);
            }
        }
    }

    [Fact]
    public void Export_acl_is_read_only_for_builtin_users_while_sessions_remain_private()
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        using var sandbox = new StorageSandbox();
        string sessionRoot = sandbox.CreateDirectory("Sessions");
        string exportRoot = sandbox.CreateDirectory("Exports");
        using ServiceStorageBoundary boundary = ServiceStorageBoundary.Open(
            sandbox.Root,
            sessionRoot,
            exportRoot);
        string exportFile = Path.Combine(exportRoot, "capture.raw");
        File.WriteAllBytes(exportFile, [0x01]);
        boundary.VerifyExportPath(exportFile);
        var usersSid = new SecurityIdentifier(WellKnownSidType.BuiltinUsersSid, domainSid: null);

        DirectorySecurity sessionSecurity = new DirectoryInfo(sessionRoot).GetAccessControl(
            AccessControlSections.Access);
        DirectorySecurity exportSecurity = new DirectoryInfo(exportRoot).GetAccessControl(
            AccessControlSections.Access);
        FileSecurity exportFileSecurity = new FileInfo(exportFile).GetAccessControl(
            AccessControlSections.Access);

        AssertNoAllowRule(sessionSecurity, usersSid, FileSystemRights.ReadData);
        AssertAllowRule(exportSecurity, usersSid, FileSystemRights.ReadAndExecute);
        AssertNoAllowRule(exportSecurity, usersSid, DangerousWriteRights);
        AssertAllowRule(exportFileSecurity, usersSid, FileSystemRights.Read);
        AssertNoAllowRule(exportFileSecurity, usersSid, DangerousWriteRights);
    }

    [Theory]
    [InlineData(false, "capture.db")]
    [InlineData(false, "capture.db-wal")]
    [InlineData(true, "capture.raw")]
    public void Write_validation_rejects_prepositioned_hard_links_to_files_outside_storage(
        bool export,
        string linkedLeafName)
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        using var sandbox = new StorageSandbox();
        string sessionRoot = sandbox.CreateDirectory("Sessions");
        string exportRoot = sandbox.CreateDirectory("Exports");
        using ServiceStorageBoundary boundary = ServiceStorageBoundary.Open(
            sandbox.Root,
            sessionRoot,
            exportRoot);
        string outsideFile = Path.Combine(sandbox.CreateDirectory("outside"), "victim.bin");
        File.WriteAllBytes(outsideFile, [0xAA, 0xBB]);
        string storageRoot = export ? exportRoot : sessionRoot;
        string linkedPath = Path.Combine(storageRoot, linkedLeafName);
        CreateHardLink(linkedPath, outsideFile);

        IOException exception = Assert.Throws<IOException>(() =>
        {
            if (export)
            {
                boundary.VerifyExportPath(linkedPath);
            }
            else
            {
                boundary.VerifySessionPath(Path.Combine(sessionRoot, "capture.db"));
            }
        });

        Assert.Contains("link", exception.Message, StringComparison.OrdinalIgnoreCase);
        Assert.Equal(new byte[] { 0xAA, 0xBB }, File.ReadAllBytes(outsideFile));
    }

    private const FileSystemRights DangerousWriteRights =
        FileSystemRights.WriteData |
        FileSystemRights.AppendData |
        FileSystemRights.WriteAttributes |
        FileSystemRights.WriteExtendedAttributes |
        FileSystemRights.Delete |
        FileSystemRights.DeleteSubdirectoriesAndFiles |
        FileSystemRights.ChangePermissions |
        FileSystemRights.TakeOwnership;

    private static void AssertAllowRule(
        FileSystemSecurity security,
        SecurityIdentifier sid,
        FileSystemRights expectedRights)
    {
        FileSystemAccessRule? rule = security
            .GetAccessRules(includeExplicit: true, includeInherited: true, typeof(SecurityIdentifier))
            .Cast<FileSystemAccessRule>()
            .FirstOrDefault(candidate =>
                candidate.AccessControlType == AccessControlType.Allow &&
                sid.Equals(candidate.IdentityReference) &&
                (candidate.FileSystemRights & expectedRights) == expectedRights);
        Assert.NotNull(rule);
    }

    private static void AssertNoAllowRule(
        FileSystemSecurity security,
        SecurityIdentifier sid,
        FileSystemRights forbiddenRights)
    {
        Assert.DoesNotContain(
            security
                .GetAccessRules(
                    includeExplicit: true,
                    includeInherited: true,
                    typeof(SecurityIdentifier))
                .Cast<FileSystemAccessRule>(),
            candidate =>
                candidate.AccessControlType == AccessControlType.Allow &&
                sid.Equals(candidate.IdentityReference) &&
                (candidate.FileSystemRights & forbiddenRights) != 0);
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

    private static (CaptureCoordinator Coordinator, FakeCaptureSource Source) CreateCoordinator()
    {
        var source = new FakeCaptureSource();
        var coordinator = new CaptureCoordinator(
            source,
            new SingleSessionStoreFactory(new NonPersistingSessionStore()));
        return (coordinator, source);
    }

    private static PipeServer CreateServer(
        CaptureCoordinator coordinator,
        FakeCaptureSource source,
        string sessionRoot,
        string? exportRoot = null)
    {
        var catalog = new EmptyPortCatalog();
        string pipeName = $"CommMonitor.Service.Storage.Tests.{Guid.NewGuid():N}";
        return exportRoot is null
            ? new PipeServer(
                coordinator,
                catalog,
                source,
                NullLogger<PipeServer>.Instance,
                pipeName,
                sessionRoot)
            : new PipeServer(
                coordinator,
                catalog,
                source,
                NullLogger<PipeServer>.Instance,
                pipeName,
                sessionRoot,
                exportRoot);
    }

    private sealed class EmptyPortCatalog : IPortCatalog
    {
        public ValueTask<IReadOnlyList<PortInfo>> GetPortsAsync(
            CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            return ValueTask.FromResult<IReadOnlyList<PortInfo>>([]);
        }
    }

    private sealed class NonPersistingSessionStore : ISessionStore
    {
        public Task InitializeAsync(CancellationToken cancellationToken = default) =>
            Task.CompletedTask;

        public Task<int> GetSchemaVersionAsync(CancellationToken cancellationToken = default) =>
            Task.FromResult(3);

        public Task<long> GetLastSequenceAsync(CancellationToken cancellationToken = default) =>
            Task.FromResult(0L);

        public Task<long> CountRunsAsync(CancellationToken cancellationToken = default) =>
            Task.FromResult(0L);

        public Task UpsertRunAsync(
            CaptureRunRecord run,
            CancellationToken cancellationToken = default) =>
            Task.CompletedTask;

        public Task<IReadOnlyList<CaptureRunRecord>> ReadRunsAsync(
            CancellationToken cancellationToken = default) =>
            Task.FromResult<IReadOnlyList<CaptureRunRecord>>([]);

        public Task<IReadOnlyList<IntegrityMarker>> ReadMarkersAsync(
            string runId,
            CancellationToken cancellationToken = default) =>
            Task.FromResult<IReadOnlyList<IntegrityMarker>>([]);

        public Task<IReadOnlyList<CommMonitor.Core.Models.CaptureEvent>> AppendBatchAsync(
            PersistBatch batch,
            CancellationToken cancellationToken = default) =>
            Task.FromResult(batch.Events);

        public Task<IReadOnlyList<CommMonitor.Core.Models.CaptureEvent>> AppendAsync(
            IReadOnlyList<CommMonitor.Core.Models.CaptureEvent> events,
            CancellationToken cancellationToken = default) =>
            Task.FromResult(events);

        public Task<IReadOnlyList<CommMonitor.Core.Models.CaptureEvent>> ReadAfterAsync(
            long sequence,
            int limit,
            CancellationToken cancellationToken = default) =>
            Task.FromResult<IReadOnlyList<CommMonitor.Core.Models.CaptureEvent>>([]);

        public Task ClearAsync(CancellationToken cancellationToken = default) =>
            Task.CompletedTask;
    }

    private sealed class SingleSessionStoreFactory(ISessionStore store) : ISessionStoreFactory
    {
        public ISessionStore Create(string path) => store;
    }

    private sealed class StorageSandbox : IDisposable
    {
        private readonly List<string> _junctions = [];

        public StorageSandbox()
        {
            Root = Path.Combine(
                Path.GetTempPath(),
                $"commmonitor-storage-security-{Guid.NewGuid():N}");
            Directory.CreateDirectory(Root);
        }

        public string Root { get; }

        public string CreateDirectory(string leafName)
        {
            string path = Path.Combine(Root, leafName);
            Directory.CreateDirectory(path);
            return path;
        }

        public string CreateJunction(string leafName, string target)
        {
            string path = Path.Combine(Root, leafName);
            Directory.CreateDirectory(path);
            Junction.Create(path, target);
            _junctions.Add(path);
            return path;
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

            if (Directory.Exists(Root))
            {
                Directory.Delete(Root, recursive: true);
            }
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

            using SafeFileHandle handle = CreateFileW(
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
        private static extern bool DeviceIoControl(
            SafeFileHandle device,
            uint ioControlCode,
            byte[] inputBuffer,
            int inputBufferSize,
            IntPtr outputBuffer,
            int outputBufferSize,
            out int bytesReturned,
            IntPtr overlapped);
    }
}
