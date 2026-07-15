using System.Text.Json;
using System.Text.Json.Serialization;
using CommMonitor.Core.Ai;
using CommMonitor.Core.Control;
using CommMonitor.Core.Ipc;
using CommMonitor.Core.Models;

namespace CommMonitor.Core.Tests.Ai;

public sealed class AiContractTests
{
    [Fact]
    public void Protocols_expose_the_stable_AI_and_control_endpoints()
    {
        Assert.Equal("Lemon.SerialMonitor.AI.v1", AiProtocol.PipeName);
        Assert.Equal(1, AiProtocol.Version);
        Assert.Equal(100, AiProtocol.DefaultPageSize);
        Assert.Equal(1000, AiProtocol.MaximumPageSize);
        Assert.Equal(4 * 1024 * 1024, AiProtocol.MaximumResponseBytes);
        Assert.Equal(TimeSpan.FromSeconds(30), AiProtocol.MaximumWait);
        Assert.Equal("Lemon.SerialMonitor.Control.v2", ControlProtocol.PipeName);
        Assert.Equal(2, ControlProtocol.Version);
        Assert.Equal(ControlProtocol.PipeName, PipeProtocol.PipeName);
        Assert.Equal(ControlProtocol.Version, PipeProtocol.Version);
    }

    [Fact]
    public void Command_names_match_the_internal_transport_set()
    {
        Assert.Equal(
            [
                "status",
                "ports",
                "prepare-start",
                "commit-start",
                "recover-lease",
                "pause",
                "resume",
                "stop",
                "sessions",
                "read",
                "wait",
                "export",
                "schema",
            ],
            new[]
            {
                AiCommandNames.Status,
                AiCommandNames.Ports,
                AiCommandNames.PrepareStart,
                AiCommandNames.CommitStart,
                AiCommandNames.RecoverLease,
                AiCommandNames.Pause,
                AiCommandNames.Resume,
                AiCommandNames.Stop,
                AiCommandNames.Sessions,
                AiCommandNames.Read,
                AiCommandNames.Wait,
                AiCommandNames.Export,
                AiCommandNames.Schema,
            });
    }

    [Fact]
    public void Error_codes_match_the_approved_set()
    {
        Assert.Equal(
            [
                "SERVICE_UNAVAILABLE",
                "DRIVER_UNAVAILABLE",
                "PROTOCOL_MISMATCH",
                "ACCESS_DENIED",
                "CAPTURE_CONFLICT",
                "INVALID_LEASE",
                "LEASE_EXPIRED",
                "START_RESERVATION_EXPIRED",
                "SESSION_NOT_FOUND",
                "INVALID_CURSOR",
                "CURSOR_FILTER_MISMATCH",
                "CURSOR_EXPIRED",
                "CURSOR_KEY_RETIRED",
                "CURSOR_KEY_UNAVAILABLE",
                "LIMIT_EXCEEDED",
                "RESPONSE_BUDGET_EXCEEDED",
                "EXPORT_EXISTS",
                "DATA_GAP",
                "INTEGRITY_UNKNOWN",
                "LEGACY_INTEGRITY_UNKNOWN",
                "CONTINUITY_UNPROVEN",
                "TIMEOUT",
                "CANCELLED",
            ],
            new[]
            {
                AiErrorCodes.ServiceUnavailable,
                AiErrorCodes.DriverUnavailable,
                AiErrorCodes.ProtocolMismatch,
                AiErrorCodes.AccessDenied,
                AiErrorCodes.CaptureConflict,
                AiErrorCodes.InvalidLease,
                AiErrorCodes.LeaseExpired,
                AiErrorCodes.StartReservationExpired,
                AiErrorCodes.SessionNotFound,
                AiErrorCodes.InvalidCursor,
                AiErrorCodes.CursorFilterMismatch,
                AiErrorCodes.CursorExpired,
                AiErrorCodes.CursorKeyRetired,
                AiErrorCodes.CursorKeyUnavailable,
                AiErrorCodes.LimitExceeded,
                AiErrorCodes.ResponseBudgetExceeded,
                AiErrorCodes.ExportExists,
                AiErrorCodes.DataGap,
                AiErrorCodes.IntegrityUnknown,
                AiErrorCodes.LegacyIntegrityUnknown,
                AiErrorCodes.ContinuityUnproven,
                AiErrorCodes.Timeout,
                AiErrorCodes.Cancelled,
            });
    }

