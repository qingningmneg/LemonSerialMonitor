using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Lemon.UninstallHelper.Completion;

public enum CompletionStatus
{
    Completed,
    PendingReboot,
    Failed,
}

public sealed record CompletionPayload(
    string InstallId,
    string ManifestSha256,
    string Status,
    string CreatedUtc);

public sealed record CompletionIntegrity(
    string Algorithm,
    string KeyId,
    string PayloadSha256,
    string Tag);

public sealed record CompletionToken(
    CompletionIntegrity Integrity,
    CompletionPayload Payload,
    int SchemaVersion);

public sealed record ProtectedCompletionKey(
    string Algorithm,
    string KeyId,
    string ProtectedBlob,
    string ProtectedBlobSha256,
    int SchemaVersion);

public static class CompletionTokenCodec
{
    private const string UtcFormat = "yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'";
    private static readonly Regex LowerSha256Pattern = new(
        "^[0-9a-f]{64}$",
        RegexOptions.CultureInvariant);

    public static CompletionToken Create(
        Guid installId,
        string manifestSha256,
        CompletionStatus status,
        DateTimeOffset createdUtc,
        byte[] key)
    {
        ValidateKey(key);
        ValidateLowerSha256(manifestSha256, nameof(manifestSha256));
        if (createdUtc.Offset != TimeSpan.Zero)
        {
            throw new ArgumentException("Completion UTC must have a zero offset.", nameof(createdUtc));
        }

        var payload = new CompletionPayload(
            installId.ToString("D").ToLowerInvariant(),
            manifestSha256,
            status.ToString(),
            createdUtc.ToUniversalTime().ToString(UtcFormat, CultureInfo.InvariantCulture));
        byte[] bytes = GetAuthenticationBytes(payload);
        string keyId = Sha256(key);
        return new CompletionToken(
            new CompletionIntegrity(
                "HMAC-SHA256",
                keyId,
                Sha256(bytes),
                HmacSha256(key, bytes)),
            payload,
            1);
    }

    public static CompletionPayload Validate(
        CompletionToken token,
        Guid expectedInstallId,
        string expectedManifestSha256,
        byte[] key)
    {
        ArgumentNullException.ThrowIfNull(token);
        try
        {
            ValidateKey(key);
            ValidateLowerSha256(expectedManifestSha256, nameof(expectedManifestSha256));
            ValidatePayload(token.Payload);
            if (token.SchemaVersion != 1 ||
                !string.Equals(token.Integrity.Algorithm, "HMAC-SHA256", StringComparison.Ordinal))
            {
                throw new CryptographicException("Completion token schema is invalid.");
            }

            ValidateLowerSha256(token.Integrity.KeyId, "token keyId");
            ValidateLowerSha256(token.Integrity.PayloadSha256, "token payload hash");
            ValidateLowerSha256(token.Integrity.Tag, "token tag");
            byte[] bytes = GetAuthenticationBytes(token.Payload);
            if (!FixedTimeHexEquals(token.Integrity.KeyId, Sha256(key)) ||
                !FixedTimeHexEquals(token.Integrity.PayloadSha256, Sha256(bytes)) ||
                !FixedTimeHexEquals(token.Integrity.Tag, HmacSha256(key, bytes)) ||
                !string.Equals(
                    token.Payload.InstallId,
                    expectedInstallId.ToString("D").ToLowerInvariant(),
                    StringComparison.Ordinal) ||
                !FixedTimeHexEquals(
                    token.Payload.ManifestSha256,
                    expectedManifestSha256))
            {
                throw new CryptographicException(
                    "Completion token authentication or expected binding failed.");
            }

            return token.Payload;
        }
        catch (CryptographicException)
        {
            throw;
        }
        catch (Exception exception) when (
            exception is ArgumentException or FormatException or OverflowException)
        {
            throw new CryptographicException("Completion token validation failed.", exception);
        }
    }

    public static CompletionPayload ParseAndValidate(
        byte[] stateFileBytes,
        Guid expectedInstallId,
        string expectedManifestSha256,
        byte[] key)
    {
        ArgumentNullException.ThrowIfNull(stateFileBytes);
        try
        {
            ValidateStateFileFraming(stateFileBytes);
            using JsonDocument document = JsonDocument.Parse(
                stateFileBytes.AsMemory(0, stateFileBytes.Length - 1),
                new JsonDocumentOptions
                {
                    AllowTrailingCommas = false,
                    CommentHandling = JsonCommentHandling.Disallow,
                    MaxDepth = 8,
                });
            CompletionToken token = ReadToken(document.RootElement);
            CompletionPayload payload = Validate(
                token,
                expectedInstallId,
                expectedManifestSha256,
                key);
            if (!stateFileBytes.AsSpan().SequenceEqual(GetStateFileBytes(token)))
            {
                throw new CryptographicException(
                    "Completion state bytes are not canonical.");
            }

            return payload;
        }
        catch (CryptographicException)
        {
            throw;
        }
        catch (Exception exception) when (
            exception is ArgumentException or FormatException or
                InvalidDataException or JsonException or OverflowException)
        {
            throw new CryptographicException(
                "Completion state validation failed.",
                exception);
        }
    }

