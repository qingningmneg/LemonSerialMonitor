# Lemon AI Service Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the LocalSystem-side Lemon AI data service, durable integrity model, safe session paging, capture leases, and separated Control.v2/AI.v1 named-pipe protocols without opening or occupying COM ports.

**Architecture:** The existing driver-to-service path remains unchanged through `DriverCaptureSource`; `CaptureCoordinator` still persists each batch before notifying consumers. New Core contracts and SQLite schema v3 provide stable AI DTOs and durable integrity evidence, while focused service components own key protection, session IDs, cursors, capture authority, and the two named-pipe endpoints. The unsafe mixed `CommMonitor.Service.v1` endpoint is removed atomically with the WPF Control.v2 client migration.

**Tech Stack:** C# 12, .NET 8, `Microsoft.Data.Sqlite` 8.0.22, Windows named pipes and ACLs, DPAPI LocalMachine, HMAC-SHA256, xUnit; existing KMDF driver protocol v1 and `GET_STATS` ABI.

## Global Constraints

- Target Windows 10/11 x64; keep Core and Service on `net8.0`.
- Keep `CommMonitorService`, `CommMonitorFilter`, `%ProgramFiles%\CommMonitor`, `%ProgramData%\CommMonitor`, the driver device path, and existing C# namespaces.
- Stop listening on `CommMonitor.Service.v1`; never provide a fallback to it.
- Use `Lemon.SerialMonitor.Control.v2` for verified WPF clients and `Lemon.SerialMonitor.AI.v1` for AI clients.
- AI never opens a COM port, the driver device, or a SQLite path supplied by a caller.
- AI has no Clear, Delete, Send, Inject, Replay, device configuration, overwrite-by-default, or arbitrary-path command.
- Driver payload remains capped at 4096 bytes; dropped, truncated, gap, legacy, and unknown states must be explicit.
- AI pages default to 100 events, hard-limit at 1000 events and 4 MiB, and wait calls stop after 30 seconds.
- AI pipe has at least 8 instances independent of the 4 Control.v2 instances.
- Event batches remain commit-before-notify; slow AI clients may lag SQLite but cannot block capture or WPF.
- All 217 existing .NET tests and all new tests must pass before moving to the AI client plan.
- Preserve unrelated working-tree changes and stage only the files named by each task.

---

## Planned File Map

### Core AI contracts and storage

- `src/CommMonitor.Core/Ai/AiProtocol.cs`: pipe constants, page/frame/wait limits, JSON options.
- `src/CommMonitor.Core/Ai/AiError.cs`: stable error codes and structured error envelope.
- `src/CommMonitor.Core/Ai/AiContracts.cs`: requests, responses, filters, ports, sessions, pages, lease and integrity DTOs.
- `src/CommMonitor.Core/Ai/AiEventMapper.cs`: lossless `CaptureEvent` to AI event conversion using string 64-bit values and Base64.
- `src/CommMonitor.Core/Control/ControlContracts.cs`: Control.v2 hello/challenge, command, confirmation and event contracts.
- `src/CommMonitor.Core/Ipc/LengthPrefixedJsonCodec.cs`: protocol-neutral bounded frame codec with explicit options.
- `src/CommMonitor.Core/Sessions/SessionModels.cs`: v3 capture-run, stats, marker and query records.
- `src/CommMonitor.Core/Sessions/ISessionStore.cs`: transactional event/integrity APIs.
- `src/CommMonitor.Core/Sessions/SessionStore.cs`: v1/v2-to-v3 migration and writer implementation.
- `src/CommMonitor.Core/Sessions/ReadOnlySessionReader.cs`: parameterized, read-only filtered paging.

### Service capture, security and sessions

- `src/CommMonitor.Service/Capture/CaptureSourceStatistics.cs`: statistics interface and known/unknown snapshot.
- `src/CommMonitor.Service/Capture/CaptureAuthority.cs`: common owner/generation state for WPF and AI.
- `src/CommMonitor.Service/Capture/CaptureLeaseManager.cs`: pending reservation, ACK, owner-bound lease and rotation.
- `src/CommMonitor.Service/Capture/CaptureCoordinator.cs`: generation, run evidence, statistics sampling and durable notification.
- `src/CommMonitor.Service/Driver/DriverCaptureSource.cs`: exact 24-byte `GET_STATS` decoding.
- `src/CommMonitor.Service/Security/InstallSecurityOptions.cs`: protected installer metadata and authorized SID.
- `src/CommMonitor.Service/Security/ProtectedKeyRing.cs`: DPAPI LocalMachine-protected active/retired keys.
- `src/CommMonitor.Service/Sessions/SessionCatalog.cs`: safe direct-child enumeration and opaque session IDs.
- `src/CommMonitor.Service/Sessions/CursorProtector.cs`: signed cursor and 90-day resume receipt.
- `src/CommMonitor.Service/Sessions/AiSessionService.cs`: list/read/wait/export business operations.
- `src/CommMonitor.Service/Ipc/IPipeClientIdentityProvider.cs`: testable PID/SID/LUID/image identity contract.
- `src/CommMonitor.Service/Ipc/WindowsPipeClientIdentityProvider.cs`: Windows token/process implementation.
- `src/CommMonitor.Service/Ipc/ControlPipeServer.cs`: verified WPF-only endpoint.
- `src/CommMonitor.Service/Ipc/AiPipeServer.cs`: bounded AI endpoint and stable error mapping.
- `src/CommMonitor.Service/Program.cs`: dependency wiring for the new components only.

### Tests

- `tests/CommMonitor.Core.Tests/Ai/AiContractTests.cs`
- `tests/CommMonitor.Core.Tests/Ai/AiEventMapperTests.cs`
- `tests/CommMonitor.Core.Tests/Sessions/SessionStoreV3Tests.cs`
- `tests/CommMonitor.Core.Tests/Sessions/ReadOnlySessionReaderTests.cs`
- `tests/CommMonitor.Service.Tests/Driver/DriverStatisticsTests.cs`
- `tests/CommMonitor.Service.Tests/Capture/CaptureIntegrityTests.cs`
- `tests/CommMonitor.Service.Tests/Capture/CaptureLeaseManagerTests.cs`
- `tests/CommMonitor.Service.Tests/Sessions/SessionCatalogTests.cs`
- `tests/CommMonitor.Service.Tests/Sessions/CursorProtectorTests.cs`
- `tests/CommMonitor.Service.Tests/Sessions/AiSessionServiceTests.cs`
- `tests/CommMonitor.Service.Tests/Ipc/PipeClientIdentityProviderTests.cs`
- `tests/CommMonitor.Service.Tests/Ipc/ControlPipeServerTests.cs`
- `tests/CommMonitor.Service.Tests/Ipc/AiPipeServerTests.cs`
- `tests/CommMonitor.Service.Tests/Ipc/AiPipeFuzzTests.cs`

