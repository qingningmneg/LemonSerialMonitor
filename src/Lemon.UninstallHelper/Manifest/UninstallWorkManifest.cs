using System.Globalization;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.RegularExpressions;
using Lemon.UninstallHelper.Completion;
using Lemon.UninstallHelper.Security;

namespace Lemon.UninstallHelper.Manifest;

public sealed record UninstallWorkPayload(
    string InstallId,
    string OwnershipManifestSha256,
    ProtectedCompletionKey CompletionKey,
    IReadOnlyList<ApprovedRootManifest> Roots);

public sealed record UninstallWorkIntegrity(
    string Algorithm,
    string KeyId,
    string PayloadSha256,
    string Tag);

public sealed record UninstallWorkEnvelope(
    UninstallWorkIntegrity Integrity,
    UninstallWorkPayload Payload,
    int SchemaVersion);

public sealed class ValidatedUninstallWork(
    UninstallWorkPayload payload,
    byte[] key) : IDisposable
{
    private bool _disposed;

    public UninstallWorkPayload Payload { get; } = payload;
    public byte[] Key { get; } = key;

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        CryptographicOperations.ZeroMemory(Key);
        _disposed = true;
    }
}

public static class UninstallWorkManifestCodec
{
    private static readonly Regex LowerSha256Pattern = new(
        "^[0-9a-f]{64}$",
        RegexOptions.CultureInvariant);
    private static readonly Regex LowerFileIdPattern = new(
        "^[0-9a-f]{32}$",
        RegexOptions.CultureInvariant);
    private static readonly Regex ObjectIdPattern = new(
        "^[a-z0-9][a-z0-9.-]*$",
        RegexOptions.CultureInvariant);

    public static UninstallWorkEnvelope Create(UninstallWorkPayload payload, byte[] key)
    {
        ArgumentNullException.ThrowIfNull(payload);
        ValidateKey(key);
        UninstallWorkPayload canonical = CanonicalizePayload(payload);
        byte[] recordKey = CompletionKeyProtection.Unprotect(canonical.CompletionKey);
        try
        {
            if (!CryptographicOperations.FixedTimeEquals(recordKey, key))
            {
                throw new CryptographicException(
                    "The protected completion key does not match the work signing key.");
            }
        }
        finally
        {
            CryptographicOperations.ZeroMemory(recordKey);
        }

        byte[] bytes = GetAuthenticationBytes(canonical);
        return new UninstallWorkEnvelope(
            new UninstallWorkIntegrity(
                "HMAC-SHA256",
                Sha256(key),
                Sha256(bytes),
                HmacSha256(key, bytes)),
            canonical,
            1);
    }