    [Fact]
    public void AiError_preserves_the_machine_readable_envelope()
    {
        IReadOnlyDictionary<string, string> details =
            new Dictionary<string, string> { ["limit"] = "1000" };

        var error = new AiError(
            AiErrorCodes.LimitExceeded,
            "The requested page is too large.",
            Retryable: false,
            "correlation-42",
            details);

        Assert.Equal("LIMIT_EXCEEDED", error.Code);
        Assert.Equal("The requested page is too large.", error.Message);
        Assert.False(error.Retryable);
        Assert.Equal("correlation-42", error.CorrelationId);
        Assert.Same(details, error.Details);
    }

    [Fact]
    public void AiJson_uses_web_defaults_a_bounded_depth_and_strict_members()
    {
        JsonSerializerOptions options = AiJson.CreateOptions();

        Assert.Equal(64, options.MaxDepth);
        Assert.Equal(JsonUnmappedMemberHandling.Disallow, options.UnmappedMemberHandling);
        Assert.Equal("propertyName", options.PropertyNamingPolicy!.ConvertName("PropertyName"));
        Assert.Throws<JsonException>(
            () => JsonSerializer.Deserialize<AiError>(
                """
                {"code":"TIMEOUT","message":"Timed out.","retryable":true,"correlationId":"c","extra":1}
                """,
                options));
    }

    [Fact]
    public void AiJson_rejects_integer_enum_values()
    {
        JsonSerializerOptions options = AiJson.CreateOptions();

        Assert.Throws<JsonException>(
            () => JsonSerializer.Deserialize<CaptureKind>("1", options));
        Assert.Equal(
            "\"Read\"",
            JsonSerializer.Serialize(CaptureKind.Read, options));
    }

    [Fact]
    public void Unknown_driver_statistics_are_represented_as_null_not_zero()
    {
        AiIntegrityDto integrity = CreateIntegrity(statsKnown: false, driverDropped: null);

        Assert.False(integrity.StatsKnown);
        Assert.Null(integrity.DriverDropped);

        JsonElement json = JsonSerializer.SerializeToElement(integrity, AiJson.CreateOptions());
        Assert.Equal(JsonValueKind.Null, json.GetProperty("driverDropped").ValueKind);
    }

    [Theory]
    [MemberData(nameof(AllContracts))]
    public void Every_contract_round_trips_with_camel_case_JSON(object contract)
    {
        JsonSerializerOptions options = AiJson.CreateOptions();
        Type contractType = contract.GetType();

        string json = JsonSerializer.Serialize(contract, contractType, options);
        object? roundTripped = JsonSerializer.Deserialize(json, contractType, options);

        Assert.NotNull(roundTripped);
        Assert.Equal(json, JsonSerializer.Serialize(roundTripped, contractType, options));
        using JsonDocument document = JsonDocument.Parse(json);
        Assert.All(
            document.RootElement.EnumerateObject(),
            static property => Assert.True(
                char.IsLower(property.Name[0]),
                $"Expected camelCase JSON but found '{property.Name}'."));
    }