---

### Task 1: Stable AI contracts and bounded framing

**Files:**
- Create: `src/CommMonitor.Core/Ai/AiProtocol.cs`
- Create: `src/CommMonitor.Core/Ai/AiError.cs`
- Create: `src/CommMonitor.Core/Ai/AiContracts.cs`
- Create: `src/CommMonitor.Core/Ai/AiEventMapper.cs`
- Create: `src/CommMonitor.Core/Control/ControlContracts.cs`
- Create: `src/CommMonitor.Core/Ipc/LengthPrefixedJsonCodec.cs`
- Modify: `src/CommMonitor.Core/Ipc/PipeFrameCodec.cs`
- Test: `tests/CommMonitor.Core.Tests/Ai/AiContractTests.cs`
- Test: `tests/CommMonitor.Core.Tests/Ai/AiEventMapperTests.cs`
- Modify test: `tests/CommMonitor.Service.Tests/Ipc/PipeFrameCodecTests.cs`

**Interfaces:**
- Produces all protocol-neutral AI request/reply DTOs needed by the later service and client tasks: envelopes, status, ports, events, integrity, leases, sessions, paging, export and schema; plus `AiProtocol`, `AiCommandNames`, `AiErrorCodes`, `AiJson`, `ControlProtocol`, and `LengthPrefixedJsonCodec.ReadAsync<T>/WriteAsync<T>`.
- `AiEventDto.Sequence`, `WireSequence`, `QpcTicks`, and `DeviceId` are strings; `PayloadBase64` is the lossless payload.
- The generic codec accepts a `JsonFrameOptions(MaximumFrameLength, MaximumDepth)` value and checks the length before allocation.

- [ ] **Step 1: Write failing contract and framing tests**

Create tests that compile against these exact shapes:

```csharp
Assert.Equal("Lemon.SerialMonitor.AI.v1", AiProtocol.PipeName);
Assert.Equal(1, AiProtocol.Version);
Assert.Equal(4 * 1024 * 1024, AiProtocol.MaximumResponseBytes);
Assert.Equal(1000, AiProtocol.MaximumPageSize);
Assert.Equal(TimeSpan.FromSeconds(30), AiProtocol.MaximumWait);
Assert.Equal("Lemon.SerialMonitor.Control.v2", ControlProtocol.PipeName);
Assert.Equal(2, ControlProtocol.Version);

CaptureEvent source = TestEvents.Create(
    sequence: long.MaxValue,
    wireSequence: long.MaxValue - 1,
    deviceId: ulong.MaxValue,
    payload: [0x00, 0x80, 0xFF]);
AiEventDto dto = AiEventMapper.Map(source, includeHex: true);
Assert.Equal(long.MaxValue.ToString(CultureInfo.InvariantCulture), dto.Sequence);
Assert.Equal("FFFFFFFFFFFFFFFF", dto.DeviceId);
Assert.Equal("AID/", dto.PayloadBase64);
Assert.Equal("00 80 FF", dto.PayloadHex);
```

Compile tests against these exact public records (all JSON property names use web/camelCase serialization):

```csharp
public sealed record AiRequestEnvelope(
    int Version, string RequestId, string Command, JsonElement Arguments);
public sealed record AiResponseEnvelope(
    int Version, string RequestId, bool Success, JsonElement? Result, AiError? Error);

public sealed record AiEventDto(
    int SchemaVersion, string Sequence, string WireSequence, string TimestampUtc,
    string QpcTicks, string DeviceId, string PortName, int ProcessId,
    string ProcessName, string ProcessNameStatus, string Kind,
    string IoctlCodeHex, string NtStatusHex, int RequestedLength,
    int CompletedLength, int CapturedLength, IReadOnlyList<string> Flags,
    string PayloadBase64, string? PayloadHex, string? TextPreview, bool Truncated);
public sealed record AiIntegrityDto(
    int SchemaVersion, bool StatsKnown, string? DriverDropped,
    string ServiceDropped, bool TruncationSeen, bool GapDetected,
    bool ContinuityProven, bool CompleteForReturnedRange,
    string? StatisticsSampledAtUtc, string? Generation);
public sealed record AiEventFilter(
    IReadOnlyList<string>? DeviceIds, IReadOnlyList<string>? Kinds,
    string? FromUtc, string? ToUtc, bool IncludeHex = false,
    bool IncludeTextPreview = false, int TextPreviewMaxBytes = 256);
public sealed record AiEventPage(
    IReadOnlyList<AiEventDto> Events, string NextCursor, bool HasMore,
    string ScannedThroughSequence, string ResumeReceipt,
    AiIntegrityDto Integrity, IReadOnlyList<string> Warnings);

public sealed record AiStatusDto(
    string ServiceState, string DriverState, string CaptureState,
    string CaptureOwner, string? CurrentSessionId, string Generation,
    AiIntegrityDto Integrity, IReadOnlyList<string> Warnings);
public sealed record AiPortDto(
    string DeviceId, string PortName, string FriendlyName, bool IsPresent);

public sealed record PrepareCaptureRequest(
    IReadOnlyList<string> DeviceIds, string? Label, string ClientInstanceId);
public sealed record PreparedCaptureDto(
    string ReservationId, string LeaseId, string LeaseSecret,
    string ClientInstanceId, string Generation, string ExpiresAtUtc);
public sealed record CommitCaptureRequest(
    string ReservationId, string LeaseId, string LeaseSecret,
    string ClientInstanceId, string Generation);
public sealed record ActiveCaptureDto(
    string LeaseId, string LeaseSecret, string ClientInstanceId,
    string Generation, string SessionId, string CaptureState);
public sealed record RecoverLeaseRequest(
    string LeaseId, string LeaseSecret, string ClientInstanceId, string Generation);
public sealed record LeaseProof(
    string LeaseId, string LeaseSecret, string ClientInstanceId, string Generation);

public sealed record ListSessionsRequest(string? Cursor, int Limit);
public sealed record AiSessionSummaryDto(
    string SessionId, string DisplayName, int SchemaVersion, string StartedUtc,
    string? StoppedUtc, string EventCount, string? Generation,
    AiIntegrityDto Integrity);
public sealed record AiSessionPage(
    IReadOnlyList<AiSessionSummaryDto> Sessions, string? NextCursor, bool HasMore);
public sealed record ReadEventsRequest(
    string SessionId, string? Cursor, string? ResumeReceipt,
    string? AfterSequence, bool AllowUnverifiedSeek, int Limit,
    AiEventFilter? Filter);
public sealed record WaitEventsRequest(
    string SessionId, string? Cursor, string? ResumeReceipt,
    string? AfterSequence, bool AllowUnverifiedSeek, int Limit,
    AiEventFilter? Filter, int TimeoutSeconds);
public sealed record ExportSessionRequest(
    string SessionId, string Format, string? SuggestedLabel);
public sealed record AiExportDto(
    string ExportId, string FileName, string FullPath, string Format,
    string ByteLength, string Sha256, string CreatedUtc);
public sealed record AiSchemaDto(
    int ProtocolVersion, IReadOnlyDictionary<string, JsonElement> Schemas,
    IReadOnlyList<string> ErrorCodes);
```

