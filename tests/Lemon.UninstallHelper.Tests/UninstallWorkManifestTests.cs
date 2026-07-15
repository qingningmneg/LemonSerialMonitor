using System.Security.Cryptography;
using System.Text;
using Lemon.UninstallHelper.Completion;
using Lemon.UninstallHelper.Manifest;
using Lemon.UninstallHelper.Security;

namespace Lemon.UninstallHelper.Tests;

public sealed class UninstallWorkManifestTests
{
    [Fact]
    public void Round_trips_an_exact_authenticated_multi_root_work_manifest()
    {
        using var sandbox = new ManifestSandbox();
        byte[] key = Enumerable.Range(0, 32).Select(value => (byte)value).ToArray();
        ProtectedCompletionKey protectedKey = CompletionKeyProtection.Protect(key);
        UninstallWorkPayload payload = sandbox.Payload(protectedKey);

        UninstallWorkEnvelope envelope = UninstallWorkManifestCodec.Create(payload, key);
        byte[] bytes = UninstallWorkManifestCodec.GetStateFileBytes(envelope);
        using ValidatedUninstallWork validated =
            UninstallWorkManifestCodec.ParseAndValidate(bytes);

        Assert.Equal(1, envelope.SchemaVersion);
        Assert.Equal("HMAC-SHA256", envelope.Integrity.Algorithm);
        Assert.Equal(payload.InstallId, validated.Payload.InstallId);
        Assert.Equal(2, validated.Payload.Roots.Count);
        Assert.Equal(ApprovedRootRole.AppRoot, validated.Payload.Roots[0].Role);
        Assert.Equal(ApprovedRootRole.AiStateRoot, validated.Payload.Roots[1].Role);
        Assert.Equal(key, validated.Key);
        Assert.Equal((byte)'\n', bytes[^1]);
        Assert.DoesNotContain(Convert.ToBase64String(key), Encoding.UTF8.GetString(bytes));
    }

    [Theory]
    [InlineData("payload")]
    [InlineData("tag")]
    [InlineData("key")]
    public void Rejects_authenticated_work_manifest_tampering(string field)
    {
        using var sandbox = new ManifestSandbox();
        byte[] key = Enumerable.Range(0, 32).Select(value => (byte)value).ToArray();
        ProtectedCompletionKey protectedKey = CompletionKeyProtection.Protect(key);
        UninstallWorkEnvelope envelope = UninstallWorkManifestCodec.Create(
            sandbox.Payload(protectedKey),
            key);
        byte[] bytes = UninstallWorkManifestCodec.GetStateFileBytes(envelope);
        string json = Encoding.UTF8.GetString(bytes);
        json = field switch
        {
            "payload" => json.Replace(
                new string('a', 64),
                new string('b', 64),
                StringComparison.Ordinal),
            "tag" => json.Replace(
                envelope.Integrity.Tag,
                new string('0', 64),
                StringComparison.Ordinal),
            "key" => json.Replace(
                protectedKey.KeyId,
                new string('0', 64),
                StringComparison.Ordinal),
            _ => throw new InvalidOperationException(),
        };

        Assert.Throws<CryptographicException>(() =>
            UninstallWorkManifestCodec.ParseAndValidate(Encoding.UTF8.GetBytes(json)));
    }

    [Theory]
    [InlineData("duplicate")]
    [InlineData("case")]
    [InlineData("unknown")]
    [InlineData("carriage-return")]
    public void Rejects_noncanonical_or_ambiguous_work_JSON(string scenario)
    {
        using var sandbox = new ManifestSandbox();
        byte[] key = Enumerable.Range(0, 32).Select(value => (byte)value).ToArray();
        UninstallWorkEnvelope envelope = UninstallWorkManifestCodec.Create(
            sandbox.Payload(CompletionKeyProtection.Protect(key)),
            key);
        string json = Encoding.UTF8.GetString(
            UninstallWorkManifestCodec.GetStateFileBytes(envelope));
        json = scenario switch
        {
            "duplicate" => json.Replace(
                "\"schemaVersion\":1}",
                "\"schemaVersion\":1,\"schemaVersion\":1}",
                StringComparison.Ordinal),
            "case" => json.Replace("\"payload\":", "\"Payload\":", StringComparison.Ordinal),
            "unknown" => json.Replace(
                "\"schemaVersion\":1}",
                "\"schemaVersion\":1,\"unexpected\":false}",
                StringComparison.Ordinal),
            "carriage-return" => json.Replace("\n", "\r\n", StringComparison.Ordinal),
            _ => throw new InvalidOperationException(),
        };

        Assert.ThrowsAny<Exception>(() =>
            UninstallWorkManifestCodec.ParseAndValidate(Encoding.UTF8.GetBytes(json)));
    }

