using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using CommMonitor.Core.Ai;
using CommMonitor.Service.Security;

namespace CommMonitor.Service.Sessions;

internal sealed record SignedCursor(
    string Value,
    DateTimeOffset ExpiresAtUtc);

internal sealed record SignedResumeReceipt(
    string Value,
    DateTimeOffset ExpiresAtUtc);

internal sealed record CursorPosition(
    long Sequence,
    string KeyId,
    DateTimeOffset IssuedAtUtc,
    DateTimeOffset ExpiresAtUtc);

internal sealed record CursorResolution(
    long Sequence,
    bool ContinuityProven,
    IReadOnlyList<string> Warnings);

internal sealed class AiCursorException : Exception
{
    public AiCursorException(string code, string message, Exception? innerException = null)
        : base(message, innerException)
    {
        Code = code;
    }

    public string Code { get; }
}

internal sealed class CursorProtector
{
    private const int TokenVersion = 1;
    private const string CursorPrefix = "c1";
    private const string ResumePrefix = "r1";
    private static readonly TimeSpan CursorLifetime = TimeSpan.FromDays(7);
    private static readonly TimeSpan ResumeLifetime = TimeSpan.FromDays(90);
    private static readonly byte[] CursorPurpose = Encoding.UTF8.GetBytes("lemon/cursor/v1");
    private static readonly byte[] ResumePurpose = Encoding.UTF8.GetBytes("lemon/resume/v1");
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    private readonly IProtectedKeyRing _keyRing;

    public CursorProtector(IProtectedKeyRing keyRing)
    {
        _keyRing = keyRing ?? throw new ArgumentNullException(nameof(keyRing));
    }

    public SignedCursor ProtectCursor(
        string sessionId,
        string filterHash,
        long scannedSequence,
        DateTimeOffset now)
    {
        (string value, DateTimeOffset expiresAtUtc) = Protect(
            CursorPrefix,
            CursorPurpose,
            CursorLifetime,
            sessionId,
            filterHash,
            scannedSequence,
            now);
        return new SignedCursor(value, expiresAtUtc);
    }

    public SignedResumeReceipt ProtectResumeReceipt(
        string sessionId,
        string filterHash,
        long scannedSequence,
        DateTimeOffset now)
    {
        (string value, DateTimeOffset expiresAtUtc) = Protect(
            ResumePrefix,
            ResumePurpose,
            ResumeLifetime,
            sessionId,
            filterHash,
            scannedSequence,
            now);
        return new SignedResumeReceipt(value, expiresAtUtc);
    }

    public CursorPosition UnprotectCursor(
        string value,
        string sessionId,
        string filterHash,
        DateTimeOffset now) =>
        Unprotect(
            value,
            CursorPrefix,
            CursorPurpose,
            CursorLifetime,
            sessionId,
            filterHash,
            now);

    public CursorPosition UnprotectResumeReceipt(
        string value,
        string sessionId,
        string filterHash,
        DateTimeOffset now) =>
        Unprotect(
            value,
            ResumePrefix,
            ResumePurpose,
            ResumeLifetime,
            sessionId,
            filterHash,
            now);

    public CursorResolution ResolvePosition(
        string sessionId,
        string filterHash,
        string? cursor,
        string? resumeReceipt,
        long? afterSequence,
        bool allowUnverifiedSeek,
        DateTimeOffset now)
    {
        ValidateBinding(sessionId, filterHash);
        if (!string.IsNullOrWhiteSpace(cursor))
        {
            try
            {
                CursorPosition position = UnprotectCursor(
                    cursor,
                    sessionId,
                    filterHash,
                    now);
                ValidateConsistentSequence(afterSequence, position.Sequence);
                return new CursorResolution(position.Sequence, true, []);
            }
            catch (AiCursorException exception) when (
                exception.Code == AiErrorCodes.CursorExpired &&
                !string.IsNullOrWhiteSpace(resumeReceipt))
            {
                CursorPosition position = UnprotectResumeReceipt(
                    resumeReceipt,
                    sessionId,
                    filterHash,
                    now);
                ValidateConsistentSequence(afterSequence, position.Sequence);
                return new CursorResolution(position.Sequence, true, []);
            }
        }

        if (!string.IsNullOrWhiteSpace(resumeReceipt))
        {
            CursorPosition position = UnprotectResumeReceipt(
                resumeReceipt,
                sessionId,
                filterHash,
                now);
            ValidateConsistentSequence(afterSequence, position.Sequence);
            return new CursorResolution(position.Sequence, true, []);
        }

        if (afterSequence is null)
        {
            return new CursorResolution(0, true, []);
        }

        if (afterSequence < 0)
        {
            throw InvalidCursor("The requested sequence cannot be negative.");
        }

        if (!allowUnverifiedSeek)
        {
            throw new AiCursorException(
                AiErrorCodes.ContinuityUnproven,
                "An arbitrary sequence requires allowUnverifiedSeek=true.");
        }

        return new CursorResolution(
            afterSequence.Value,
            false,
            [AiErrorCodes.ContinuityUnproven]);
    }