Tests also assert: `DeviceId` is uppercase fixed `X16`; IOCTL/NTSTATUS are uppercase `0x` + `X8`; timestamps use UTC round-trip `O`; flags are stable enum names; unresolved process names are empty with `ProcessNameStatus="unavailable"`; `DriverDropped` is `null` when statistics are unknown rather than a fabricated zero; `AiJson` rejects integer enum values; and serialization round-trips every contract.

Add codec tests for a 4 MiB+1 length prefix, truncated prefix/payload, JSON null, depth 65, malformed JSON, cancellation and a valid frame. Assert an oversized frame throws before the test stream's payload-read counter increments.

- [ ] **Step 2: Run the focused tests and verify failure**

Run:

```powershell
dotnet test tests/CommMonitor.Core.Tests/CommMonitor.Core.Tests.csproj --filter "AiContractTests|AiEventMapperTests"
dotnet test tests/CommMonitor.Service.Tests/CommMonitor.Service.Tests.csproj --filter PipeFrameCodecTests
```

Expected: FAIL because the AI/Control contracts and protocol-neutral codec do not exist.

- [ ] **Step 3: Implement the contracts and strict codec**

Use these exact protocol constants and error envelope:

```csharp
public static class AiProtocol
{
    public const int Version = 1;
    public const string PipeName = "Lemon.SerialMonitor.AI.v1";
    public const int DefaultPageSize = 100;
    public const int MaximumPageSize = 1000;
    public const int MaximumResponseBytes = 4 * 1024 * 1024;
    public static readonly TimeSpan MaximumWait = TimeSpan.FromSeconds(30);
}

public static class ControlProtocol
{
    public const int Version = 2;
    public const string PipeName = "Lemon.SerialMonitor.Control.v2";
}

public sealed record AiError(
    string Code,
    string Message,
    bool Retryable,
    string CorrelationId,
    IReadOnlyDictionary<string, string>? Details = null);
```

Define `AiCommandNames` constants for the exact internal transport set `status`, `ports`, `prepare-start`, `commit-start`, `recover-lease`, `pause`, `resume`, `stop`, `sessions`, `read`, `wait`, `export`, and `schema`. Define `AiErrorCodes` constants for every approved code: `SERVICE_UNAVAILABLE`, `DRIVER_UNAVAILABLE`, `PROTOCOL_MISMATCH`, `ACCESS_DENIED`, `CAPTURE_CONFLICT`, `INVALID_LEASE`, `LEASE_EXPIRED`, `START_RESERVATION_EXPIRED`, `SESSION_NOT_FOUND`, `INVALID_CURSOR`, `CURSOR_FILTER_MISMATCH`, `CURSOR_EXPIRED`, `CURSOR_KEY_RETIRED`, `CURSOR_KEY_UNAVAILABLE`, `LIMIT_EXCEEDED`, `RESPONSE_BUDGET_EXCEEDED`, `EXPORT_EXISTS`, `DATA_GAP`, `INTEGRITY_UNKNOWN`, `LEGACY_INTEGRITY_UNKNOWN`, `CONTINUITY_UNPROVEN`, `TIMEOUT`, and `CANCELLED`.

`AiJson.CreateOptions()` returns a new `JsonSerializerOptions(JsonSerializerDefaults.Web)` with maximum depth 64, strict unmapped-member handling and `JsonStringEnumConverter(allowIntegerValues: false)`. Implement `LengthPrefixedJsonCodec` with `ArrayPool<byte>` only after validating the four-byte signed little-endian length, strict UTF-8 decoding and those shared options. Keep `PipeFrameCodec` as a compatibility wrapper only until the atomic Control.v2 migration in Task 6 removes v1.

- [ ] **Step 4: Run contract, codec and existing Core tests**

Run:

```powershell
dotnet test tests/CommMonitor.Core.Tests/CommMonitor.Core.Tests.csproj
dotnet test tests/CommMonitor.Service.Tests/CommMonitor.Service.Tests.csproj --filter PipeFrameCodecTests
```

Expected: all focused tests PASS; existing Core tests remain green.

- [ ] **Step 5: Commit Task 1**

```powershell
git add -- src/CommMonitor.Core/Ai src/CommMonitor.Core/Control src/CommMonitor.Core/Ipc/LengthPrefixedJsonCodec.cs src/CommMonitor.Core/Ipc/PipeFrameCodec.cs tests/CommMonitor.Core.Tests/Ai tests/CommMonitor.Service.Tests/Ipc/PipeFrameCodecTests.cs
git commit -m "feat: add Lemon AI protocol contracts"
```

