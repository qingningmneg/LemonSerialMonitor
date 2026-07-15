using Lemon.UninstallHelper.Security;
using System.Security.AccessControl;

namespace Lemon.UninstallHelper.Tests;

public sealed class OwnershipPathProbeTests : IDisposable
{
    private readonly string _root = Path.Combine(
        Path.GetTempPath(),
        "LemonOwnershipProbeTests",
        Guid.NewGuid().ToString("N"));

    public OwnershipPathProbeTests()
    {
        Directory.CreateDirectory(_root);
    }

    [Fact]
    public void Captures_an_existing_empty_directory_and_complete_ancestor_chain()
    {
        string target = Path.Combine(_root, "empty");
        Directory.CreateDirectory(target);

        OwnershipPathProbeResult result = OwnershipPathProbe.Capture(target);

        Assert.Equal("FileSystem", result.Provider);
        Assert.Equal("Fixed", result.VolumeKind);
        Assert.Matches("^[0-9a-f]{16}$", result.VolumeSerialNumber);
        Assert.Equal(Path.GetFullPath(target), result.RequestedPath, ignoreCase: true);
        Assert.Equal(Path.GetFullPath(target), result.FinalPath, ignoreCase: true);
        Assert.True(result.Exists);
        Assert.True(result.IsDirectory);
        Assert.True(result.IsEmpty);
        Assert.False(result.IsReparse);
        Assert.Matches("^[0-9a-f]{32}$", result.FileId!);
        Assert.Null(result.ExistingParentFileId);
        Assert.Equal(result.FileId, result.NearestExistingAncestor.FileId);
        Assert.Equal(string.Empty, result.UnresolvedSuffix);
        Assert.NotEmpty(result.Ancestors);
        Assert.All(result.Ancestors, ancestor =>
        {
            Assert.Equal(result.VolumeSerialNumber, ancestor.VolumeSerial);
            Assert.Matches("^[0-9a-f]{32}$", ancestor.FileId);
            Assert.Equal(0U, ancestor.ReparseTag);
        });
        Assert.Equal(
            result.NearestExistingAncestor.FileId,
            result.Ancestors[^1].FileId);
    }

    [Fact]
    public void Captures_a_nonexistent_target_from_its_nearest_existing_ancestor()
    {
        string target = Path.Combine(_root, "missing", "child");

        OwnershipPathProbeResult result = OwnershipPathProbe.Capture(target);

        Assert.False(result.Exists);
        Assert.True(result.IsDirectory);
        Assert.True(result.IsEmpty);
        Assert.Null(result.FinalPath);
        Assert.Null(result.FileId);
        Assert.Equal(
            result.NearestExistingAncestor.FileId,
            result.ExistingParentFileId);
        Assert.Equal(Path.GetFullPath(_root), result.NearestExistingAncestor.RequestedPath, ignoreCase: true);
        Assert.Equal(Path.Combine("missing", "child"), result.UnresolvedSuffix);
    }

    [Fact]
    public void Reports_a_nonempty_existing_directory_without_enumerating_recursively()
    {
        string target = Path.Combine(_root, "nonempty");
        Directory.CreateDirectory(target);
        File.WriteAllText(Path.Combine(target, "sentinel.txt"), "do not remove");

        OwnershipPathProbeResult result = OwnershipPathProbe.Capture(target);

        Assert.True(result.Exists);
        Assert.False(result.IsEmpty);
    }

    [Fact]
    public void Rejects_a_file_used_as_an_intermediate_ancestor()
    {
        string blocker = Path.Combine(_root, "blocker");
        File.WriteAllText(blocker, "file");

        Assert.Throws<IOException>(() =>
            OwnershipPathProbe.Capture(Path.Combine(blocker, "child")));
    }

    [Fact]
    public void Emits_a_typed_acl_profile_for_the_existing_boundary()
    {
        OwnershipPathProbeResult result = OwnershipPathProbe.Capture(_root);

        Assert.False(string.IsNullOrWhiteSpace(result.AclProfile.OwnerSid));
        Assert.NotNull(result.AclProfile.AllowedFullControlSids);
        Assert.True(result.AclProfile.DenyRuleCount >= 0);
    }

    [Theory]
    [InlineData(FileSystemRights.Read)]
    [InlineData(FileSystemRights.ReadAndExecute)]
    public void Treats_read_only_rights_as_not_writable(FileSystemRights rights)
    {
        Assert.False(OwnershipPathProbe.IncludesWritableRights(rights));
    }

    [Theory]
    [InlineData(FileSystemRights.WriteData)]
    [InlineData(FileSystemRights.AppendData)]
    [InlineData(FileSystemRights.WriteExtendedAttributes)]
    [InlineData(FileSystemRights.WriteAttributes)]
    [InlineData(FileSystemRights.Delete)]
    [InlineData(FileSystemRights.DeleteSubdirectoriesAndFiles)]
    [InlineData(FileSystemRights.ChangePermissions)]
    [InlineData(FileSystemRights.TakeOwnership)]
    public void Treats_atomic_write_rights_as_writable(FileSystemRights rights)
    {
        Assert.True(OwnershipPathProbe.IncludesWritableRights(rights));
    }

    public void Dispose()
    {
        if (Directory.Exists(_root))
        {
            Directory.Delete(_root, recursive: true);
        }
    }
}
