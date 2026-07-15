namespace CommMonitor.Core.Ai;

public sealed record AiError(
    string Code,
    string Message,
    bool Retryable,
    string CorrelationId,
    IReadOnlyDictionary<string, string>? Details = null);

public static class AiErrorCodes
{
    public const string ServiceUnavailable = "SERVICE_UNAVAILABLE";
    public const string DriverUnavailable = "DRIVER_UNAVAILABLE";
    public const string ProtocolMismatch = "PROTOCOL_MISMATCH";
    public const string AccessDenied = "ACCESS_DENIED";
    public const string CaptureConflict = "CAPTURE_CONFLICT";
    public const string InvalidLease = "INVALID_LEASE";
    public const string LeaseExpired = "LEASE_EXPIRED";
    public const string StartReservationExpired = "START_RESERVATION_EXPIRED";
    public const string SessionNotFound = "SESSION_NOT_FOUND";
    public const string InvalidCursor = "INVALID_CURSOR";
    public const string CursorFilterMismatch = "CURSOR_FILTER_MISMATCH";
    public const string CursorExpired = "CURSOR_EXPIRED";
    public const string CursorKeyRetired = "CURSOR_KEY_RETIRED";
    public const string CursorKeyUnavailable = "CURSOR_KEY_UNAVAILABLE";
    public const string LimitExceeded = "LIMIT_EXCEEDED";
    public const string ResponseBudgetExceeded = "RESPONSE_BUDGET_EXCEEDED";
    public const string ExportExists = "EXPORT_EXISTS";
    public const string DataGap = "DATA_GAP";
    public const string IntegrityUnknown = "INTEGRITY_UNKNOWN";
    public const string LegacyIntegrityUnknown = "LEGACY_INTEGRITY_UNKNOWN";
    public const string ContinuityUnproven = "CONTINUITY_UNPROVEN";
    public const string Timeout = "TIMEOUT";
    public const string Cancelled = "CANCELLED";
}