---

### Task 2: SQLite schema v3 and transactional integrity evidence

**Files:**
- Create: `src/CommMonitor.Core/Sessions/SessionModels.cs`
- Create: `src/CommMonitor.Core/Sessions/ReadOnlySessionReader.cs`
- Modify: `src/CommMonitor.Core/Sessions/ISessionStore.cs`
- Modify: `src/CommMonitor.Core/Sessions/SessionStore.cs`
- Create: `tests/CommMonitor.Core.Tests/Sessions/SessionStoreV3Tests.cs`
- Create: `tests/CommMonitor.Core.Tests/Sessions/ReadOnlySessionReaderTests.cs`
- Modify test: `tests/CommMonitor.Core.Tests/Sessions/SessionStoreTests.cs`

**Interfaces:**
- Produces: `CaptureRunRecord`, `DriverStatsSnapshot`, `IntegrityMarker`, `PersistBatch`, `SessionEventQuery`, `SessionEventPage`, and `IReadOnlySessionReader` with the exact shapes below.
- `ISessionStore.AppendBatchAsync(PersistBatch, CancellationToken)` writes events and markers in one SQLite transaction and returns persisted events.
- `ReadOnlySessionReader` opens only `SqliteOpenMode.ReadOnly`, never creates a database, and supports parameterized device/kind/time filters.

```csharp
public sealed record DriverStatsSnapshot(
    bool StatsKnown, uint Queued, CaptureState State, ulong Dropped,
    ulong Sequence, DateTimeOffset SampledAtUtc, string? UnavailableReason);
public sealed record CaptureRunRecord(
    string RunId, string SessionId, long Generation, string ServiceInstanceId,
    string OwnerType, string OwnerSid, IReadOnlyList<string> SelectedDeviceIds,
    long StartAfterSequence, long? EndSequence,
    DateTimeOffset StartedUtc, DateTimeOffset? StoppedUtc,
    DriverStatsSnapshot StartStats, DriverStatsSnapshot? EndStats,
    long ServiceDropped, long TruncationCount, bool StatsKnown,
    bool CleanShutdown, string? EndReason);
public sealed record IntegrityMarker(
    long? MarkerId, string RunId, long Generation, string MarkerType,
    DateTimeOffset OccurredUtc, long AfterSequence, long CountDelta, string Code);
public sealed record PersistBatch(
    IReadOnlyList<CaptureEvent> Events,
    IReadOnlyList<IntegrityMarker> Markers);
public sealed record SessionEventQuery(
    long AfterSequence, int Limit, IReadOnlyList<ulong>? DeviceIds,
    IReadOnlyList<CaptureKind>? Kinds, DateTimeOffset? FromUtc,
    DateTimeOffset? ToUtc);
public sealed record SessionEventPage(
    IReadOnlyList<CaptureEvent> Events, long ScannedThroughSequence,
    bool HasMore, int SchemaVersion, bool StatsKnown,
    IReadOnlyList<string> IntegrityCodes,
    IReadOnlyList<CaptureRunRecord> Runs,
    IReadOnlyList<IntegrityMarker> Markers);

public interface IReadOnlySessionReader
{
    Task<int> GetSchemaVersionAsync(CancellationToken cancellationToken = default);
    Task<SessionEventPage> ReadAsync(
        SessionEventQuery query,
        CancellationToken cancellationToken = default);
    Task<IReadOnlyList<CaptureEvent>> ReadAfterAsync(
        long sequence,
        int limit,
        CancellationToken cancellationToken = default);
    Task<IReadOnlyList<CaptureRunRecord>> ReadRunsAsync(
        CancellationToken cancellationToken = default);
    Task<IReadOnlyList<IntegrityMarker>> ReadMarkersAsync(
        string runId,
        CancellationToken cancellationToken = default);
}
```

Extend `ISessionStore` with `GetSchemaVersionAsync`, `GetLastSequenceAsync`, `CountRunsAsync`, `UpsertRunAsync`, `ReadRunsAsync`, `ReadMarkersAsync`, and `AppendBatchAsync`; `GetSchemaVersionAsync` returns `Task<int>`, while `GetLastSequenceAsync` and `CountRunsAsync` return `Task<long>`. Preserve `AppendAsync` as a compatibility delegate to an empty-marker batch. `ClearAsync` deletes markers, runs and events in one transaction. `UpsertRunAsync` must not silently replace an existing run with a different session ID, generation or service instance. `GetLastSequenceAsync` supplies the exclusive start boundary recorded before a run accepts events.

- [ ] **Step 1: Write failing v3 migration and transaction tests**

Build fixture databases for schema v1, v2 and v3. Assert:

```csharp
await store.InitializeAsync();
Assert.Equal(3, await store.GetSchemaVersionAsync());
Assert.Equal(0, await store.CountRunsAsync());

await InstallFailingMarkerTriggerAsync(path);
await Assert.ThrowsAsync<SqliteException>(() =>
    store.AppendBatchAsync(new PersistBatch(events, markers)));
Assert.Empty(await reader.ReadAfterAsync(0, 100));
Assert.Empty(await reader.ReadMarkersAsync(runId));
```

`InstallFailingMarkerTriggerAsync` creates a test-database trigger that raises `ABORT` before marker insertion; no failure flag, test-only callback or other test seam is added to production contracts. Add tests that opening v3 twice is idempotent, v3 never writes schema version 2, a future schema version is rejected before journal mode or sidecar state changes, every read API fails closed on a v3-layout fixture labeled with a future version, old v2 event column values/payload bytes remain identical, a marker whose generation differs from its run rolls back the complete batch, a reader remains non-blocking while another WAL connection holds an uncommitted writer transaction, legacy reads report `statsKnown=false` and `LEGACY_INTEGRITY_UNKNOWN`, filters are parameterized, page limits are enforced, and the reader never creates a missing file.

- [ ] **Step 2: Run the storage tests and verify failure**

Run:

```powershell
dotnet test tests/CommMonitor.Core.Tests/CommMonitor.Core.Tests.csproj --filter "SessionStoreV3Tests|ReadOnlySessionReaderTests|SessionStoreTests"
```

Expected: FAIL because schema v3 records and read-only reader do not exist.