    public static byte[] GetAuthenticationBytes(CompletionPayload payload)
    {
        ArgumentNullException.ThrowIfNull(payload);
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream, new JsonWriterOptions
        {
            Indented = false,
            SkipValidation = false,
        }))
        {
            writer.WriteStartObject();
            writer.WriteString("installId", payload.InstallId);
            writer.WriteString("manifestSha256", payload.ManifestSha256);
            writer.WriteString("status", payload.Status);
            writer.WriteString("createdUtc", payload.CreatedUtc);
            writer.WriteEndObject();
        }

        return stream.ToArray();
    }

    public static byte[] GetStateFileBytes(CompletionToken token)
    {
        ArgumentNullException.ThrowIfNull(token);
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream, new JsonWriterOptions
        {
            Indented = false,
            SkipValidation = false,
        }))
        {
            writer.WriteStartObject();
            writer.WritePropertyName("integrity");
            writer.WriteStartObject();
            writer.WriteString("algorithm", token.Integrity.Algorithm);
            writer.WriteString("keyId", token.Integrity.KeyId);
            writer.WriteString("payloadSha256", token.Integrity.PayloadSha256);
            writer.WriteString("tag", token.Integrity.Tag);
            writer.WriteEndObject();
            writer.WritePropertyName("payload");
            writer.WriteRawValue(GetAuthenticationBytes(token.Payload), skipInputValidation: false);
            writer.WriteNumber("schemaVersion", token.SchemaVersion);
            writer.WriteEndObject();
        }

        stream.WriteByte((byte)'\n');
        return stream.ToArray();
    }

    private static void ValidatePayload(CompletionPayload payload)
    {
        ArgumentNullException.ThrowIfNull(payload);
        Guid installId = Guid.Empty;
        if (!Guid.TryParseExact(payload.InstallId, "D", out installId) ||
            !string.Equals(
                payload.InstallId,
                installId.ToString("D").ToLowerInvariant(),
                StringComparison.Ordinal))
        {
            throw new CryptographicException("Completion installId is not canonical.");
        }

        ValidateLowerSha256(payload.ManifestSha256, "completion manifest hash");
        if (payload.Status is not ("Completed" or "PendingReboot" or "Failed"))
        {
            throw new CryptographicException("Completion status is unsupported.");
        }

        DateTimeOffset parsed = DateTimeOffset.MinValue;
        if (!DateTimeOffset.TryParseExact(
                payload.CreatedUtc,
                UtcFormat,
                CultureInfo.InvariantCulture,
                DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal,
                out parsed) ||
            !string.Equals(
                payload.CreatedUtc,
                parsed.ToUniversalTime().ToString(UtcFormat, CultureInfo.InvariantCulture),
                StringComparison.Ordinal))
        {
            throw new CryptographicException("Completion createdUtc is not canonical UTC.");
        }
    }

    private static CompletionToken ReadToken(JsonElement root)
    {
        RequireExactProperties(root, "integrity", "payload", "schemaVersion");
        JsonElement integrityElement = root.GetProperty("integrity");
        RequireExactProperties(
            integrityElement,
            "algorithm",
            "keyId",
            "payloadSha256",
            "tag");
        JsonElement payloadElement = root.GetProperty("payload");
        RequireExactProperties(
            payloadElement,
            "installId",
            "manifestSha256",
            "status",
            "createdUtc");
        return new CompletionToken(
            new CompletionIntegrity(
                ReadString(integrityElement, "algorithm"),
                ReadString(integrityElement, "keyId"),
                ReadString(integrityElement, "payloadSha256"),
                ReadString(integrityElement, "tag")),
            new CompletionPayload(
                ReadString(payloadElement, "installId"),
                ReadString(payloadElement, "manifestSha256"),
                ReadString(payloadElement, "status"),
                ReadString(payloadElement, "createdUtc")),
            ReadInt32(root, "schemaVersion"));
    }

    private static void RequireExactProperties(
        JsonElement element,
        params string[] expectedNames)
    {
        if (element.ValueKind != JsonValueKind.Object)
        {
            throw new InvalidDataException("Completion JSON value must be an object.");
        }

        var expected = new HashSet<string>(expectedNames, StringComparer.Ordinal);
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (JsonProperty property in element.EnumerateObject())
        {
            if (!expected.Contains(property.Name) || !seen.Add(property.Name))
            {
                throw new InvalidDataException(
                    "Completion JSON fields are unknown, duplicated, or mis-cased.");
            }
        }

        if (seen.Count != expected.Count)
        {
            throw new InvalidDataException("Completion JSON is missing a required field.");
        }
    }

    private static string ReadString(JsonElement element, string name)
    {
        JsonElement value = element.GetProperty(name);
        if (value.ValueKind != JsonValueKind.String)
        {
            throw new InvalidDataException($"Completion {name} must be a string.");
        }

        return value.GetString() ??
            throw new InvalidDataException($"Completion {name} cannot be null.");
    }

    private static int ReadInt32(JsonElement element, string name)
    {
        JsonElement value = element.GetProperty(name);
        if (value.ValueKind != JsonValueKind.Number ||
            !value.TryGetInt32(out int result) ||
            !string.Equals(
                value.GetRawText(),
                result.ToString(CultureInfo.InvariantCulture),
                StringComparison.Ordinal))
        {
            throw new InvalidDataException($"Completion {name} must be a raw JSON Int32.");
        }

        return result;
    }

    private static void ValidateStateFileFraming(byte[] bytes)
    {
        if (bytes.Length < 3 || bytes[^1] != (byte)'\n' ||
            bytes[^2] == (byte)'\n' || bytes.Contains((byte)'\r') ||
            bytes.AsSpan().StartsWith(new byte[] { 0xEF, 0xBB, 0xBF }))
        {
            throw new CryptographicException(
                "Completion state must be UTF-8 without BOM and have one final LF.");
        }
    }

    private static void ValidateKey(byte[] key)
    {
        ArgumentNullException.ThrowIfNull(key);
        if (key.Length != 32)
        {
            throw new ArgumentException("Completion key must contain exactly 256 bits.", nameof(key));
        }
    }

    private static void ValidateLowerSha256(string value, string parameterName)
    {
        if (value is null || !LowerSha256Pattern.IsMatch(value))
        {
            throw new ArgumentException(
                "Value must be a lowercase SHA-256 string.",
                parameterName);
        }
    }

    private static string Sha256(byte[] bytes) =>
        Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();

    private static string HmacSha256(byte[] key, byte[] bytes) =>
        Convert.ToHexString(HMACSHA256.HashData(key, bytes)).ToLowerInvariant();

    private static bool FixedTimeHexEquals(string left, string right)
    {
        try
        {
            return CryptographicOperations.FixedTimeEquals(
                Convert.FromHexString(left),
                Convert.FromHexString(right));
        }
        catch (FormatException)
        {
            return false;
        }
    }
}

