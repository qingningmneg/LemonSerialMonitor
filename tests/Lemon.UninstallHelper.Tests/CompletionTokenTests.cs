using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using Lemon.UninstallHelper.Completion;

namespace Lemon.UninstallHelper.Tests;

public sealed class CompletionTokenTests
{
    private static readonly Guid InstallId =
        Guid.Parse("11111111-1111-1111-1111-111111111111");
    private static readonly string ManifestHash = new('a', 64);
    private static readonly DateTimeOffset CreatedUtc =
        DateTimeOffset.ParseExact(
            "2026-07-14T03:04:05.0000000Z",
            "yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'",
            CultureInfo.InvariantCulture,
            DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal);

    [Fact]
    public void Creates_and_validates_an_exact_authenticated_completion_token()
    {
        byte[] key = Enumerable.Range(0, 32).Select(value => (byte)value).ToArray();

        CompletionToken token = CompletionTokenCodec.Create(
            InstallId,
            ManifestHash,
            CompletionStatus.Completed,
            CreatedUtc,
            key);
        CompletionPayload payload = CompletionTokenCodec.Validate(
            token,
            InstallId,
            ManifestHash,
            key);

        Assert.Equal(1, token.SchemaVersion);
        Assert.Equal("HMAC-SHA256", token.Integrity.Algorithm);
        Assert.Equal(InstallId.ToString("D"), payload.InstallId);
        Assert.Equal(ManifestHash, payload.ManifestSha256);
        Assert.Equal("Completed", payload.Status);
        Assert.Equal("2026-07-14T03:04:05.0000000Z", payload.CreatedUtc);
    }

    [Fact]
    public void Authentication_and_state_file_bytes_have_exact_line_endings()
    {
        byte[] key = Enumerable.Range(0, 32).Select(value => (byte)value).ToArray();
        CompletionToken token = CompletionTokenCodec.Create(
            InstallId,
            ManifestHash,
            CompletionStatus.Completed,
            CreatedUtc,
            key);

        byte[] authentication = CompletionTokenCodec.GetAuthenticationBytes(token.Payload);
        byte[] stateFile = CompletionTokenCodec.GetStateFileBytes(token);

        Assert.NotEqual((byte)'\n', authentication[^1]);
        Assert.Equal((byte)'\n', stateFile[^1]);
        Assert.NotEqual((byte)'\n', stateFile[^2]);
        Assert.DoesNotContain((byte)'\r', stateFile);
    }

    [Fact]
    public void Strictly_parses_and_validates_exact_completion_state_bytes()
    {
        byte[] key = Enumerable.Range(0, 32).Select(value => (byte)value).ToArray();
        CompletionToken token = CompletionTokenCodec.Create(
            InstallId,
            ManifestHash,
            CompletionStatus.Completed,
            CreatedUtc,
            key);
        byte[] bytes = CompletionTokenCodec.GetStateFileBytes(token);

        CompletionPayload payload = CompletionTokenCodec.ParseAndValidate(
            bytes,
            InstallId,
            ManifestHash,
            key);

        Assert.Equal("Completed", payload.Status);
    }

    [Theory]
    [InlineData("duplicate")]
    [InlineData("case")]
    [InlineData("unknown")]
    [InlineData("carriage-return")]
    [InlineData("no-final-lf")]
    public void Strict_state_parser_rejects_noncanonical_or_ambiguous_JSON(string scenario)
    {
        byte[] key = Enumerable.Range(0, 32).Select(value => (byte)value).ToArray();
        CompletionToken token = CompletionTokenCodec.Create(
            InstallId,
            ManifestHash,
            CompletionStatus.Completed,
            CreatedUtc,
            key);
        string json = Encoding.UTF8.GetString(CompletionTokenCodec.GetStateFileBytes(token));
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
            "no-final-lf" => json.TrimEnd('\n'),
            _ => throw new InvalidOperationException(),
        };