- [ ] **Step 3: Implement schema v3 and read-only paging**

Create these tables in the same migration transaction that updates `metadata.schema_version`:

```sql
CREATE TABLE IF NOT EXISTS capture_runs(
 run_id TEXT PRIMARY KEY,
 session_id TEXT NOT NULL,
 generation INTEGER NOT NULL,
 service_instance_id TEXT NOT NULL,
 owner_type TEXT NOT NULL,
 owner_sid TEXT NOT NULL,
 selected_devices_json TEXT NOT NULL,
 start_after_sequence INTEGER NOT NULL,
 end_sequence INTEGER NULL,
 started_utc TEXT NOT NULL,
 stopped_utc TEXT NULL,
 start_stats_json TEXT NOT NULL,
 end_stats_json TEXT NULL,
 service_dropped INTEGER NOT NULL DEFAULT 0,
 truncation_count INTEGER NOT NULL DEFAULT 0,
 stats_known INTEGER NOT NULL,
 clean_shutdown INTEGER NOT NULL DEFAULT 0,
 end_reason TEXT NULL,
 UNIQUE(run_id, generation)
);
CREATE TABLE IF NOT EXISTS integrity_markers(
 marker_id INTEGER PRIMARY KEY AUTOINCREMENT,
 run_id TEXT NOT NULL,
 generation INTEGER NOT NULL,
 marker_type TEXT NOT NULL,
 occurred_utc TEXT NOT NULL,
 after_sequence INTEGER NOT NULL,
 count_delta INTEGER NOT NULL,
 code TEXT NOT NULL,
 FOREIGN KEY(run_id, generation) REFERENCES capture_runs(run_id, generation)
);
CREATE INDEX IF NOT EXISTS ix_integrity_run_sequence
 ON integrity_markers(run_id, after_sequence);
```

Before executing persistent pragmas or DDL, read an existing metadata version on the same connection and reject versions greater than 3; then set WAL mode, begin the migration transaction and re-read the version to guard races. Serialize stats and selected devices deterministically with the shared strict AI JSON settings; store device IDs as uppercase `X16` strings. Enable foreign keys on every writer connection. Bind marker generation to run generation with the composite foreign key above. Use one transaction for each batch and one prepared event command plus one prepared marker command. Keep `ReadAfterAsync` for existing exporters, but implement filtered AI paging in `ReadOnlySessionReader` with allow-listed SQL fragments and parameters only.

Every reader operation that interprets database content rejects schema versions greater than 3 with a clear compatibility exception; `GetSchemaVersionAsync` may still report the raw future version. Use an explicitly deferred read transaction so WAL writers are not blocked while the first schema query establishes one consistent snapshot. For filtered paging, validate a 1–1000 limit and half-open UTC time range `[FromUtc, ToUtc)`, then establish a consistent maximum sequence for the read. When `limit + 1` matching events exist, return `limit`, set `HasMore=true`, and set `ScannedThroughSequence` to the last returned sequence. When fewer match, set `HasMore=false` and advance `ScannedThroughSequence` to that consistent maximum even if zero events matched, so a selective cursor cannot loop forever. Return runs whose `(StartAfterSequence, EndSequence]` overlaps the scanned interval and markers with `AfterSequence` inside it. For schema v3, `StatsKnown` is true only when at least one relevant run exists and every relevant run has known statistics; codes are marker codes in `(AfterSequence, MarkerId)` order with ordinal first-occurrence de-duplication, plus one `INTEGRITY_UNKNOWN` when `StatsKnown=false`. For schema v1/v2, return no fabricated run/marker evidence, `StatsKnown=false`, and exactly `LEGACY_INTEGRITY_UNKNOWN`.

- [ ] **Step 4: Run all Core session tests**

Run:

```powershell
dotnet test tests/CommMonitor.Core.Tests/CommMonitor.Core.Tests.csproj --filter "FullyQualifiedName~Sessions"
```

Expected: all session migration, transaction, paging and existing round-trip tests PASS.

- [ ] **Step 5: Commit Task 2**

```powershell
git add -- src/CommMonitor.Core/Sessions tests/CommMonitor.Core.Tests/Sessions
git commit -m "feat: persist capture integrity in session schema v3"
```

---

### Task 3: Driver statistics and capture generations

**Files:**
- Create: `src/CommMonitor.Service/Capture/CaptureSourceStatistics.cs`
- Modify: `src/CommMonitor.Service/Capture/FakeCaptureSource.cs`
- Modify: `src/CommMonitor.Service/Driver/DriverCaptureSource.cs`
- Modify: `src/CommMonitor.Service/Capture/CaptureSelection.cs`
- Modify: `src/CommMonitor.Service/Capture/CaptureCoordinator.cs`
- Create: `tests/CommMonitor.Service.Tests/Driver/DriverStatisticsTests.cs`
- Create: `tests/CommMonitor.Service.Tests/Capture/CaptureIntegrityTests.cs`
- Modify test: `tests/CommMonitor.Service.Tests/Capture/CaptureCoordinatorTests.cs`
- Modify test: `tests/CommMonitor.Service.Tests/Capture/CaptureCoordinatorSessionTests.cs`

**Interfaces:**
- Produces: `ICaptureSourceStatisticsProvider.GetStatisticsAsync`, `CaptureSourceStatistics`, `CaptureSnapshot`, monotonically increasing `CaptureCoordinator.Generation`, and committed-event notification.
- `CaptureSelection` gains `RunId`, `SessionId`, `OwnerType`, and `OwnerSid` without accepting caller filesystem paths at the pipe layer.

- [ ] **Step 1: Write failing driver-stat and integrity tests**

Use the existing scripted driver device to return the exact native layout:

```csharp
byte[] bytes = new byte[24];
BinaryPrimitives.WriteUInt32LittleEndian(bytes, 7);
BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(4), (uint)CaptureState.Running);
BinaryPrimitives.WriteUInt64LittleEndian(bytes.AsSpan(8), ulong.MaxValue - 1);
BinaryPrimitives.WriteUInt64LittleEndian(bytes.AsSpan(16), ulong.MaxValue);
CaptureSourceStatistics stats = await source.GetStatisticsAsync(default);
Assert.True(stats.StatsKnown);
Assert.Equal(7U, stats.Queued);
Assert.Equal(ulong.MaxValue - 1, stats.Dropped);
```