public static class CompletionKeyProtection
{
    private static readonly byte[] Entropy =
        Encoding.UTF8.GetBytes("Lemon.UninstallHelper.CompletionKey.v1");

    public static ProtectedCompletionKey Protect(byte[] key)
    {
        ArgumentNullException.ThrowIfNull(key);
        if (key.Length != 32)
        {
            throw new ArgumentException(
                "Completion key must contain exactly 256 bits.",
                nameof(key));
        }

        byte[] protectedBytes = ProtectedData.Protect(
            key,
            Entropy,
            DataProtectionScope.LocalMachine);
        return new ProtectedCompletionKey(
            "DPAPI-LocalMachine",
            Sha256(key),
            Convert.ToBase64String(protectedBytes),
            Sha256(protectedBytes),
            1);
    }

    public static byte[] Unprotect(ProtectedCompletionKey record)
    {
        ArgumentNullException.ThrowIfNull(record);
        try
        {
            if (record.SchemaVersion != 1 ||
                !string.Equals(
                    record.Algorithm,
                    "DPAPI-LocalMachine",
                    StringComparison.Ordinal) ||
                !IsLowerSha256(record.KeyId) ||
                !IsLowerSha256(record.ProtectedBlobSha256))
            {
                throw new CryptographicException("Protected completion key schema is invalid.");
            }

            byte[] protectedBytes = Convert.FromBase64String(record.ProtectedBlob);
            if (!FixedTimeHexEquals(record.ProtectedBlobSha256, Sha256(protectedBytes)))
            {
                throw new CryptographicException("Protected completion key blob hash failed.");
            }

            byte[] key = ProtectedData.Unprotect(
                protectedBytes,
                Entropy,
                DataProtectionScope.LocalMachine);
            if (key.Length != 32 || !FixedTimeHexEquals(record.KeyId, Sha256(key)))
            {
                CryptographicOperations.ZeroMemory(key);
                throw new CryptographicException("Protected completion key identity failed.");
            }

            return key;
        }
        catch (CryptographicException)
        {
            throw;
        }
        catch (Exception exception) when (
            exception is ArgumentException or FormatException)
        {
            throw new CryptographicException("Protected completion key validation failed.", exception);
        }
    }

    private static bool IsLowerSha256(string value) =>
        value is not null && value.Length == 64 &&
        value.All(character => character is >= '0' and <= '9' or >= 'a' and <= 'f');

    private static string Sha256(byte[] bytes) =>
        Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();

    private static bool FixedTimeHexEquals(string left, string right)
    {
        try
        {
            return CryptographicOperations.FixedTimeEquals(
                Convert.FromHexString(left),
                Convert.FromHexString(right));
        }
        catch (FormatException)
        {
            return false;
        }
    }
}
