using System.Security.Cryptography;
using CommMonitor.Core.Ai;
using CommMonitor.Core.Models;

namespace CommMonitor.Service.Capture;

internal sealed record CaptureClientOwner(
    string Sid,
    ulong LogonLuid,
    string ClientInstanceId);

internal sealed record CaptureLeaseOwner(
    string Sid,
    ulong LogonLuid,
    string ClientInstanceId,
    long Generation);

internal sealed record PreparedLease(
    string ReservationId,
    string LeaseId,
    string Secret,
    string ClientInstanceId,
    long Generation,
    DateTimeOffset ExpiresAtUtc);

internal sealed record ActiveLease(
    string LeaseId,
    string Secret,
    string ClientInstanceId,
    long Generation,
    string SessionId,
    CaptureState CaptureState);

internal sealed class CaptureLeaseException : Exception
{
    public CaptureLeaseException(
        string code,
        string message,
        Exception? innerException = null)
        : base(message, innerException)
    {
        Code = code;
    }

    public string Code { get; }
}

internal sealed record LeaseCommit(
    CaptureSelection? Selection,
    ActiveLease? Active,
    long PreparedGeneration)
{
    public bool AlreadyCommitted => Active is not null;
}

internal sealed class CaptureLeaseManager
{
    internal static readonly TimeSpan ReservationLifetime = TimeSpan.FromSeconds(10);

    private PendingReservation? _pending;
    private ActiveReservation? _active;
    private string? _lastExpiredReservationId;

    public PreparedLease Prepare(
        CaptureClientOwner owner,
        long generation,
        CaptureSelection selection,
        DateTimeOffset now)
    {
        ValidateOwner(owner);
        ArgumentNullException.ThrowIfNull(selection);
        if (generation < 0)
        {
            throw new ArgumentOutOfRangeException(nameof(generation));
        }

        ExpirePending(now);
        if (_pending is not null || _active is not null)
        {
            throw Conflict("Capture already has an AI reservation or active AI lease.");
        }

        string reservationId = Guid.NewGuid().ToString("N");
        string leaseId = Guid.NewGuid().ToString("N");
        byte[] secret = RandomNumberGenerator.GetBytes(32);
        DateTimeOffset expiresAtUtc = now.ToUniversalTime() + ReservationLifetime;
        _pending = new PendingReservation(
            reservationId,
            leaseId,
            secret,
            owner,
            generation,
            expiresAtUtc,
            selection);
        _lastExpiredReservationId = null;
        return Describe(_pending);
    }

    public LeaseCommit BeginCommit(
        CaptureClientOwner owner,
        string reservationId,
        string secret,
        DateTimeOffset now)
    {
        ValidateOwner(owner);
        ArgumentException.ThrowIfNullOrWhiteSpace(reservationId);
        if (_active is not null &&
            string.Equals(_active.ReservationId, reservationId, StringComparison.Ordinal))
        {
            return BeginCommit(
                owner,
                reservationId,
                _active.LeaseId,
                secret,
                _active.PreparedGeneration,
                now);
        }

        ExpirePending(now);
        if (_pending is not null &&
            string.Equals(_pending.ReservationId, reservationId, StringComparison.Ordinal))
        {
            return BeginCommit(
                owner,
                reservationId,
                _pending.LeaseId,
                secret,
                _pending.PreparedGeneration,
                now);
        }

        if (string.Equals(
                _lastExpiredReservationId,
                reservationId,
                StringComparison.Ordinal))
        {
            throw new CaptureLeaseException(
                AiErrorCodes.StartReservationExpired,
                "The pending capture reservation has expired.");
        }

        throw Invalid("The pending capture reservation does not exist.");
    }