Add tests for 23/25-byte replies, invalid state, unavailable stats, counter rollback/source restart, generation increments, start/end snapshots, truncated flags, interrupted runs, persistence failure recovery markers, and commit-before-notify.

- [ ] **Step 2: Run focused Service tests and verify failure**

Run:

```powershell
dotnet test tests/CommMonitor.Service.Tests/CommMonitor.Service.Tests.csproj --filter "DriverStatisticsTests|CaptureIntegrityTests|CaptureCoordinatorTests|CaptureCoordinatorSessionTests"
```

Expected: FAIL because statistics and generation APIs do not exist.

- [ ] **Step 3: Implement statistics sampling and durable run lifecycle**

Define:

```csharp
public interface ICaptureSourceStatisticsProvider
{
    ValueTask<CaptureSourceStatistics> GetStatisticsAsync(CancellationToken cancellationToken);
}

public sealed record CaptureSourceStatistics(
    bool StatsKnown,
    uint Queued,
    CaptureState State,
    ulong Dropped,
    ulong Sequence,
    DateTimeOffset SampledAtUtc,
    string? UnavailableReason);
```

Decode exactly 24 bytes from `DriverProtocol.GetStatsIoControlCode`. `FakeCaptureSource` returns unknown stats. `CaptureCoordinator.StartAsync` records the baseline before enabling capture; periodic and stop samples compute deltas only when counters are monotonic. A rollback writes a `SOURCE_RESTART` marker and makes the run incomplete. Persist each event batch and its markers atomically, then signal `EventsCommitted`.

- [ ] **Step 4: Run all driver and capture tests**

Run:

```powershell
dotnet test tests/CommMonitor.Service.Tests/CommMonitor.Service.Tests.csproj --filter "FullyQualifiedName~Driver|FullyQualifiedName~Capture"
```

Expected: all existing and new driver/capture tests PASS.

- [ ] **Step 5: Commit Task 3**

```powershell
git add -- src/CommMonitor.Service/Capture src/CommMonitor.Service/Driver/DriverCaptureSource.cs tests/CommMonitor.Service.Tests/Capture tests/CommMonitor.Service.Tests/Driver/DriverStatisticsTests.cs
git commit -m "feat: track capture generations and driver integrity"
```

---

### Task 4: Protected key ring, session catalog, cursors and resume receipts

**Files:**
- Modify: `src/CommMonitor.Service/CommMonitor.Service.csproj`
- Create: `src/CommMonitor.Service/Security/InstallSecurityOptions.cs`
- Create: `src/CommMonitor.Service/Security/ProtectedKeyRing.cs`
- Create: `src/CommMonitor.Service/Sessions/SessionCatalog.cs`
- Create: `src/CommMonitor.Service/Sessions/CursorProtector.cs`
- Create: `tests/CommMonitor.Service.Tests/Sessions/SessionCatalogTests.cs`
- Create: `tests/CommMonitor.Service.Tests/Sessions/CursorProtectorTests.cs`

**Interfaces:**
- Produces: `IProtectedKeyRing.GetActiveKeyAsync`, `SessionCatalog.ListAsync/ResolveAsync`, and `CursorProtector.ProtectCursor/UnprotectCursor/ProtectResumeReceipt`.
- Session IDs and cursors use purpose-separated HMAC-SHA256 keys; raw keys never appear in logs or replies.

- [ ] **Step 1: Write failing catalog and signing tests**

Test direct `.db` and `.cmsession` children, rejection of WAL/SHM/journal, nested paths, hard links, reparse points and missing files. Test HMAC tampering, filter mismatch, seven-day cursor expiry, 90-day receipt expiry, service restart with the same protected key, rotation retaining every unexpired retired key, emergency retirement, and `allowUnverifiedSeek` returning `CONTINUITY_UNPROVEN`.

```csharp
SignedCursor cursor = protector.ProtectCursor(
    sessionId, filterHash, scannedSequence: 42, now);
Assert.Equal(42, protector.UnprotectCursor(cursor.Value, sessionId, filterHash, now).Sequence);
Assert.Throws<AiCursorException>(() =>
    protector.UnprotectCursor(cursor.Value + "A", sessionId, filterHash, now));
```

- [ ] **Step 2: Run focused tests and verify failure**

Run:

```powershell
dotnet test tests/CommMonitor.Service.Tests/CommMonitor.Service.Tests.csproj --filter "SessionCatalogTests|CursorProtectorTests"
```

Expected: FAIL because the catalog and key services do not exist.

- [ ] **Step 3: Implement protected keys and opaque identifiers**

Add `System.Security.Cryptography.ProtectedData` version `8.0.0`. Store a versioned key-ring JSON under the installer-supplied CoreRoot metadata path, protect key bytes with `ProtectedData.Protect(..., DataProtectionScope.LocalMachine)`, write atomically, and require SYSTEM/Administrators-only ACL. Derive keys using HMAC labels `lemon/session-id/v1`, `lemon/cursor/v1`, and `lemon/resume/v1`.

`SessionCatalog` must obtain safe handles through `ServiceStorageBoundary`, accept only direct `.db`/`.cmsession` files, and return an authenticated session ID rather than a path. Retain retired keys until the last 90-day receipt expires.

- [ ] **Step 4: Run catalog, cursor and storage-security tests**

Run:

```powershell
dotnet test tests/CommMonitor.Service.Tests/CommMonitor.Service.Tests.csproj --filter "SessionCatalogTests|CursorProtectorTests|ServiceStorageSecurityTests"
```

Expected: PASS with no test able to escape the managed Sessions root.

- [ ] **Step 5: Commit Task 4**

```powershell
git add -- src/CommMonitor.Service/CommMonitor.Service.csproj src/CommMonitor.Service/Security src/CommMonitor.Service/Sessions tests/CommMonitor.Service.Tests/Sessions
git commit -m "feat: protect Lemon session identifiers and cursors"
```

---

### Task 5: Capture authority, two-phase AI leases and read/wait/export service