    private (string Value, DateTimeOffset ExpiresAtUtc) Protect(
        string prefix,
        ReadOnlySpan<byte> purpose,
        TimeSpan lifetime,
        string sessionId,
        string filterHash,
        long scannedSequence,
        DateTimeOffset now)
    {
        ValidateBinding(sessionId, filterHash);
        if (scannedSequence < 0)
        {
            throw new ArgumentOutOfRangeException(
                nameof(scannedSequence),
                "A scanned sequence cannot be negative.");
        }

        ProtectedKeyMaterial active = WaitFor(
            _keyRing.GetActiveKeyAsync(),
            "The active signing key is unavailable.");
        DateTimeOffset issuedAtUtc = now.ToUniversalTime();
        DateTimeOffset expiresAtUtc = issuedAtUtc + lifetime;
        var payload = new TokenPayload(
            TokenVersion,
            active.KeyId,
            issuedAtUtc.UtcDateTime.Ticks,
            expiresAtUtc.UtcDateTime.Ticks,
            sessionId,
            scannedSequence,
            filterHash);
        byte[] payloadBytes = JsonSerializer.SerializeToUtf8Bytes(payload, JsonOptions);
        byte[] purposeKey = DerivePurposeKey(active.KeyBytes.Span, purpose);
        byte[] signature;
        try
        {
            using var hmac = new HMACSHA256(purposeKey);
            signature = hmac.ComputeHash(payloadBytes);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(purposeKey);
        }

        WaitFor(
            _keyRing.RetainKeyUntilAsync(active.KeyId, expiresAtUtc),
            "The signing key retention could not be persisted.");
        return (
            string.Join('.', prefix, Base64UrlEncode(payloadBytes), Base64UrlEncode(signature)),
            expiresAtUtc);
    }

    private CursorPosition Unprotect(
        string value,
        string expectedPrefix,
        ReadOnlySpan<byte> purpose,
        TimeSpan expectedLifetime,
        string sessionId,
        string filterHash,
        DateTimeOffset now)
    {
        ValidateBinding(sessionId, filterHash);
        if (!TryParseToken(value, expectedPrefix, out byte[] payloadBytes, out byte[] signature))
        {
            throw InvalidCursor("The signed cursor is malformed.");
        }

        TokenPayload payload;
        try
        {
            payload = JsonSerializer.Deserialize<TokenPayload>(payloadBytes, JsonOptions) ??
                throw new JsonException("The signed cursor payload is empty.");
        }
        catch (JsonException exception)
        {
            throw InvalidCursor("The signed cursor payload is invalid.", exception);
        }

        DateTimeOffset issuedAtUtc;
        DateTimeOffset expiresAtUtc;
        try
        {
            issuedAtUtc = new DateTimeOffset(payload.IssuedAtUtcTicks, TimeSpan.Zero);
            expiresAtUtc = new DateTimeOffset(payload.ExpiresAtUtcTicks, TimeSpan.Zero);
        }
        catch (ArgumentOutOfRangeException exception)
        {
            throw InvalidCursor("The signed cursor timestamps are invalid.", exception);
        }

        if (payload.Version != TokenVersion ||
            payload.Sequence < 0 ||
            string.IsNullOrWhiteSpace(payload.KeyId) ||
            expiresAtUtc - issuedAtUtc != expectedLifetime)
        {
            throw InvalidCursor("The signed cursor payload is invalid.");
        }

        ProtectedKeyMaterial key;
        try
        {
            key = WaitFor(
                _keyRing.GetKeyAsync(payload.KeyId, now),
                "The signing key is unavailable.");
        }
        catch (ProtectedKeyRingException exception)
        {
            string code = exception.Failure == ProtectedKeyFailure.Retired
                ? AiErrorCodes.CursorKeyRetired
                : AiErrorCodes.CursorKeyUnavailable;
            throw new AiCursorException(code, exception.Message, exception);
        }
        catch (Exception exception) when (
            exception is IOException or CryptographicException or InvalidDataException)
        {
            throw new AiCursorException(
                AiErrorCodes.CursorKeyUnavailable,
                "The signing key is unavailable.",
                exception);
        }

        byte[] purposeKey = DerivePurposeKey(key.KeyBytes.Span, purpose);
        byte[] expectedSignature;
        try
        {
            using var hmac = new HMACSHA256(purposeKey);
            expectedSignature = hmac.ComputeHash(payloadBytes);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(purposeKey);
        }

        if (!CryptographicOperations.FixedTimeEquals(expectedSignature, signature))
        {
            throw InvalidCursor("The signed cursor authentication tag is invalid.");
        }

        if (!string.Equals(payload.SessionId, sessionId, StringComparison.Ordinal))
        {
            throw InvalidCursor("The signed cursor belongs to a different session.");
        }

        if (!string.Equals(payload.FilterHash, filterHash, StringComparison.Ordinal))
        {
            throw new AiCursorException(
                AiErrorCodes.CursorFilterMismatch,
                "The signed cursor belongs to a different filter.");
        }

        if (now.ToUniversalTime() >= expiresAtUtc)
        {
            throw new AiCursorException(
                AiErrorCodes.CursorExpired,
                "The signed cursor has expired.");
        }

        return new CursorPosition(
            payload.Sequence,
            payload.KeyId,
            issuedAtUtc,
            expiresAtUtc);
    }

