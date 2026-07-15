using System.Buffers.Binary;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using Lemon.UninstallHelper.Manifest;
using Lemon.UninstallHelper.Security;
using Microsoft.Win32.SafeHandles;

namespace Lemon.UninstallHelper.Tests;

public sealed class SafeOwnedTreeDeleteTests
{
    [Fact]
    public void Deletes_a_verified_immutable_file_and_the_empty_approved_root()
    {
        using var sandbox = new DeleteSandbox();
        string file = sandbox.WriteRootFile("app.exe", [0x10, 0x20, 0x30]);
        ApprovedRootManifest manifest = sandbox.Manifest(
            OwnedObject.ImmutableFile(
                "app-exe",
                "app.exe",
                new FileInfo(file).Length,
                Sha256(file),
                "CommMonitor:0.1.0"));

        DeletionReport report = new SafeOwnedTreeDelete().Execute(manifest);

        Assert.Equal(DeletionStatus.Completed, report.Status);
        Assert.Equal(DeletionOutcomeStatus.Deleted, report.Outcome("app-exe").Status);
        Assert.False(Directory.Exists(sandbox.ApprovedRoot));
        sandbox.AssertOutsideSentinel();
    }

    [Fact]
    public void Replaying_a_completed_manifest_reports_every_object_already_absent()
    {
        using var sandbox = new DeleteSandbox();
        string file = sandbox.WriteRootFile("app.exe", [0x10]);
        ApprovedRootManifest manifest = sandbox.Manifest(
            OwnedObject.ImmutableFile(
                "app-exe",
                "app.exe",
                1,
                Sha256(file),
                "CommMonitor:0.1.0"));
        Assert.Equal(
            DeletionStatus.Completed,
            new SafeOwnedTreeDelete().Execute(manifest).Status);

        DeletionReport replay = new SafeOwnedTreeDelete().Execute(manifest);

        Assert.Equal(DeletionStatus.Completed, replay.Status);
        Assert.Equal(
            DeletionOutcomeStatus.AlreadyAbsent,
            replay.Outcome("app-exe").Status);
        sandbox.AssertOutsideSentinel();
    }

    [Fact]
    public void Preserves_an_immutable_file_when_its_hash_does_not_match()
    {
        using var sandbox = new DeleteSandbox();
        string file = sandbox.WriteRootFile("app.exe", [0x10, 0x20, 0x30]);
        ApprovedRootManifest manifest = sandbox.Manifest(
            OwnedObject.ImmutableFile(
                "app-exe",
                "app.exe",
                new FileInfo(file).Length,
                new string('0', 64),
                "CommMonitor:0.1.0"));

        DeletionReport report = new SafeOwnedTreeDelete().Execute(manifest);

        Assert.Equal(DeletionStatus.Failed, report.Status);
        Assert.Equal(DeletionOutcomeStatus.Preserved, report.Outcome("app-exe").Status);
        Assert.True(File.Exists(file));
        sandbox.AssertOutsideSentinel();
    }

    [Fact]
    public void Deletes_only_the_exact_allow_listed_dynamic_lease_file()
    {
        using var sandbox = new DeleteSandbox();
        string lease = sandbox.WriteRootFile(
            "leases.json",
            "{\"active\":false}"u8.ToArray());
        PathIdentitySnapshot leaseIdentity = PathIdentity.Capture(lease);
        ApprovedRootManifest manifest = sandbox.Manifest(
            OwnedObject.DynamicFile(
                "leases",
                "leases.json",
                leaseIdentity.VolumeSerialNumber,
                leaseIdentity.FileId));

        DeletionReport report = new SafeOwnedTreeDelete().Execute(manifest);

        Assert.Equal(DeletionStatus.Completed, report.Status);
        Assert.False(Directory.Exists(sandbox.ApprovedRoot));
        sandbox.AssertOutsideSentinel();
    }

    [Fact]
    public void Rejects_a_dynamic_file_name_outside_the_fixed_allow_list()
    {
        using var sandbox = new DeleteSandbox();
        string file = sandbox.WriteRootFile("arbitrary.json", "{}"u8.ToArray());
        PathIdentitySnapshot identity = PathIdentity.Capture(file);
        ApprovedRootManifest manifest = sandbox.Manifest(
            OwnedObject.DynamicFile(
                "arbitrary",
                "arbitrary.json",
                identity.VolumeSerialNumber,
                identity.FileId));

        DeletionReport report = new SafeOwnedTreeDelete().Execute(manifest);

        Assert.Equal(DeletionStatus.Failed, report.Status);
        Assert.True(File.Exists(file));
        sandbox.AssertOutsideSentinel();
    }

