using Lemon.UninstallHelper.Manifest;

namespace Lemon.UninstallHelper.Tests;

public sealed class UninstallWorkBuilderTests : IDisposable
{
    private readonly string _root = Path.Combine(
        Path.GetTempPath(),
        "LemonUninstallWorkBuilderTests",
        Guid.NewGuid().ToString("N"));

    public UninstallWorkBuilderTests()
    {
        Directory.CreateDirectory(Path.Combine(_root, "nested"));
        File.WriteAllText(Path.Combine(_root, "Lemon.SerialMonitor.exe"), "binary");
        File.WriteAllText(Path.Combine(_root, "nested", "配置.json"), "{}");
    }

    [Fact]
    public void Builds_a_canonical_authenticated_work_manifest_from_one_owned_root()
    {
        string installId = "11111111-1111-1111-1111-111111111111";
        string ownershipSha256 = new string('a', 64);

        byte[] bytes = UninstallWorkBuilder.Build(
            installId,
            ownershipSha256,
            _root,
            aiStateRoot: null);

        using ValidatedUninstallWork validated =
            UninstallWorkManifestCodec.ParseAndValidate(bytes);
        Assert.Equal(installId, validated.Payload.InstallId);
        Assert.Equal(ownershipSha256, validated.Payload.OwnershipManifestSha256);
        ApprovedRootManifest root = Assert.Single(validated.Payload.Roots);
        Assert.Equal(ApprovedRootRole.AppRoot, root.Role);
        Assert.Contains(root.Objects, item =>
            item.Kind == OwnedObjectKind.Directory && item.RelativePath == "nested");
        Assert.Contains(root.Objects, item =>
            item.Kind == OwnedObjectKind.ImmutableFile &&
            item.RelativePath == "nested\\配置.json" &&
            item.ProductMarker == "CommMonitor:0.1.0");
    }

    [Fact]
    public void Omits_an_absent_optional_root_but_requires_at_least_one_root()
    {
        byte[] bytes = UninstallWorkBuilder.Build(
            "11111111-1111-1111-1111-111111111111",
            new string('b', 64),
            appRoot: null,
            aiStateRoot: _root);

        using ValidatedUninstallWork validated =
            UninstallWorkManifestCodec.ParseAndValidate(bytes);
        Assert.Equal(
            ApprovedRootRole.AiStateRoot,
            Assert.Single(validated.Payload.Roots).Role);

        Assert.Throws<ArgumentException>(() => UninstallWorkBuilder.Build(
            "11111111-1111-1111-1111-111111111111",
            new string('b', 64),
            appRoot: null,
            aiStateRoot: null));
    }

    public void Dispose()
    {
        if (Directory.Exists(_root))
        {
            Directory.Delete(_root, recursive: true);
        }
    }
}