    public static TheoryData<object> AllContracts()
    {
        JsonSerializerOptions options = AiJson.CreateOptions();
        JsonElement arguments = JsonSerializer.SerializeToElement(
            new { sessionId = "session-1" },
            options);
        JsonElement result = JsonSerializer.SerializeToElement(
            new { state = "running" },
            options);
        AiIntegrityDto integrity = CreateIntegrity(statsKnown: true, driverDropped: "2");
        var error = new AiError(
            AiErrorCodes.Timeout,
            "Timed out.",
            Retryable: true,
            "correlation-1");
        var eventDto = new AiEventDto(
            SchemaVersion: 1,
            Sequence: "10",
            WireSequence: "9",
            TimestampUtc: "2026-07-13T04:00:00.0000000Z",
            QpcTicks: "1234",
            DeviceId: "0000000000000011",
            PortName: "COM3",
            ProcessId: 42,
            ProcessName: "terminal.exe",
            ProcessNameStatus: "available",
            Kind: "Read",
            IoctlCodeHex: "0x00000000",
            NtStatusHex: "0x00000000",
            RequestedLength: 3,
            CompletedLength: 3,
            CapturedLength: 3,
            Flags: ["InputPayload"],
            PayloadBase64: "AID/",
            PayloadHex: "00 80 FF",
            TextPreview: null,
            Truncated: false);

        var contracts = new TheoryData<object>
        {
            new AiRequestEnvelope(AiProtocol.Version, "request-1", AiCommandNames.Status, arguments),
            new AiResponseEnvelope(AiProtocol.Version, "request-1", true, result, null),
            error,
            eventDto,
            integrity,
            new AiEventFilter(
                DeviceIds: ["0000000000000011"],
                Kinds: ["Read"],
                FromUtc: "2026-07-13T04:00:00.0000000Z",
                ToUtc: null,
                IncludeHex: true,
                IncludeTextPreview: true,
                TextPreviewMaxBytes: 128),
            new AiEventPage(
                Events: [eventDto],
                NextCursor: "cursor-2",
                HasMore: true,
                ScannedThroughSequence: "10",
                ResumeReceipt: "receipt-1",
                Integrity: integrity,
                Warnings: ["DATA_GAP"]),
            new AiStatusDto(
                ServiceState: "available",
                DriverState: "available",
                CaptureState: "running",
                CaptureOwner: "ai",
                CurrentSessionId: "session-1",
                Generation: "generation-1",
                Integrity: integrity,
                Warnings: []),
            new AiPortDto("0000000000000011", "COM3", "USB Serial Port", true),
            new PrepareCaptureRequest(["0000000000000011"], "diagnostic", "client-1"),
            new PreparedCaptureDto(
                "reservation-1",
                "lease-1",
                "secret-1",
                "client-1",
                "generation-1",
                "2026-07-13T04:05:00.0000000Z"),
            new CommitCaptureRequest(
                "reservation-1",
                "lease-1",
                "secret-1",
                "client-1",
                "generation-1"),
            new ActiveCaptureDto(
                "lease-1",
                "secret-1",
                "client-1",
                "generation-1",
                "session-1",
                "running"),
            new RecoverLeaseRequest("lease-1", "secret-1", "client-1", "generation-1"),
            new LeaseProof("lease-1", "secret-1", "client-1", "generation-1"),
            new ListSessionsRequest("cursor-1", 100),
            new AiSessionSummaryDto(
                "session-1",
                "Diagnostic capture",
                1,
                "2026-07-13T04:00:00.0000000Z",
                null,
                "10",
                "generation-1",
                integrity),
            new AiSessionPage(
                Sessions:
                [
                    new AiSessionSummaryDto(
                        "session-1",
                        "Diagnostic capture",
                        1,
                        "2026-07-13T04:00:00.0000000Z",
                        null,
                        "10",
                        "generation-1",
                        integrity),
                ],
                NextCursor: null,
                HasMore: false),
            new ReadEventsRequest(
                "session-1",
                "cursor-1",
                "receipt-1",
                null,
                false,
                100,
                new AiEventFilter(null, null, null, null)),
            new WaitEventsRequest(
                "session-1",
                "cursor-1",
                "receipt-1",
                null,
                false,
                100,
                new AiEventFilter(null, null, null, null),
                30),
            new ExportSessionRequest("session-1", "csv", "diagnostic"),
            new AiExportDto(
                "export-1",
                "diagnostic.csv",
                "C:\\exports\\diagnostic.csv",
                "csv",
                "1024",
                "ABCDEF",
                "2026-07-13T04:10:00.0000000Z"),
            new AiSchemaDto(
                AiProtocol.Version,
                new Dictionary<string, JsonElement> { ["event"] = arguments },
                [AiErrorCodes.Timeout]),
        };

        return contracts;
    }

    private static AiIntegrityDto CreateIntegrity(bool statsKnown, string? driverDropped) =>
        new(
            SchemaVersion: 1,
            StatsKnown: statsKnown,
            DriverDropped: driverDropped,
            ServiceDropped: "0",
            TruncationSeen: false,
            GapDetected: false,
            ContinuityProven: statsKnown,
            CompleteForReturnedRange: statsKnown,
            StatisticsSampledAtUtc: statsKnown ? "2026-07-13T04:00:00.0000000Z" : null,
            Generation: "generation-1");
}
