using System.Runtime.InteropServices;
using System.Text;
using Lemon.UninstallHelper.CommandLine;
using Lemon.UninstallHelper.Execution;

namespace Lemon.UninstallHelper.Tests;

public sealed class WindowsProtectedStateBoundaryTests
{
    [Fact]
    public void Reads_only_the_ordinary_single_link_manifest_through_the_protected_boundary()
    {
        using var sandbox = new StateSandbox();
        byte[] expected = Encoding.UTF8.GetBytes("authenticated-work\n");
        File.WriteAllBytes(sandbox.ManifestPath, expected);
        var acl = new RecordingAclPolicy();
        var boundary = new WindowsProtectedStateBoundary(sandbox.InstallerRoot, acl);

        byte[] actual = boundary.ReadManifest(sandbox.Command);

        Assert.Equal(expected, actual);
        Assert.Contains(sandbox.InstallerRoot, acl.VerifiedDirectories);
        Assert.Contains(sandbox.StatePath, acl.VerifiedDirectories);
        Assert.Contains(sandbox.ManifestPath, acl.VerifiedFiles);
    }

    [Fact]
    public void Rejects_a_hard_linked_manifest_before_returning_any_bytes()
    {
        using var sandbox = new StateSandbox();
        string source = Path.Combine(sandbox.StatePath, "source.bin");
        File.WriteAllText(source, "outside identity");
        CreateHardLink(sandbox.ManifestPath, source);
        var boundary = new WindowsProtectedStateBoundary(
            sandbox.InstallerRoot,
            new RecordingAclPolicy());

        Assert.Throws<IOException>(() => boundary.ReadManifest(sandbox.Command));
        Assert.Equal("outside identity", File.ReadAllText(source));
    }

    [Fact]
    public void Atomically_writes_and_replaces_only_the_exact_result_file()
    {
        using var sandbox = new StateSandbox();
        File.WriteAllText(sandbox.ResultPath, "old");
        var acl = new RecordingAclPolicy();
        var boundary = new WindowsProtectedStateBoundary(sandbox.InstallerRoot, acl);
        byte[] expected = Encoding.UTF8.GetBytes("authenticated-result\n");

        boundary.WriteResult(sandbox.Command, expected);

        Assert.Equal(expected, File.ReadAllBytes(sandbox.ResultPath));
        string protectedTemporaryPath = Assert.Single(acl.ProtectedFiles);
        Assert.Equal(sandbox.ResultsPath, Path.GetDirectoryName(protectedTemporaryPath));
        Assert.StartsWith(".result-", Path.GetFileName(protectedTemporaryPath));
        Assert.EndsWith(".tmp", protectedTemporaryPath);
        Assert.Contains(sandbox.ResultPath, acl.VerifiedFiles);
        Assert.Contains(sandbox.ResultsPath, acl.VerifiedDirectories);
        Assert.Empty(Directory.EnumerateFiles(sandbox.ResultsPath, ".result-*.tmp"));
    }

    [Fact]
    public void Rejects_a_hard_linked_existing_result_and_preserves_the_sentinel()
    {
        using var sandbox = new StateSandbox();
        string sentinel = Path.Combine(sandbox.BasePath, "outside-sentinel.bin");
        File.WriteAllText(sentinel, "keep");
        CreateHardLink(sandbox.ResultPath, sentinel);
        var boundary = new WindowsProtectedStateBoundary(
            sandbox.InstallerRoot,
            new RecordingAclPolicy());

        Assert.Throws<IOException>(() =>
            boundary.WriteResult(sandbox.Command, Encoding.UTF8.GetBytes("new\n")));

        Assert.Equal("keep", File.ReadAllText(sentinel));
    }

    [Fact]
    public void Enforces_the_acl_policy_before_reading_the_manifest()
    {
        using var sandbox = new StateSandbox();
        File.WriteAllText(sandbox.ManifestPath, "work\n");
        var boundary = new WindowsProtectedStateBoundary(
            sandbox.InstallerRoot,
            new RejectingAclPolicy());

        Assert.Throws<UnauthorizedAccessException>(() =>
            boundary.ReadManifest(sandbox.Command));
    }

    [Fact]
    public void Rejects_oversized_manifest_state()
    {
        using var sandbox = new StateSandbox();
        File.WriteAllBytes(
            sandbox.ManifestPath,
            new byte[WindowsProtectedStateBoundary.MaximumStateBytes + 1]);
        var boundary = new WindowsProtectedStateBoundary(
            sandbox.InstallerRoot,
            new RecordingAclPolicy());

        Assert.Throws<IOException>(() => boundary.ReadManifest(sandbox.Command));
    }

    private static void CreateHardLink(string linkPath, string existingPath)
    {
        if (!CreateHardLinkW(linkPath, existingPath, IntPtr.Zero))
        {
            throw new IOException(
                "Unable to create hard link for test.",
                Marshal.GetExceptionForHR(Marshal.GetHRForLastWin32Error()));
        }
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CreateHardLinkW(
        string fileName,
        string existingFileName,
        IntPtr securityAttributes);

    private sealed class RecordingAclPolicy : IProtectedStateAclPolicy
    {
        public List<string> VerifiedDirectories { get; } = [];
        public List<string> VerifiedFiles { get; } = [];
        public List<string> ProtectedFiles { get; } = [];

        public void VerifyDirectory(string path) => VerifiedDirectories.Add(path);

        public void VerifyFile(string path) => VerifiedFiles.Add(path);

        public void ProtectFile(string path)
        {
            ProtectedFiles.Add(path);
            VerifiedFiles.Add(path);
        }
    }

    private sealed class RejectingAclPolicy : IProtectedStateAclPolicy
    {
        public void VerifyDirectory(string path) =>
            throw new UnauthorizedAccessException("untrusted test ACL");

        public void VerifyFile(string path) =>
            throw new UnauthorizedAccessException("untrusted test ACL");

        public void ProtectFile(string path) =>
            throw new UnauthorizedAccessException("untrusted test ACL");
    }

    private sealed class StateSandbox : IDisposable
    {
        public StateSandbox()
        {
            BasePath = Path.Combine(
                Path.GetTempPath(),
                $"lemon-helper-state-{Guid.NewGuid():N}");
            InstallerRoot = Path.Combine(BasePath, "Installer");
            StatePath = Path.Combine(InstallerRoot, "state");
            ResultsPath = Path.Combine(StatePath, "results");
            ManifestPath = Path.Combine(StatePath, "uninstall-work.v1.json");
            ResultPath = Path.Combine(
                ResultsPath,
                "11111111-1111-1111-1111-111111111111.completion.v1.json");
            Directory.CreateDirectory(ResultsPath);
            Command = new HelperCommand(
                ManifestPath,
                Guid.Parse("11111111-1111-1111-1111-111111111111"),
                ResultPath);
        }

        public string BasePath { get; }
        public string InstallerRoot { get; }
        public string StatePath { get; }
        public string ResultsPath { get; }
        public string ManifestPath { get; }
        public string ResultPath { get; }
        public HelperCommand Command { get; }

        public void Dispose()
        {
            if (Directory.Exists(BasePath))
            {
                Directory.Delete(BasePath, recursive: true);
            }
        }
    }
}