        Assert.Throws<CryptographicException>(() =>
            CompletionTokenCodec.ParseAndValidate(
                Encoding.UTF8.GetBytes(json),
                InstallId,
                ManifestHash,
                key));
    }

    [Theory]
    [InlineData("install")]
    [InlineData("manifest")]
    [InlineData("status")]
    [InlineData("created")]
    [InlineData("payload-hash")]
    [InlineData("tag")]
    public void Rejects_any_completion_token_tampering(string field)
    {
        byte[] key = Enumerable.Range(0, 32).Select(value => (byte)value).ToArray();
        CompletionToken original = CompletionTokenCodec.Create(
            InstallId,
            ManifestHash,
            CompletionStatus.Completed,
            CreatedUtc,
            key);
        CompletionToken token = field switch
        {
            "install" => original with
            {
                Payload = original.Payload with
                {
                    InstallId = "22222222-2222-2222-2222-222222222222",
                },
            },
            "manifest" => original with
            {
                Payload = original.Payload with { ManifestSha256 = new string('b', 64) },
            },
            "status" => original with
            {
                Payload = original.Payload with { Status = "Failed" },
            },
            "created" => original with
            {
                Payload = original.Payload with
                {
                    CreatedUtc = "2026-07-14T03:04:06.0000000Z",
                },
            },
            "payload-hash" => original with
            {
                Integrity = original.Integrity with { PayloadSha256 = new string('0', 64) },
            },
            "tag" => original with
            {
                Integrity = original.Integrity with { Tag = new string('0', 64) },
            },
            _ => throw new InvalidOperationException(),
        };

        Assert.Throws<CryptographicException>(() =>
            CompletionTokenCodec.Validate(token, InstallId, ManifestHash, key));
    }

    [Fact]
    public void Rejects_a_valid_token_for_another_install_or_manifest()
    {
        byte[] key = Enumerable.Range(0, 32).Select(value => (byte)value).ToArray();
        CompletionToken token = CompletionTokenCodec.Create(
            InstallId,
            ManifestHash,
            CompletionStatus.Completed,
            CreatedUtc,
            key);

        Assert.Throws<CryptographicException>(() => CompletionTokenCodec.Validate(
            token,
            Guid.Parse("22222222-2222-2222-2222-222222222222"),
            ManifestHash,
            key));
        Assert.Throws<CryptographicException>(() => CompletionTokenCodec.Validate(
            token,
            InstallId,
            new string('b', 64),
            key));
    }

    [Fact]
    public void Rejects_a_token_authenticated_by_another_key()
    {
        byte[] key = Enumerable.Range(0, 32).Select(value => (byte)value).ToArray();
        byte[] otherKey = Enumerable.Range(32, 32).Select(value => (byte)value).ToArray();
        CompletionToken token = CompletionTokenCodec.Create(
            InstallId,
            ManifestHash,
            CompletionStatus.Completed,
            CreatedUtc,
            key);

        Assert.Throws<CryptographicException>(() => CompletionTokenCodec.Validate(
            token,
            InstallId,
            ManifestHash,
            otherKey));
    }

    [Fact]
    public void DPAPI_LocalMachine_record_round_trips_without_serializing_plaintext_key()
    {
        byte[] key = Enumerable.Range(0, 32).Select(value => (byte)value).ToArray();

        ProtectedCompletionKey record = CompletionKeyProtection.Protect(key);
        byte[] unprotected = CompletionKeyProtection.Unprotect(record);

        Assert.Equal(1, record.SchemaVersion);
        Assert.Equal("DPAPI-LocalMachine", record.Algorithm);
        Assert.Equal(key, unprotected);
        Assert.DoesNotContain(Convert.ToBase64String(key), record.ProtectedBlob);
        Assert.Equal(
            Convert.ToHexString(SHA256.HashData(key)).ToLowerInvariant(),
            record.KeyId);
    }

    [Theory]
    [InlineData("key-id")]
    [InlineData("blob")]
    [InlineData("blob-hash")]
    public void Rejects_tampered_DPAPI_key_records(string field)
    {
        byte[] key = Enumerable.Range(0, 32).Select(value => (byte)value).ToArray();
        ProtectedCompletionKey original = CompletionKeyProtection.Protect(key);
        ProtectedCompletionKey record = field switch
        {
            "key-id" => original with { KeyId = new string('0', 64) },
            "blob" => original with { ProtectedBlob = "AA==" },
            "blob-hash" => original with { ProtectedBlobSha256 = new string('0', 64) },
            _ => throw new InvalidOperationException(),
        };

        Assert.Throws<CryptographicException>(() =>
            CompletionKeyProtection.Unprotect(record));
    }

    [Fact]
    public void Rejects_non_256_bit_keys_and_noncanonical_manifest_hashes()
    {
        Assert.Throws<ArgumentException>(() => CompletionTokenCodec.Create(
            InstallId,
            ManifestHash,
            CompletionStatus.Completed,
            CreatedUtc,
            new byte[31]));
        Assert.Throws<ArgumentException>(() => CompletionTokenCodec.Create(
            InstallId,
            ManifestHash.ToUpperInvariant(),
            CompletionStatus.Completed,
            CreatedUtc,
            new byte[32]));
        Assert.Throws<ArgumentException>(() => CompletionKeyProtection.Protect(new byte[31]));
    }
}