    [Fact]
    public void Preserves_an_allow_listed_dynamic_file_replaced_after_snapshot()
    {
        using var sandbox = new DeleteSandbox();
        string lease = sandbox.WriteRootFile(
            "leases.json",
            "{\"active\":true}"u8.ToArray());
        PathIdentitySnapshot expected = PathIdentity.Capture(lease);
        ApprovedRootManifest manifest = sandbox.Manifest(
            OwnedObject.DynamicFile(
                "leases",
                "leases.json",
                expected.VolumeSerialNumber,
                expected.FileId));
        File.Move(lease, Path.Combine(sandbox.OutsideDirectory, "old-lease.json"));
        File.WriteAllText(lease, "personal replacement");

        DeletionReport report = new SafeOwnedTreeDelete().Execute(manifest);

        Assert.Equal(DeletionStatus.Failed, report.Status);
        Assert.Equal(DeletionOutcomeStatus.Preserved, report.Outcome("leases").Status);
        Assert.Equal("personal replacement", File.ReadAllText(lease));
        sandbox.AssertOutsideSentinel();
    }

    [Fact]
    public void Preserves_and_reports_an_unknown_file()
    {
        using var sandbox = new DeleteSandbox();
        string known = sandbox.WriteRootFile("app.exe", [0x01]);
        string unknown = sandbox.WriteRootFile("notes.txt", [0x02]);
        ApprovedRootManifest manifest = sandbox.Manifest(
            OwnedObject.ImmutableFile(
                "app-exe",
                "app.exe",
                1,
                Sha256(known),
                "CommMonitor:0.1.0"));

        DeletionReport report = new SafeOwnedTreeDelete().Execute(manifest);

        Assert.Equal(DeletionStatus.Failed, report.Status);
        Assert.Contains(
            report.Outcomes,
            outcome => outcome.RelativePath == "notes.txt" &&
                outcome.Status == DeletionOutcomeStatus.Preserved);
        Assert.True(File.Exists(unknown));
        Assert.True(Directory.Exists(sandbox.ApprovedRoot));
        sandbox.AssertOutsideSentinel();
    }

    [Fact]
    public void Preserves_a_known_file_that_contains_an_unowned_named_data_stream()
    {
        using var sandbox = new DeleteSandbox();
        string file = sandbox.WriteRootFile("app.exe", [0x01]);
        File.WriteAllText(file + ":user-notes", "do not delete");
        ApprovedRootManifest manifest = sandbox.Manifest(
            OwnedObject.ImmutableFile(
                "app-exe",
                "app.exe",
                1,
                Sha256(file),
                "CommMonitor:0.1.0"));

        DeletionReport report = new SafeOwnedTreeDelete().Execute(manifest);

        Assert.Equal(DeletionStatus.Failed, report.Status);
        Assert.Equal(DeletionOutcomeStatus.Preserved, report.Outcome("app-exe").Status);
        Assert.True(File.Exists(file));
        Assert.Equal("do not delete", File.ReadAllText(file + ":user-notes"));
        sandbox.AssertOutsideSentinel();
    }

    [Fact]
    public void Concurrent_unknown_creation_prevents_false_completion()
    {
        using var sandbox = new DeleteSandbox();
        string file = sandbox.WriteRootFile("app.exe", [0x01]);
        string injected = Path.Combine(sandbox.ApprovedRoot, "injected.txt");
        var probe = new DelegateRaceProbe(
            onObjectHeld: relativePath =>
            {
                if (relativePath == "app.exe")
                {
                    File.WriteAllText(injected, "late unknown");
                }
            });
        ApprovedRootManifest manifest = sandbox.Manifest(
            OwnedObject.ImmutableFile(
                "app-exe",
                "app.exe",
                1,
                Sha256(file),
                "CommMonitor:0.1.0"));

        DeletionReport report = new SafeOwnedTreeDelete(probe).Execute(manifest);

        Assert.Equal(DeletionStatus.Failed, report.Status);
        Assert.True(File.Exists(injected));
        Assert.True(Directory.Exists(sandbox.ApprovedRoot));
        sandbox.AssertOutsideSentinel();
    }