    [Fact]
    public void Rejects_duplicate_root_roles_and_root_paths()
    {
        using var sandbox = new ManifestSandbox();
        byte[] key = Enumerable.Range(0, 32).Select(value => (byte)value).ToArray();
        ProtectedCompletionKey protectedKey = CompletionKeyProtection.Protect(key);
        UninstallWorkPayload original = sandbox.Payload(protectedKey);
        UninstallWorkPayload duplicateRole = original with
        {
            Roots = [original.Roots[0], original.Roots[1] with { Role = ApprovedRootRole.AppRoot }],
        };
        UninstallWorkPayload duplicatePath = original with
        {
            Roots = [original.Roots[0], original.Roots[1] with
            {
                CanonicalPath = original.Roots[0].CanonicalPath,
            }],
        };

        Assert.Throws<ArgumentException>(() =>
            UninstallWorkManifestCodec.Create(duplicateRole, key));
        Assert.Throws<ArgumentException>(() =>
            UninstallWorkManifestCodec.Create(duplicatePath, key));
    }

    [Fact]
    public void Rejects_a_completion_key_record_not_matching_the_signing_key()
    {
        using var sandbox = new ManifestSandbox();
        byte[] key = Enumerable.Range(0, 32).Select(value => (byte)value).ToArray();
        byte[] other = Enumerable.Range(32, 32).Select(value => (byte)value).ToArray();

        Assert.Throws<CryptographicException>(() =>
            UninstallWorkManifestCodec.Create(
                sandbox.Payload(CompletionKeyProtection.Protect(key)),
                other));
    }

    private sealed class ManifestSandbox : IDisposable
    {
        public ManifestSandbox()
        {
            BasePath = Path.Combine(
                Path.GetTempPath(),
                $"lemon-work-manifest-{Guid.NewGuid():N}");
            AppRoot = Path.Combine(BasePath, "app");
            AiRoot = Path.Combine(BasePath, "ai");
            Directory.CreateDirectory(AppRoot);
            Directory.CreateDirectory(AiRoot);
            File.WriteAllBytes(Path.Combine(AppRoot, "app.exe"), [0x01]);
            File.WriteAllText(Path.Combine(AiRoot, "leases.json"), "{}");
        }

        public string BasePath { get; }
        public string AppRoot { get; }
        public string AiRoot { get; }

        public UninstallWorkPayload Payload(ProtectedCompletionKey protectedKey)
        {
            PathIdentitySnapshot appIdentity = PathIdentity.Capture(AppRoot);
            PathIdentitySnapshot aiIdentity = PathIdentity.Capture(AiRoot);
            string appFile = Path.Combine(AppRoot, "app.exe");
            string leaseFile = Path.Combine(AiRoot, "leases.json");
            PathIdentitySnapshot leaseIdentity = PathIdentity.Capture(leaseFile);
            var app = new ApprovedRootManifest(
                AppRoot,
                appIdentity.VolumeSerialNumber,
                appIdentity.FileId,
                [OwnedObject.ImmutableFile(
                    "app-exe",
                    "app.exe",
                    1,
                    Sha256(appFile),
                    "CommMonitor:0.1.0")],
                ApprovedRootRole.AppRoot);
            var ai = new ApprovedRootManifest(
                AiRoot,
                aiIdentity.VolumeSerialNumber,
                aiIdentity.FileId,
                [OwnedObject.DynamicFile(
                    "leases",
                    "leases.json",
                    leaseIdentity.VolumeSerialNumber,
                    leaseIdentity.FileId)],
                ApprovedRootRole.AiStateRoot);
            return new UninstallWorkPayload(
                "11111111-1111-1111-1111-111111111111",
                new string('a', 64),
                protectedKey,
                [app, ai]);
        }

        public void Dispose()
        {
            if (Directory.Exists(BasePath))
            {
                Directory.Delete(BasePath, recursive: true);
            }
        }

        private static string Sha256(string path) =>
            Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(path))).ToLowerInvariant();
    }
}