    private static void ValidateConsistentSequence(long? requested, long authenticated)
    {
        if (requested is not null && requested.Value != authenticated)
        {
            throw InvalidCursor(
                "The requested sequence differs from the authenticated continuation point.");
        }
    }

    private static void ValidateBinding(string sessionId, string filterHash)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(sessionId);
        ArgumentException.ThrowIfNullOrWhiteSpace(filterHash);
    }

    private static byte[] DerivePurposeKey(
        ReadOnlySpan<byte> masterKey,
        ReadOnlySpan<byte> purpose)
    {
        using var hmac = new HMACSHA256(masterKey.ToArray());
        return hmac.ComputeHash(purpose.ToArray());
    }

    private static bool TryParseToken(
        string value,
        string expectedPrefix,
        out byte[] payload,
        out byte[] signature)
    {
        payload = [];
        signature = [];
        if (string.IsNullOrWhiteSpace(value))
        {
            return false;
        }

        string[] components = value.Split('.');
        if (components.Length != 3 ||
            !string.Equals(components[0], expectedPrefix, StringComparison.Ordinal) ||
            !TryBase64UrlDecode(components[1], out payload) ||
            !TryBase64UrlDecode(components[2], out signature) ||
            signature.Length != 32)
        {
            payload = [];
            signature = [];
            return false;
        }

        return true;
    }

    private static bool TryBase64UrlDecode(string value, out byte[] bytes)
    {
        bytes = [];
        if (value.Length == 0 || value.Length % 4 == 1)
        {
            return false;
        }

        try
        {
            string base64 = value.Replace('-', '+').Replace('_', '/');
            base64 = base64.PadRight(base64.Length + ((4 - base64.Length % 4) % 4), '=');
            bytes = Convert.FromBase64String(base64);
            if (!string.Equals(Base64UrlEncode(bytes), value, StringComparison.Ordinal))
            {
                bytes = [];
                return false;
            }

            return true;
        }
        catch (FormatException)
        {
            return false;
        }
    }

    private static string Base64UrlEncode(ReadOnlySpan<byte> bytes) =>
        Convert.ToBase64String(bytes)
            .TrimEnd('=')
            .Replace('+', '-')
            .Replace('/', '_');

    private static T WaitFor<T>(ValueTask<T> operation, string message)
    {
        try
        {
            return operation.AsTask().ConfigureAwait(false).GetAwaiter().GetResult();
        }
        catch (ProtectedKeyRingException)
        {
            throw;
        }
        catch (Exception exception)
        {
            throw new ProtectedKeyRingException(
                ProtectedKeyFailure.Unavailable,
                message,
                exception);
        }
    }

    private static void WaitFor(ValueTask operation, string message)
    {
        try
        {
            operation.AsTask().ConfigureAwait(false).GetAwaiter().GetResult();
        }
        catch (ProtectedKeyRingException)
        {
            throw;
        }
        catch (Exception exception)
        {
            throw new ProtectedKeyRingException(
                ProtectedKeyFailure.Unavailable,
                message,
                exception);
        }
    }

    private static AiCursorException InvalidCursor(
        string message,
        Exception? innerException = null) =>
        new(AiErrorCodes.InvalidCursor, message, innerException);

    private sealed record TokenPayload(
        int Version,
        string KeyId,
        long IssuedAtUtcTicks,
        long ExpiresAtUtcTicks,
        string SessionId,
        long Sequence,
        string FilterHash);
}