    [Theory]
    [InlineData("root")]
    [InlineData("child")]
    [InlineData("nested")]
    public void Rejects_a_junction_at_every_depth_without_touching_its_target(string depth)
    {
        using var sandbox = new DeleteSandbox();
        string target = sandbox.OutsideDirectory;
        ApprovedRootManifest manifest;

        if (depth == "root")
        {
            PathIdentitySnapshot original = PathIdentity.Capture(sandbox.ApprovedRoot);
            Directory.Delete(sandbox.ApprovedRoot);
            sandbox.CreateJunction(sandbox.ApprovedRoot, target);
            manifest = new ApprovedRootManifest(
                sandbox.ApprovedRoot,
                original.VolumeSerialNumber,
                original.FileId,
                []);
        }
        else if (depth == "child")
        {
            sandbox.CreateJunction(Path.Combine(sandbox.ApprovedRoot, "linked"), target);
            manifest = sandbox.Manifest(OwnedObject.Directory("linked", "linked"));
        }
        else
        {
            Directory.CreateDirectory(Path.Combine(sandbox.ApprovedRoot, "level"));
            sandbox.CreateJunction(
                Path.Combine(sandbox.ApprovedRoot, "level", "linked"),
                target);
            manifest = sandbox.Manifest(
                OwnedObject.Directory("level", "level"),
                OwnedObject.Directory("linked", @"level\linked"));
        }

        DeletionReport report = new SafeOwnedTreeDelete().Execute(manifest);

        Assert.Equal(DeletionStatus.Failed, report.Status);
        sandbox.AssertOutsideSentinel();
    }

    [Fact]
    public void Rejects_a_hard_link_to_an_outside_file()
    {
        using var sandbox = new DeleteSandbox();
        string link = Path.Combine(sandbox.ApprovedRoot, "linked.bin");
        CreateHardLink(link, sandbox.OutsideSentinel);
        ApprovedRootManifest manifest = sandbox.Manifest(
            OwnedObject.ImmutableFile(
                "linked",
                "linked.bin",
                new FileInfo(link).Length,
                Sha256(link),
                "CommMonitor:0.1.0"));

        DeletionReport report = new SafeOwnedTreeDelete().Execute(manifest);

        Assert.Equal(DeletionStatus.Failed, report.Status);
        Assert.Equal(DeletionOutcomeStatus.Preserved, report.Outcome("linked").Status);
        Assert.True(File.Exists(link));
        sandbox.AssertOutsideSentinel();
    }

    [Fact]
    public void Held_root_handle_blocks_a_root_replacement_race()
    {
        using var sandbox = new DeleteSandbox();
        string file = sandbox.WriteRootFile("app.exe", [0x01]);
        string moved = Path.Combine(sandbox.BasePath, "moved-root");
        var probe = new DelegateRaceProbe(
            onRootHeld: _ => Assert.ThrowsAny<IOException>(
                () => Directory.Move(sandbox.ApprovedRoot, moved)));
        ApprovedRootManifest manifest = sandbox.Manifest(
            OwnedObject.ImmutableFile(
                "app-exe",
                "app.exe",
                1,
                Sha256(file),
                "CommMonitor:0.1.0"));

        DeletionReport report = new SafeOwnedTreeDelete(probe).Execute(manifest);

        Assert.True(probe.RootObserved);
        Assert.Equal(DeletionStatus.Completed, report.Status);
        Assert.False(Directory.Exists(moved));
        sandbox.AssertOutsideSentinel();
    }

    [Fact]
    public void Held_child_handle_blocks_a_child_replacement_race()
    {
        using var sandbox = new DeleteSandbox();
        string file = sandbox.WriteRootFile("app.exe", [0x01]);
        string moved = Path.Combine(sandbox.ApprovedRoot, "moved.exe");
        var probe = new DelegateRaceProbe(
            onObjectHeld: relativePath =>
            {
                if (relativePath == "app.exe")
                {
                    Assert.ThrowsAny<IOException>(() => File.Move(file, moved));
                }
            });
        ApprovedRootManifest manifest = sandbox.Manifest(
            OwnedObject.ImmutableFile(
                "app-exe",
                "app.exe",
                1,
                Sha256(file),
                "CommMonitor:0.1.0"));

        DeletionReport report = new SafeOwnedTreeDelete(probe).Execute(manifest);

        Assert.True(probe.ObjectObserved);
        Assert.Equal(DeletionStatus.Completed, report.Status);
        Assert.False(File.Exists(moved));
        sandbox.AssertOutsideSentinel();
    }