    public LeaseCommit BeginCommit(
        CaptureClientOwner owner,
        string reservationId,
        string leaseId,
        string secret,
        long generation,
        DateTimeOffset now)
    {
        ValidateOwner(owner);
        ArgumentException.ThrowIfNullOrWhiteSpace(reservationId);
        ArgumentException.ThrowIfNullOrWhiteSpace(leaseId);

        if (_active is not null &&
            string.Equals(_active.ReservationId, reservationId, StringComparison.Ordinal))
        {
            ValidateActiveProof(
                owner,
                leaseId,
                secret,
                _active.Owner.Generation,
                _active.Owner.Generation);
            if (generation != _active.PreparedGeneration)
            {
                throw Invalid("The acknowledged reservation generation is invalid.");
            }

            return new LeaseCommit(
                null,
                Describe(_active, _active.State),
                _active.PreparedGeneration);
        }

        ExpirePending(now);
        if (_pending is null)
        {
            if (string.Equals(
                    _lastExpiredReservationId,
                    reservationId,
                    StringComparison.Ordinal))
            {
                throw new CaptureLeaseException(
                    AiErrorCodes.StartReservationExpired,
                    "The pending capture reservation has expired.");
            }

            throw Invalid("The pending capture reservation does not exist.");
        }

        if (!string.Equals(_pending.ReservationId, reservationId, StringComparison.Ordinal) ||
            !string.Equals(_pending.LeaseId, leaseId, StringComparison.Ordinal) ||
            generation != _pending.PreparedGeneration ||
            !OwnerEquals(_pending.Owner, owner) ||
            !SecretMatches(_pending.Secret, secret))
        {
            throw Invalid("The capture reservation acknowledgement is invalid.");
        }

        return new LeaseCommit(
            _pending.Selection,
            null,
            _pending.PreparedGeneration);
    }

    public ActiveLease Activate(
        string reservationId,
        long generation,
        string sessionId,
        CaptureState state)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(reservationId);
        ArgumentException.ThrowIfNullOrWhiteSpace(sessionId);
        PendingReservation pending = _pending ??
            throw Invalid("The pending capture reservation does not exist.");
        if (!string.Equals(pending.ReservationId, reservationId, StringComparison.Ordinal) ||
            generation <= pending.PreparedGeneration)
        {
            throw Invalid("The committed capture generation is invalid.");
        }

