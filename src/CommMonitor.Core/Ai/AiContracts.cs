using System.Text.Json;

namespace CommMonitor.Core.Ai;

public sealed record AiRequestEnvelope(
    int Version,
    string RequestId,
    string Command,
    JsonElement Arguments);

public sealed record AiResponseEnvelope(
    int Version,
    string RequestId,
    bool Success,
    JsonElement? Result,
    AiError? Error);

public sealed record AiEventDto(
    int SchemaVersion,
    string Sequence,
    string WireSequence,
    string TimestampUtc,
    string QpcTicks,
    string DeviceId,
    string PortName,
    int ProcessId,
    string ProcessName,
    string ProcessNameStatus,
    string Kind,
    string IoctlCodeHex,
    string NtStatusHex,
    int RequestedLength,
    int CompletedLength,
    int CapturedLength,
    IReadOnlyList<string> Flags,
    string PayloadBase64,
    string? PayloadHex,
    string? TextPreview,
    bool Truncated);

public sealed record AiIntegrityDto(
    int SchemaVersion,
    bool StatsKnown,
    string? DriverDropped,
    string ServiceDropped,
    bool TruncationSeen,
    bool GapDetected,
    bool ContinuityProven,
    bool CompleteForReturnedRange,
    string? StatisticsSampledAtUtc,
    string? Generation);

public sealed record AiEventFilter(
    IReadOnlyList<string>? DeviceIds,
    IReadOnlyList<string>? Kinds,
    string? FromUtc,
    string? ToUtc,
    bool IncludeHex = false,
    bool IncludeTextPreview = false,
    int TextPreviewMaxBytes = 256);

public sealed record AiEventPage(
    IReadOnlyList<AiEventDto> Events,
    string NextCursor,
    bool HasMore,
    string ScannedThroughSequence,
    string ResumeReceipt,
    AiIntegrityDto Integrity,
    IReadOnlyList<string> Warnings);

public sealed record AiStatusDto(
    string ServiceState,
    string DriverState,
    string CaptureState,
    string CaptureOwner,
    string? CurrentSessionId,
    string Generation,
    AiIntegrityDto Integrity,
    IReadOnlyList<string> Warnings);

public sealed record AiPortDto(
    string DeviceId,
    string PortName,
    string FriendlyName,
    bool IsPresent);

public sealed record PrepareCaptureRequest(
    IReadOnlyList<string> DeviceIds,
    string? Label,
    string ClientInstanceId);

public sealed record PreparedCaptureDto(
    string ReservationId,
    string LeaseId,
    string LeaseSecret,
    string ClientInstanceId,
    string Generation,
    string ExpiresAtUtc);

public sealed record CommitCaptureRequest(
    string ReservationId,
    string LeaseId,
    string LeaseSecret,
    string ClientInstanceId,
    string Generation);

public sealed record ActiveCaptureDto(
    string LeaseId,
    string LeaseSecret,
    string ClientInstanceId,
    string Generation,
    string SessionId,
    string CaptureState);

public sealed record RecoverLeaseRequest(
    string LeaseId,
    string LeaseSecret,
    string ClientInstanceId,
    string Generation);

public sealed record LeaseProof(
    string LeaseId,
    string LeaseSecret,
    string ClientInstanceId,
    string Generation);

public sealed record ListSessionsRequest(
    string? Cursor,
    int Limit);

public sealed record AiSessionSummaryDto(
    string SessionId,
    string DisplayName,
    int SchemaVersion,
    string StartedUtc,
    string? StoppedUtc,
    string EventCount,
    string? Generation,
    AiIntegrityDto Integrity);

public sealed record AiSessionPage(
    IReadOnlyList<AiSessionSummaryDto> Sessions,
    string? NextCursor,
    bool HasMore);

public sealed record ReadEventsRequest(
    string SessionId,
    string? Cursor,
    string? ResumeReceipt,
    string? AfterSequence,
    bool AllowUnverifiedSeek,
    int Limit,
    AiEventFilter? Filter);

public sealed record WaitEventsRequest(
    string SessionId,
    string? Cursor,
    string? ResumeReceipt,
    string? AfterSequence,
    bool AllowUnverifiedSeek,
    int Limit,
    AiEventFilter? Filter,
    int TimeoutSeconds);

public sealed record ExportSessionRequest(
    string SessionId,
    string Format,
    string? SuggestedLabel);

public sealed record AiExportDto(
    string ExportId,
    string FileName,
    string FullPath,
    string Format,
    string ByteLength,
    string Sha256,
    string CreatedUtc);

public sealed record AiSchemaDto(
    int ProtocolVersion,
    IReadOnlyDictionary<string, JsonElement> Schemas,
    IReadOnlyList<string> ErrorCodes);