    [Fact]
    public void Locked_file_returns_pending_then_is_revalidated_after_unlock()
    {
        using var sandbox = new DeleteSandbox();
        string file = sandbox.WriteRootFile("app.exe", [0x01]);
        ApprovedRootManifest manifest = sandbox.Manifest(
            OwnedObject.ImmutableFile(
                "app-exe",
                "app.exe",
                1,
                Sha256(file),
                "CommMonitor:0.1.0"));
        DeletionReport pending;
        using (new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.None))
        {
            pending = new SafeOwnedTreeDelete().Execute(manifest);
        }

        Assert.Equal(DeletionStatus.PendingReboot, pending.Status);
        Assert.Equal(
            DeletionOutcomeStatus.PendingReboot,
            pending.Outcome("app-exe").Status);
        Assert.True(File.Exists(file));

        DeletionReport completed = new SafeOwnedTreeDelete().Execute(manifest);
        Assert.Equal(DeletionStatus.Completed, completed.Status);
        Assert.False(Directory.Exists(sandbox.ApprovedRoot));
        sandbox.AssertOutsideSentinel();
    }

    [Fact]
    public void Deletes_known_empty_directories_in_bottom_up_order()
    {
        using var sandbox = new DeleteSandbox();
        string deep = Path.Combine(sandbox.ApprovedRoot, "a", "b");
        Directory.CreateDirectory(deep);
        string file = Path.Combine(deep, "payload.bin");
        File.WriteAllBytes(file, [0x11, 0x22]);
        ApprovedRootManifest manifest = sandbox.Manifest(
            OwnedObject.Directory("a", "a"),
            OwnedObject.Directory("b", @"a\b"),
            OwnedObject.ImmutableFile(
                "payload",
                @"a\b\payload.bin",
                2,
                Sha256(file),
                "CommMonitor:0.1.0"));

        DeletionReport report = new SafeOwnedTreeDelete().Execute(manifest);

        Assert.Equal(DeletionStatus.Completed, report.Status);
        Assert.False(Directory.Exists(sandbox.ApprovedRoot));
        Assert.True(
            report.Outcome("payload").Sequence < report.Outcome("b").Sequence);
        Assert.True(report.Outcome("b").Sequence < report.Outcome("a").Sequence);
        sandbox.AssertOutsideSentinel();
    }

    [Theory]
    [InlineData(@"..\outside\sentinel.bin")]
    [InlineData(@"C:\Windows\System32\kernel32.dll")]
    [InlineData(@"folder\..\payload.bin")]
    [InlineData(@"folder:stream")]
    public void Rejects_malicious_manifest_paths_before_any_deletion(string relativePath)
    {
        using var sandbox = new DeleteSandbox();
        string known = sandbox.WriteRootFile("app.exe", [0x01]);
        ApprovedRootManifest manifest = sandbox.Manifest(
            OwnedObject.ImmutableFile(
                "app-exe",
                relativePath,
                1,
                Sha256(known),
                "CommMonitor:0.1.0"));

        DeletionReport report = new SafeOwnedTreeDelete().Execute(manifest);

        Assert.Equal(DeletionStatus.Failed, report.Status);
        Assert.True(File.Exists(known));
        sandbox.AssertOutsideSentinel();
    }

    [Fact]
    public void Production_source_does_not_register_string_path_reboot_deletion()
    {
        string sourceRoot = FindRepositoryRoot();
        string[] files = Directory.GetFiles(
            Path.Combine(sourceRoot, "src", "Lemon.UninstallHelper"),
            "*.cs",
            SearchOption.AllDirectories);
        string source = string.Join('\n', files.Select(File.ReadAllText));

        Assert.DoesNotContain("MoveFileEx", source, StringComparison.Ordinal);
        Assert.DoesNotContain("Directory.Delete(", source, StringComparison.Ordinal);
        Assert.DoesNotContain("File.Delete(", source, StringComparison.Ordinal);
    }

    private static string Sha256(string path) =>
        Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(path))).ToLowerInvariant();

    private static void CreateHardLink(string linkPath, string existingPath)
    {
        if (!CreateHardLinkW(linkPath, existingPath, IntPtr.Zero))
        {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
    }

    private static string FindRepositoryRoot()
    {
        DirectoryInfo? current = new(AppContext.BaseDirectory);
        while (current is not null && !File.Exists(Path.Combine(current.FullName, "CommMonitor.sln")))
        {
            current = current.Parent;
        }

        return current?.FullName ?? throw new InvalidOperationException("Repository root not found.");
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CreateHardLinkW(
        string fileName,
        string existingFileName,
        IntPtr securityAttributes);

    private sealed class DelegateRaceProbe(
        Action<string>? onRootHeld = null,
        Action<string>? onObjectHeld = null) : IDeletionRaceProbe
    {
        public bool RootObserved { get; private set; }
        public bool ObjectObserved { get; private set; }

        public void RootHeld(string canonicalPath)
        {
            RootObserved = true;
            onRootHeld?.Invoke(canonicalPath);
        }

        public void ObjectHeld(string relativePath)
        {
            ObjectObserved = true;
            onObjectHeld?.Invoke(relativePath);
        }
    }

    private sealed class DeleteSandbox : IDisposable
    {
        private readonly List<string> _junctions = [];

        public DeleteSandbox()
        {
            BasePath = Path.Combine(
                Path.GetTempPath(),
                $"lemon-uninstall-helper-{Guid.NewGuid():N}");
            ApprovedRoot = Path.Combine(BasePath, "approved");
            OutsideDirectory = Path.Combine(BasePath, "outside");
            OutsideSentinel = Path.Combine(OutsideDirectory, "sentinel.bin");
            Directory.CreateDirectory(ApprovedRoot);
            Directory.CreateDirectory(OutsideDirectory);
            File.WriteAllBytes(OutsideSentinel, [0xCA, 0xFE, 0xBA, 0xBE]);
        }

        public string BasePath { get; }
        public string ApprovedRoot { get; }
        public string OutsideDirectory { get; }
        public string OutsideSentinel { get; }

        public string WriteRootFile(string relativePath, byte[] content)
        {
            string path = Path.Combine(ApprovedRoot, relativePath);
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            File.WriteAllBytes(path, content);
            return path;
        }

        public ApprovedRootManifest Manifest(params OwnedObject[] objects)
        {
            PathIdentitySnapshot identity = PathIdentity.Capture(ApprovedRoot);
            return new ApprovedRootManifest(
                ApprovedRoot,
                identity.VolumeSerialNumber,
                identity.FileId,
                objects);
        }

        public void CreateJunction(string junctionPath, string targetPath)
        {
            Directory.CreateDirectory(junctionPath);
            Junction.Create(junctionPath, targetPath);
            _junctions.Add(junctionPath);
        }

        public void AssertOutsideSentinel()
        {
            Assert.True(File.Exists(OutsideSentinel));
            Assert.Equal(
                new byte[] { 0xCA, 0xFE, 0xBA, 0xBE },
                File.ReadAllBytes(OutsideSentinel));
        }

        public void Dispose()
        {
            foreach (string junction in _junctions.OrderByDescending(path => path.Length))
            {
                if (Directory.Exists(junction))
                {
                    Directory.Delete(junction);
                }
            }

            if (Directory.Exists(BasePath))
            {
                Directory.Delete(BasePath, recursive: true);
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
            string fullTarget = Path.GetFullPath(targetPath)
                .TrimEnd(Path.DirectorySeparatorChar);
            string substituteName = @"\??\" + fullTarget;
            byte[] substituteBytes = Encoding.Unicode.GetBytes(substituteName);
            byte[] printBytes = Encoding.Unicode.GetBytes(fullTarget);
            int pathBufferLength = substituteBytes.Length + 2 + printBytes.Length + 2;
            ushort reparseDataLength = checked((ushort)(8 + pathBufferLength));
            byte[] buffer = new byte[8 + reparseDataLength];

            BinaryPrimitives.WriteUInt32LittleEndian(
                buffer.AsSpan(0, 4),
                IoReparseTagMountPoint);
            BinaryPrimitives.WriteUInt16LittleEndian(
                buffer.AsSpan(4, 2),
                reparseDataLength);
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