**Files:**
- Create: `src/CommMonitor.Service/Capture/CaptureAuthority.cs`
- Create: `src/CommMonitor.Service/Capture/CaptureLeaseManager.cs`
- Create: `src/CommMonitor.Service/Sessions/AiSessionService.cs`
- Create: `tests/CommMonitor.Service.Tests/Capture/CaptureLeaseManagerTests.cs`
- Create: `tests/CommMonitor.Service.Tests/Sessions/AiSessionServiceTests.cs`

**Interfaces:**
- Produces: `PrepareAiStartAsync`, `CommitAiStartAsync`, `RecoverLeaseAsync`, `PauseAiAsync`, `ResumeAiAsync`, `StopAiAsync`, `StartWpfAsync`, and `StopWpfAsync` on `CaptureAuthority`.
- Lease owner is `(SID, logon LUID, clientInstanceId, generation)`; secret comparisons are constant-time.
- `AiSessionService.ReadAsync/WaitAsync` always reads committed SQLite rows and returns a cursor plus resume receipt.

- [ ] **Step 1: Write failing authority and paging tests**

Cover pending reservation timeout, disconnect before ACK, ACK then driver-start failure, service crash before/after commit, DPAPI-vault reply loss simulation, owner SID/LUID/client mismatch, secret rotation and replay, WPF conflict, no AI force takeover, commit-before-wait, query-register-query race, one active wait per client, 30-second cap, 1000-event/4-MiB budgets, and CreateNew export.

```csharp
PreparedLease pending = await authority.PrepareAiStartAsync(owner, devices, label, now);
Assert.Equal(CaptureState.Stopped, coordinator.State);
ActiveLease active = await authority.CommitAiStartAsync(owner, pending.ReservationId, pending.Secret, now);
Assert.Equal(CaptureState.Running, coordinator.State);
await Assert.ThrowsAsync<AiServiceException>(() =>
    authority.PauseAiAsync(otherOwner, active.LeaseId, active.Secret, active.Generation));
```

- [ ] **Step 2: Run focused tests and verify failure**

Run:

```powershell
dotnet test tests/CommMonitor.Service.Tests/CommMonitor.Service.Tests.csproj --filter "CaptureLeaseManagerTests|AiSessionServiceTests"
```

Expected: FAIL because authority, lease and AI session services do not exist.

- [ ] **Step 3: Implement authority and session operations**

Use a single async transition gate in `CaptureAuthority`. A pending reservation lasts 10 seconds and does not call the coordinator. Commit validates the ACK proof, starts the coordinator once, records generation, and returns an active lease. Recovery requires the same SID/LUID/clientInstanceId and rotates the secret; service restart, logout, generation change and Stop invalidate it.

Implement wait as: read SQLite, register a per-session commit notification, immediately read again, then await notification or timeout and read once more. Export accepts `(sessionId, format, suggestedLabel)` only; formats are `json`, `jsonl`, `csv`, `txt`, and `raw`. It creates a unique service-managed file with `FileMode.CreateNew` and never accepts a directory or overwrite flag from AI.

- [ ] **Step 4: Run authority/session plus capture regression tests**

Run:

```powershell
dotnet test tests/CommMonitor.Service.Tests/CommMonitor.Service.Tests.csproj --filter "CaptureLeaseManagerTests|AiSessionServiceTests|CaptureCoordinator"
```

Expected: PASS, including all crash-window reconciliation cases.

- [ ] **Step 5: Commit Task 5**

```powershell
git add -- src/CommMonitor.Service/Capture/CaptureAuthority.cs src/CommMonitor.Service/Capture/CaptureLeaseManager.cs src/CommMonitor.Service/Sessions/AiSessionService.cs tests/CommMonitor.Service.Tests/Capture/CaptureLeaseManagerTests.cs tests/CommMonitor.Service.Tests/Sessions/AiSessionServiceTests.cs
git commit -m "feat: add owner-bound AI capture leases"
```

---

### Task 6: Windows client identity and Control.v2 atomic migration

**Files:**
- Create: `src/CommMonitor.Service/Ipc/IPipeClientIdentityProvider.cs`
- Create: `src/CommMonitor.Service/Ipc/WindowsPipeClientIdentityProvider.cs`
- Create: `src/CommMonitor.Service/Ipc/ControlPipeServer.cs`
- Modify: `src/CommMonitor.Service/Program.cs`
- Remove: `src/CommMonitor.Service/Ipc/PipeServer.cs`
- Remove: `src/CommMonitor.Core/Ipc/PipeContracts.cs`
- Remove: `src/CommMonitor.Core/Ipc/PipeFrameCodec.cs`
- Modify: `src/CommMonitor.App/Services/ServiceClient.cs`
- Modify: `src/CommMonitor.App/Services/IConfirmationService.cs`
- Modify: `src/CommMonitor.App/Services/WpfConfirmationService.cs`
- Modify: `src/CommMonitor.App/ViewModels/MainViewModel.cs`
- Modify test: `tests/CommMonitor.App.Tests/Services/ServiceClientTests.cs`
- Modify test: `tests/CommMonitor.App.Tests/ViewModels/MainViewModelTests.cs`
- Modify test: `tests/CommMonitor.App.Tests/Services/WpfConfirmationServiceTests.cs`
- Create: `tests/CommMonitor.Service.Tests/Ipc/PipeClientIdentityProviderTests.cs`
- Create: `tests/CommMonitor.Service.Tests/Ipc/ControlPipeServerTests.cs`
- Remove/replace: `tests/CommMonitor.Service.Tests/Ipc/PipeServerTests.cs`

**Interfaces:**
- Produces: `PipeClientIdentity(ProcessId, Sid, LogonLuid, FinalImagePath, Sha256)` and a Control.v2 server with connection challenge and one-use confirmation nonce.
- WPF `IServiceClient.ExportAsync` returns the actual service path and only retries overwrite after `ConfirmOverwriteExport`.
- Both WPF command and subscription connections perform Control.v2 hello; no v1 constant or fallback remains.

- [ ] **Step 1: Rewrite tests for Control.v2 before production changes**