        var leaseOwner = new CaptureLeaseOwner(
            pending.Owner.Sid,
            pending.Owner.LogonLuid,
            pending.Owner.ClientInstanceId,
            generation);
        _active = new ActiveReservation(
            pending.ReservationId,
            pending.LeaseId,
            pending.Secret,
            leaseOwner,
            pending.PreparedGeneration,
            sessionId,
            state);
        _pending = null;
        _lastExpiredReservationId = null;
        return Describe(_active, state);
    }

    public void FailCommit(string reservationId)
    {
        if (_pending is null ||
            !string.Equals(_pending.ReservationId, reservationId, StringComparison.Ordinal))
        {
            return;
        }

        CryptographicOperations.ZeroMemory(_pending.Secret);
        _pending = null;
        _lastExpiredReservationId = null;
    }

    public bool CancelPending(CaptureClientOwner owner, string reservationId)
    {
        ValidateOwner(owner);
        ArgumentException.ThrowIfNullOrWhiteSpace(reservationId);
        if (_pending is null ||
            !string.Equals(
                _pending.ReservationId,
                reservationId,
                StringComparison.Ordinal) ||
            !OwnerEquals(_pending.Owner, owner))
        {
            return false;
        }

        CryptographicOperations.ZeroMemory(_pending.Secret);
        _pending = null;
        _lastExpiredReservationId = null;
        return true;
    }

    public ActiveLease Recover(
        CaptureClientOwner owner,
        string leaseId,
        string secret,
        long generation,
        long coordinatorGeneration,
        CaptureState state)
    {
        ActiveReservation active = ValidateRecoveryProof(
            owner,
            leaseId,
            secret,
            generation,
            coordinatorGeneration,
            out bool replayedPreviousSecret);
        if (replayedPreviousSecret)
        {
            active.State = state;
            return Describe(active, state);
        }

        ClearPreviousRecoverySecret(active);
        byte[] replacement = RandomNumberGenerator.GetBytes(32);
        active.PreviousRecoverySecret = active.Secret;
        active.Secret = replacement;
        active.State = state;
        return Describe(active, state);
    }

    public ActiveLease Validate(
        CaptureClientOwner owner,
        string leaseId,
        string secret,
        long generation,
        long coordinatorGeneration,
        CaptureState state)
    {
        ActiveReservation active = ValidateActiveProof(
            owner,
            leaseId,
            secret,
            generation,
            coordinatorGeneration);
        ClearPreviousRecoverySecret(active);
        active.State = state;
        return Describe(active, state);
    }

    public ActiveLease Describe(CaptureState state)
    {
        ActiveReservation active = _active ??
            throw Expired("The AI capture lease is no longer active.");
        active.State = state;
        return Describe(active, state);
    }

    public bool HasReservationOrLease(DateTimeOffset now)
    {
        ExpirePending(now);
        return _pending is not null || _active is not null;
    }

    public bool InvalidateLogonSession(string sid, ulong logonLuid)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(sid);
        bool invalidated = false;
        if (_pending is not null &&
            string.Equals(_pending.Owner.Sid, sid, StringComparison.Ordinal) &&
            _pending.Owner.LogonLuid == logonLuid)
        {
            CryptographicOperations.ZeroMemory(_pending.Secret);
            _pending = null;
            _lastExpiredReservationId = null;
            invalidated = true;
        }

        if (_active is not null &&
            string.Equals(_active.Owner.Sid, sid, StringComparison.Ordinal) &&
            _active.Owner.LogonLuid == logonLuid)
        {
            ZeroActive(_active);
            _active = null;
            invalidated = true;
        }

        return invalidated;
    }

    public void Invalidate()
    {
        if (_pending is not null)
        {
            CryptographicOperations.ZeroMemory(_pending.Secret);
            _pending = null;
        }

        if (_active is not null)
        {
            ZeroActive(_active);
            _active = null;
        }

        _lastExpiredReservationId = null;
    }

    private ActiveReservation ValidateActiveProof(
        CaptureClientOwner owner,
        string leaseId,
        string secret,
        long generation,
        long coordinatorGeneration)
    {
        ValidateOwner(owner);
        ActiveReservation? active = _active;
        if (active is null)
        {
            throw Expired("The AI capture lease is no longer active.");
        }

        bool secretMatches = SecretMatches(active.Secret, secret);
        if (!string.Equals(active.LeaseId, leaseId, StringComparison.Ordinal) ||
            !secretMatches)
        {
            throw Invalid("The AI capture lease proof is invalid.");
        }

        ValidateActiveOwnerAndGeneration(
            active,
            owner,
            generation,
            coordinatorGeneration);
        return active;
    }

    private ActiveReservation ValidateRecoveryProof(
        CaptureClientOwner owner,
        string leaseId,
        string secret,
        long generation,
        long coordinatorGeneration,
        out bool replayedPreviousSecret)
    {
        ValidateOwner(owner);
        ActiveReservation? active = _active;
        if (active is null)
        {
            throw Expired("The AI capture lease is no longer active.");
        }

        bool currentMatches = SecretMatches(active.Secret, secret);
        bool previousMatches = active.PreviousRecoverySecret is not null &&
            SecretMatches(active.PreviousRecoverySecret, secret);
        if (!string.Equals(active.LeaseId, leaseId, StringComparison.Ordinal) ||
            (!currentMatches && !previousMatches))
        {
            throw Invalid("The AI capture lease proof is invalid.");
        }

        ValidateActiveOwnerAndGeneration(
            active,
            owner,
            generation,
            coordinatorGeneration);
        replayedPreviousSecret = previousMatches;
        return active;
    }

    private void ValidateActiveOwnerAndGeneration(
        ActiveReservation active,
        CaptureClientOwner owner,
        long generation,
        long coordinatorGeneration)
    {

        if (generation != active.Owner.Generation ||
            coordinatorGeneration != active.Owner.Generation)
        {
            Invalidate();
            throw Expired("The AI capture lease generation is no longer active.");
        }

        if (!string.Equals(active.Owner.Sid, owner.Sid, StringComparison.Ordinal) ||
            !string.Equals(
                active.Owner.ClientInstanceId,
                owner.ClientInstanceId,
                StringComparison.Ordinal))
        {
            throw Invalid("The AI capture lease belongs to a different owner.");
        }

        if (active.Owner.LogonLuid != owner.LogonLuid)
        {
            Invalidate();
            throw Expired("The login session that owned the AI capture lease has ended.");
        }
    }

    private static void ClearPreviousRecoverySecret(ActiveReservation active)
    {
        if (active.PreviousRecoverySecret is null)
        {
            return;
        }

        CryptographicOperations.ZeroMemory(active.PreviousRecoverySecret);
        active.PreviousRecoverySecret = null;
    }

    private static void ZeroActive(ActiveReservation active)
    {
        CryptographicOperations.ZeroMemory(active.Secret);
        ClearPreviousRecoverySecret(active);
    }

    private void ExpirePending(DateTimeOffset now)
    {
        if (_pending is null || now.ToUniversalTime() < _pending.ExpiresAtUtc)
        {
            return;
        }

        _lastExpiredReservationId = _pending.ReservationId;
        CryptographicOperations.ZeroMemory(_pending.Secret);
        _pending = null;
    }

    private static PreparedLease Describe(PendingReservation pending) =>
        new(
            pending.ReservationId,
            pending.LeaseId,
            Base64UrlEncode(pending.Secret),
            pending.Owner.ClientInstanceId,
            pending.PreparedGeneration,
            pending.ExpiresAtUtc);

    private static ActiveLease Describe(
        ActiveReservation active,
        CaptureState state) =>
        new(
            active.LeaseId,
            Base64UrlEncode(active.Secret),
            active.Owner.ClientInstanceId,
            active.Owner.Generation,
            active.SessionId,
            state);

    private static bool OwnerEquals(
        CaptureClientOwner expected,
        CaptureClientOwner supplied) =>
        string.Equals(expected.Sid, supplied.Sid, StringComparison.Ordinal) &&
        expected.LogonLuid == supplied.LogonLuid &&
        string.Equals(
            expected.ClientInstanceId,
            supplied.ClientInstanceId,
            StringComparison.Ordinal);

    private static bool SecretMatches(byte[] expected, string? supplied)
    {
        byte[] candidate = new byte[expected.Length];
        bool validLength = TryBase64UrlDecode(supplied, out byte[] decoded) &&
            decoded.Length == expected.Length;
        if (decoded.Length > 0)
        {
            decoded.AsSpan(0, Math.Min(decoded.Length, candidate.Length)).CopyTo(candidate);
        }

        bool matches = CryptographicOperations.FixedTimeEquals(expected, candidate);
        CryptographicOperations.ZeroMemory(candidate);
        CryptographicOperations.ZeroMemory(decoded);
        return validLength && matches;
    }

    private static bool TryBase64UrlDecode(string? value, out byte[] bytes)
    {
        bytes = [];
        if (string.IsNullOrWhiteSpace(value) || value.Length % 4 == 1)
        {
            return false;
        }

        try
        {
            string base64 = value.Replace('-', '+').Replace('_', '/');
            base64 = base64.PadRight(
                base64.Length + ((4 - base64.Length % 4) % 4),
                '=');
            bytes = Convert.FromBase64String(base64);
            return string.Equals(Base64UrlEncode(bytes), value, StringComparison.Ordinal);
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

    private static void ValidateOwner(CaptureClientOwner owner)
    {
        ArgumentNullException.ThrowIfNull(owner);
        ArgumentException.ThrowIfNullOrWhiteSpace(owner.Sid);
        ArgumentException.ThrowIfNullOrWhiteSpace(owner.ClientInstanceId);
    }

    private static CaptureLeaseException Conflict(string message) =>
        new(AiErrorCodes.CaptureConflict, message);

    private static CaptureLeaseException Invalid(string message) =>
        new(AiErrorCodes.InvalidLease, message);

    private static CaptureLeaseException Expired(string message) =>
        new(AiErrorCodes.LeaseExpired, message);

    private sealed class PendingReservation(
        string reservationId,
        string leaseId,
        byte[] secret,
        CaptureClientOwner owner,
        long preparedGeneration,
        DateTimeOffset expiresAtUtc,
        CaptureSelection selection)
    {
        public string ReservationId { get; } = reservationId;
        public string LeaseId { get; } = leaseId;
        public byte[] Secret { get; } = secret;
        public CaptureClientOwner Owner { get; } = owner;
        public long PreparedGeneration { get; } = preparedGeneration;
        public DateTimeOffset ExpiresAtUtc { get; } = expiresAtUtc;
        public CaptureSelection Selection { get; } = selection;
    }

    private sealed class ActiveReservation(
        string reservationId,
        string leaseId,
        byte[] secret,
        CaptureLeaseOwner owner,
        long preparedGeneration,
        string sessionId,
        CaptureState state)
    {
        public string ReservationId { get; } = reservationId;
        public string LeaseId { get; } = leaseId;
        public byte[] Secret { get; set; } = secret;
        public byte[]? PreviousRecoverySecret { get; set; }
        public CaptureLeaseOwner Owner { get; } = owner;
        public long PreparedGeneration { get; } = preparedGeneration;
        public string SessionId { get; } = sessionId;
        public CaptureState State { get; set; } = state;
    }
}