    public static ValidatedUninstallWork ParseAndValidate(byte[] stateFileBytes)
    {
        ArgumentNullException.ThrowIfNull(stateFileBytes);
        byte[] key = [];
        try
        {
            ValidateStateFileFraming(stateFileBytes);
            using JsonDocument document = JsonDocument.Parse(
                stateFileBytes.AsMemory(0, stateFileBytes.Length - 1),
                new JsonDocumentOptions
                {
                    AllowTrailingCommas = false,
                    CommentHandling = JsonCommentHandling.Disallow,
                    MaxDepth = 32,
                });
            UninstallWorkEnvelope parsed = ReadEnvelope(document.RootElement);
            UninstallWorkPayload canonical = CanonicalizePayload(parsed.Payload);
            key = CompletionKeyProtection.Unprotect(canonical.CompletionKey);
            ValidateKey(key);
            byte[] authentication = GetAuthenticationBytes(canonical);
            if (parsed.SchemaVersion != 1 ||
                !string.Equals(
                    parsed.Integrity.Algorithm,
                    "HMAC-SHA256",
                    StringComparison.Ordinal) ||
                !IsLowerSha256(parsed.Integrity.KeyId) ||
                !IsLowerSha256(parsed.Integrity.PayloadSha256) ||
                !IsLowerSha256(parsed.Integrity.Tag) ||
                !FixedTimeHexEquals(parsed.Integrity.KeyId, Sha256(key)) ||
                !FixedTimeHexEquals(
                    parsed.Integrity.PayloadSha256,
                    Sha256(authentication)) ||
                !FixedTimeHexEquals(
                    parsed.Integrity.Tag,
                    HmacSha256(key, authentication)))
            {
                throw new CryptographicException(
                    "Uninstall work manifest authentication failed.");
            }

            var normalized = new UninstallWorkEnvelope(
                parsed.Integrity,
                canonical,
                1);
            if (!stateFileBytes.AsSpan().SequenceEqual(GetStateFileBytes(normalized)))
            {
                throw new CryptographicException(
                    "Uninstall work manifest bytes are not canonical.");
            }

            var validated = new ValidatedUninstallWork(canonical, key);
            key = [];
            return validated;
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
                "Uninstall work manifest validation failed.",
                exception);
        }
        finally
        {
            if (key.Length != 0)
            {
                CryptographicOperations.ZeroMemory(key);
            }
        }
    }

    public static byte[] GetAuthenticationBytes(UninstallWorkPayload payload)
    {
        ArgumentNullException.ThrowIfNull(payload);
        using var stream = new MemoryStream();
        using (var writer = NewWriter(stream))
        {
            WritePayload(writer, payload);
        }

        return stream.ToArray();
    }

    public static byte[] GetStateFileBytes(UninstallWorkEnvelope envelope)
    {
        ArgumentNullException.ThrowIfNull(envelope);
        using var stream = new MemoryStream();
        using (var writer = NewWriter(stream))
        {
            writer.WriteStartObject();
            writer.WritePropertyName("integrity");
            writer.WriteStartObject();
            writer.WriteString("algorithm", envelope.Integrity.Algorithm);
            writer.WriteString("keyId", envelope.Integrity.KeyId);
            writer.WriteString("payloadSha256", envelope.Integrity.PayloadSha256);
            writer.WriteString("tag", envelope.Integrity.Tag);
            writer.WriteEndObject();
            writer.WritePropertyName("payload");
            WritePayload(writer, envelope.Payload);
            writer.WriteNumber("schemaVersion", envelope.SchemaVersion);
            writer.WriteEndObject();
        }

        stream.WriteByte((byte)'\n');
        return stream.ToArray();
    }

    private static UninstallWorkPayload CanonicalizePayload(UninstallWorkPayload payload)
    {
        Guid installId = Guid.Empty;
        if (!Guid.TryParseExact(payload.InstallId, "D", out installId) ||
            !string.Equals(
                payload.InstallId,
                installId.ToString("D").ToLowerInvariant(),
                StringComparison.Ordinal) ||
            !IsLowerSha256(payload.OwnershipManifestSha256) ||
            payload.CompletionKey is null || payload.Roots is null ||
            payload.Roots.Count is < 1 or > 2)
        {
            throw new ArgumentException("Uninstall work payload identity is invalid.");
        }

        ValidateProtectedKeyRecord(payload.CompletionKey);
        var roles = new HashSet<ApprovedRootRole>();
        var paths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var roots = new List<ApprovedRootManifest>(payload.Roots.Count);
        foreach (ApprovedRootManifest sourceRoot in payload.Roots)
        {
            if (sourceRoot is null || !roles.Add(sourceRoot.Role))
            {
                throw new ArgumentException("Approved root roles are invalid or duplicate.");
            }

            string path = PathIdentity.NormalizePath(sourceRoot.CanonicalPath);
            if (!Path.IsPathFullyQualified(path) ||
                path.StartsWith(@"\\", StringComparison.Ordinal) ||
                !paths.Add(path) || !LowerFileIdPattern.IsMatch(sourceRoot.FileId) ||
                sourceRoot.Objects is null)
            {
                throw new ArgumentException("Approved root identity is invalid or duplicate.");
            }

            var objectIds = new HashSet<string>(StringComparer.Ordinal);
            var objectPaths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            var objects = new List<OwnedObject>(sourceRoot.Objects.Count);
            foreach (OwnedObject item in sourceRoot.Objects)
            {
                if (item is null || !ObjectIdPattern.IsMatch(item.ObjectId) ||
                    !objectIds.Add(item.ObjectId) ||
                    string.IsNullOrWhiteSpace(item.RelativePath) ||
                    !objectPaths.Add(item.RelativePath))
                {
                    throw new ArgumentException("Owned work objects are invalid or duplicate.");
                }

                ValidateObjectUnion(item);
                objects.Add(item);
            }

            objects.Sort((left, right) =>
                StringComparer.Ordinal.Compare(left.ObjectId, right.ObjectId));
            roots.Add(new ApprovedRootManifest(
                path,
                sourceRoot.VolumeSerialNumber,
                sourceRoot.FileId,
                objects.ToArray(),
                sourceRoot.Role));
        }

        roots.Sort((left, right) => left.Role.CompareTo(right.Role));
        return new UninstallWorkPayload(
            payload.InstallId,
            payload.OwnershipManifestSha256,
            payload.CompletionKey,
            roots.ToArray());
    }

    private static void ValidateObjectUnion(OwnedObject item)
    {
        switch (item.Kind)
        {
            case OwnedObjectKind.ImmutableFile:
                if (item.Size is null or < 0 || !IsLowerSha256(item.Sha256) ||
                    string.IsNullOrWhiteSpace(item.ProductMarker) ||
                    item.VolumeSerialNumber is not null || item.FileId is not null)
                {
                    throw new ArgumentException("Immutable work object is invalid.");
                }
                break;
            case OwnedObjectKind.DynamicFile:
                if (item.Size is not null || item.Sha256 is not null ||
                    item.ProductMarker is not null ||
                    item.VolumeSerialNumber is null ||
                    !LowerFileIdPattern.IsMatch(item.FileId ?? string.Empty))
                {
                    throw new ArgumentException("Dynamic work object is invalid.");
                }
                break;
            case OwnedObjectKind.Directory:
                if (item.Size is not null || item.Sha256 is not null ||
                    item.ProductMarker is not null ||
                    item.VolumeSerialNumber is not null || item.FileId is not null)
                {
                    throw new ArgumentException("Directory work object is invalid.");
                }
                break;
            default:
                throw new ArgumentException("Owned work object kind is unsupported.");
        }
    }

    private static void ValidateProtectedKeyRecord(ProtectedCompletionKey record)
    {
        if (record.SchemaVersion != 1 ||
            !string.Equals(record.Algorithm, "DPAPI-LocalMachine", StringComparison.Ordinal) ||
            !IsLowerSha256(record.KeyId) ||
            !IsLowerSha256(record.ProtectedBlobSha256) ||
            string.IsNullOrWhiteSpace(record.ProtectedBlob))
        {
            throw new ArgumentException("Protected completion key record is invalid.");
        }
    }

    private static UninstallWorkEnvelope ReadEnvelope(JsonElement root)
    {
        RequireExactProperties(root, "integrity", "payload", "schemaVersion");
        JsonElement integrityElement = root.GetProperty("integrity");
        RequireExactProperties(
            integrityElement,
            "algorithm",
            "keyId",
            "payloadSha256",
            "tag");
        var integrity = new UninstallWorkIntegrity(
            ReadString(integrityElement, "algorithm"),
            ReadString(integrityElement, "keyId"),
            ReadString(integrityElement, "payloadSha256"),
            ReadString(integrityElement, "tag"));
        UninstallWorkPayload payload = ReadPayload(root.GetProperty("payload"));
        int schemaVersion = ReadInt32(root, "schemaVersion");
        return new UninstallWorkEnvelope(integrity, payload, schemaVersion);
    }

    private static UninstallWorkPayload ReadPayload(JsonElement element)
    {
        RequireExactProperties(
            element,
            "installId",
            "ownershipManifestSha256",
            "completionKey",
            "roots");
        JsonElement keyElement = element.GetProperty("completionKey");
        RequireExactProperties(
            keyElement,
            "algorithm",
            "keyId",
            "protectedBlob",
            "protectedBlobSha256",
            "schemaVersion");
        var key = new ProtectedCompletionKey(
            ReadString(keyElement, "algorithm"),
            ReadString(keyElement, "keyId"),
            ReadString(keyElement, "protectedBlob"),
            ReadString(keyElement, "protectedBlobSha256"),
            ReadInt32(keyElement, "schemaVersion"));
        JsonElement rootsElement = element.GetProperty("roots");
        if (rootsElement.ValueKind != JsonValueKind.Array)
        {
            throw new InvalidDataException("Work roots must be an array.");
        }

        var roots = new List<ApprovedRootManifest>();
        foreach (JsonElement root in rootsElement.EnumerateArray())
        {
            roots.Add(ReadRoot(root));
        }

        return new UninstallWorkPayload(
            ReadString(element, "installId"),
            ReadString(element, "ownershipManifestSha256"),
            key,
            roots.ToArray());
    }

    private static ApprovedRootManifest ReadRoot(JsonElement element)
    {
        RequireExactProperties(
            element,
            "role",
            "canonicalPath",
            "volumeSerialNumber",
            "fileId",
            "objects");
        string roleText = ReadString(element, "role");
        ApprovedRootRole role = roleText switch
        {
            "AppRoot" => ApprovedRootRole.AppRoot,
            "AiStateRoot" => ApprovedRootRole.AiStateRoot,
            _ => throw new InvalidDataException("Approved root role is unsupported."),
        };
        string volumeText = ReadString(element, "volumeSerialNumber");
        if (volumeText.Length != 16 || !ulong.TryParse(
                volumeText,
                NumberStyles.AllowHexSpecifier,
                CultureInfo.InvariantCulture,
                out ulong volume) ||
            !string.Equals(
                volumeText,
                volume.ToString("x16", CultureInfo.InvariantCulture),
                StringComparison.Ordinal))
        {
            throw new InvalidDataException("Approved root volume serial is invalid.");
        }

        JsonElement objectsElement = element.GetProperty("objects");
        if (objectsElement.ValueKind != JsonValueKind.Array)
        {
            throw new InvalidDataException("Root objects must be an array.");
        }

        var objects = new List<OwnedObject>();
        foreach (JsonElement item in objectsElement.EnumerateArray())
        {
            objects.Add(ReadObject(item));
        }

        return new ApprovedRootManifest(
            ReadString(element, "canonicalPath"),
            volume,
            ReadString(element, "fileId"),
            objects.ToArray(),
            role);
    }

    private static OwnedObject ReadObject(JsonElement element)
    {
        string kind = ReadString(element, "kind");
        return kind switch
        {
            "ImmutableFile" => ReadImmutableObject(element),
            "DynamicFile" => ReadDynamicObject(element),
            "Directory" => ReadDirectoryObject(element),
            _ => throw new InvalidDataException("Owned work object kind is unsupported."),
        };
    }

    private static OwnedObject ReadImmutableObject(JsonElement element)
    {
        RequireExactProperties(
            element,
            "objectId",
            "relativePath",
            "kind",
            "size",
            "sha256",
            "productMarker");
        return OwnedObject.ImmutableFile(
            ReadString(element, "objectId"),
            ReadString(element, "relativePath"),
            ReadInt64(element, "size"),
            ReadString(element, "sha256"),
            ReadString(element, "productMarker"));
    }

    private static OwnedObject ReadDynamicObject(JsonElement element)
    {
        RequireExactProperties(
            element,
            "objectId",
            "relativePath",
            "kind",
            "volumeSerialNumber",
            "fileId");
        string volumeText = ReadString(element, "volumeSerialNumber");
        if (volumeText.Length != 16 || !ulong.TryParse(
                volumeText,
                NumberStyles.AllowHexSpecifier,
                CultureInfo.InvariantCulture,
                out ulong volume))
        {
            throw new InvalidDataException("Dynamic file volume serial is invalid.");
        }

        return OwnedObject.DynamicFile(
            ReadString(element, "objectId"),
            ReadString(element, "relativePath"),
            volume,
            ReadString(element, "fileId"));
    }

    private static OwnedObject ReadDirectoryObject(JsonElement element)
    {
        RequireExactProperties(element, "objectId", "relativePath", "kind");
        return OwnedObject.Directory(
            ReadString(element, "objectId"),
            ReadString(element, "relativePath"));
    }

    private static void WritePayload(Utf8JsonWriter writer, UninstallWorkPayload payload)
    {
        writer.WriteStartObject();
        writer.WriteString("installId", payload.InstallId);
        writer.WriteString("ownershipManifestSha256", payload.OwnershipManifestSha256);
        writer.WritePropertyName("completionKey");
        WriteProtectedKey(writer, payload.CompletionKey);
        writer.WritePropertyName("roots");
        writer.WriteStartArray();
        foreach (ApprovedRootManifest root in payload.Roots)
        {
            writer.WriteStartObject();
            writer.WriteString("role", root.Role.ToString());
            writer.WriteString("canonicalPath", root.CanonicalPath);
            writer.WriteString(
                "volumeSerialNumber",
                root.VolumeSerialNumber.ToString("x16", CultureInfo.InvariantCulture));
            writer.WriteString("fileId", root.FileId);
            writer.WritePropertyName("objects");
            writer.WriteStartArray();
            foreach (OwnedObject item in root.Objects)
            {
                WriteObject(writer, item);
            }
            writer.WriteEndArray();
            writer.WriteEndObject();
        }
        writer.WriteEndArray();
        writer.WriteEndObject();
    }

    private static void WriteProtectedKey(Utf8JsonWriter writer, ProtectedCompletionKey key)
    {
        writer.WriteStartObject();
        writer.WriteString("algorithm", key.Algorithm);
        writer.WriteString("keyId", key.KeyId);
        writer.WriteString("protectedBlob", key.ProtectedBlob);
        writer.WriteString("protectedBlobSha256", key.ProtectedBlobSha256);
        writer.WriteNumber("schemaVersion", key.SchemaVersion);
        writer.WriteEndObject();
    }

    private static void WriteObject(Utf8JsonWriter writer, OwnedObject item)
    {
        writer.WriteStartObject();
        writer.WriteString("objectId", item.ObjectId);
        writer.WriteString("relativePath", item.RelativePath);
        writer.WriteString("kind", item.Kind.ToString());
        switch (item.Kind)
        {
            case OwnedObjectKind.ImmutableFile:
                writer.WriteNumber("size", item.Size!.Value);
                writer.WriteString("sha256", item.Sha256);
                writer.WriteString("productMarker", item.ProductMarker);
                break;
            case OwnedObjectKind.DynamicFile:
                writer.WriteString(
                    "volumeSerialNumber",
                    item.VolumeSerialNumber!.Value.ToString(
                        "x16",
                        CultureInfo.InvariantCulture));
                writer.WriteString("fileId", item.FileId);
                break;
            case OwnedObjectKind.Directory:
                break;
        }
        writer.WriteEndObject();
    }

    private static Utf8JsonWriter NewWriter(Stream stream) =>
        new(stream, new JsonWriterOptions { Indented = false, SkipValidation = false });

    private static void RequireExactProperties(JsonElement element, params string[] expected)
    {
        if (element.ValueKind != JsonValueKind.Object)
        {
            throw new InvalidDataException("Expected an exact JSON object.");
        }

        JsonProperty[] actual = element.EnumerateObject().ToArray();
        if (actual.Length != expected.Length || expected.Any(name =>
                actual.Count(property => string.Equals(
                    property.Name,
                    name,
                    StringComparison.Ordinal)) != 1))
        {
            throw new InvalidDataException("JSON object fields are missing, unknown, or duplicate.");
        }
    }

    private static string ReadString(JsonElement element, string name)
    {
        JsonElement value = element.GetProperty(name);
        if (value.ValueKind != JsonValueKind.String)
        {
            throw new InvalidDataException($"{name} must be a raw JSON string.");
        }

        return value.GetString()!;
    }

    private static int ReadInt32(JsonElement element, string name)
    {
        JsonElement value = element.GetProperty(name);
        if (value.ValueKind != JsonValueKind.Number || !value.TryGetInt32(out int result))
        {
            throw new InvalidDataException($"{name} must be a raw JSON Int32.");
        }

        return result;
    }

    private static long ReadInt64(JsonElement element, string name)
    {
        JsonElement value = element.GetProperty(name);
        if (value.ValueKind != JsonValueKind.Number || !value.TryGetInt64(out long result))
        {
            throw new InvalidDataException($"{name} must be a raw JSON Int64.");
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
                "Work manifest must be UTF-8 without BOM and have one final LF.");
        }
    }

    private static void ValidateKey(byte[] key)
    {
        ArgumentNullException.ThrowIfNull(key);
        if (key.Length != 32)
        {
            throw new ArgumentException("Work manifest key must contain exactly 256 bits.");
        }
    }

    private static bool IsLowerSha256(string? value) =>
        value is not null && LowerSha256Pattern.IsMatch(value);

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