Migrate existing WPF client tests so their fake server performs hello/challenge before commands. Preserve status parsing, immutable event delivery, command correlation, timeouts, disposal, Clear subscription quiesce/recovery and observer isolation. Add tests for wrong PID/SID/path/hash, protocol mismatch, challenge replay, nonce expiry/replay/connection change/generation change, default export exists, Yes/No overwrite confirmation, and explicit absence of `CommMonitor.Service.v1`.

- [ ] **Step 2: Run Control and App tests and verify failure**

Run:

```powershell
dotnet test tests/CommMonitor.Service.Tests/CommMonitor.Service.Tests.csproj --filter "PipeClientIdentityProviderTests|ControlPipeServerTests"
dotnet test tests/CommMonitor.App.Tests/CommMonitor.App.Tests.csproj --filter "ServiceClientTests|MainViewModelTests|WpfConfirmationServiceTests"
```

Expected: FAIL until both sides speak Control.v2.

- [ ] **Step 3: Implement identity checks and migrate both ends in one commit**

Use `GetNamedPipeClientProcessId`, open the process with query rights, obtain the final process image path by handle, query token user and `TokenStatistics.AuthenticationId`, and SHA-256 the installed image. Compare all fields with protected installer metadata. ACL the pipe to SYSTEM, Administrators and the one authorized SID; deny Network.

Issue a random connection challenge during hello. A confirmation request returns a short-lived nonce bound to connection ID, PID, SID and generation. Clear and overwrite consume it once. `ServiceClient.ClearAsync` keeps the existing stop-subscription/clear/reconnect behavior; `MainViewModel` still asks the human before calling it.

Remove the old `PipeServer`, `PipeContracts`, `PipeFrameCodec` and v1 tests; register only Control.v2 now. Do not leave a build state where WPF expects v1 while service only supports v2.

- [ ] **Step 4: Run all App, Control and existing copy/search/export tests**

Run:

```powershell
dotnet test tests/CommMonitor.App.Tests/CommMonitor.App.Tests.csproj
dotnet test tests/CommMonitor.Core.Tests/CommMonitor.Core.Tests.csproj --filter "CopyFormatterTests|CaptureSearchMatcherTests|CaptureExporterTests"
dotnet test tests/CommMonitor.Service.Tests/CommMonitor.Service.Tests.csproj --filter "ControlPipeServerTests|PipeClientIdentityProviderTests"
```

Expected: PASS; searches, copies and exporters retain their existing semantics.

- [ ] **Step 5: Commit Task 6**

```powershell
git add -- src/CommMonitor.Core/Control src/CommMonitor.Core/Ipc src/CommMonitor.Service/Ipc src/CommMonitor.Service/Program.cs src/CommMonitor.App/Services src/CommMonitor.App/ViewModels/MainViewModel.cs tests/CommMonitor.Service.Tests/Ipc tests/CommMonitor.App.Tests
git commit -m "feat: replace mixed pipe with verified Control v2"
```

---

### Task 7: AI.v1 pipe server, quotas and malformed-input hardening

**Files:**
- Create: `src/CommMonitor.Service/Ipc/AiPipeServer.cs`
- Modify: `src/CommMonitor.Service/Program.cs`
- Create: `tests/CommMonitor.Service.Tests/Ipc/AiPipeServerTests.cs`
- Create: `tests/CommMonitor.Service.Tests/Ipc/AiPipeFuzzTests.cs`

**Interfaces:**
- Produces: 8-instance `Lemon.SerialMonitor.AI.v1` endpoint with only the approved command set.
- Every response uses `{ version, requestId, success, result, error }`; errors use stable `AiError` codes and a correlation ID.

- [ ] **Step 1: Write failing command, ACL and fuzz tests**

Assert the internal transport command registry contains exactly: status, ports, prepare-start, commit-start, recover-lease, pause, resume, stop, sessions, read, wait, export and schema. `recover-lease` is used only by the local vault reconciliation path and does not add a public MCP tool. Assert Clear/Delete/Send/Inject/Replay are absent. Cover authorized SID, unauthorized SID, Network deny, independent 8-instance pool, request/response budgets, one wait per connection, disconnect cancellation, slow reader, oversized length, truncated frame, malformed/deep JSON, very long strings, unknown-field flood, slow byte-at-a-time sender and connection flood.

- [ ] **Step 2: Run AI pipe tests and verify failure**

Run:

```powershell
dotnet test tests/CommMonitor.Service.Tests/CommMonitor.Service.Tests.csproj --filter "AiPipeServerTests|AiPipeFuzzTests"
```

Expected: FAIL because `AiPipeServer` is not registered.

- [ ] **Step 3: Implement the isolated AI server**

Create eight listener loops independent of Control.v2. Resolve the client identity on connection and require the protected authorized SID and current LUID. Parse with the 4-MiB/64-depth codec; validate strings and collections before business calls; map exceptions centrally to stable codes. Run waits on a per-client slot and cancel them on disconnect. Log command, code, duration, SID and correlation ID only—never payload, lease secret, cursor or receipt.

Confirm the mixed server and old tests removed in Task 6 have not been reintroduced; AI handlers must use only the new AI contracts and shared business services.

- [ ] **Step 4: Run the complete managed test suite**

Run:

```powershell
dotnet test CommMonitor.sln --configuration Release --nologo
rg -n "CommMonitor\.Service\.v1|BuiltinUsersSid.*ReadWrite" src tests -g "*.cs"
```

Expected: all managed tests PASS; `rg` finds no listening constant or permissive v1 ACL (historical documentation is outside this source scan).

- [ ] **Step 5: Commit Task 7**

```powershell
git add -- src/CommMonitor.Service/Ipc src/CommMonitor.Service/Program.cs tests/CommMonitor.Service.Tests/Ipc
git commit -m "feat: expose bounded Lemon AI pipe service"
```

---

## Service Plan Completion Gate

Run:

```powershell
dotnet test CommMonitor.sln --configuration Release --nologo
dotnet build src/CommMonitor.Service/CommMonitor.Service.csproj --configuration Release --runtime win-x64 --nologo
git diff --check
```

Expected:

- All prior and new managed tests pass.
- Service builds for win-x64.
- Old v1 is absent from runtime source.
- AI and Control instance pools, ACLs, quotas, lease crash windows, v3 integrity evidence, cursor/receipt recovery and malformed input all have green tests.
- No unrelated dirty file is staged.
