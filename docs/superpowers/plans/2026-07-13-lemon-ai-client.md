# Lemon AI Client Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `Lemon.SerialMonitor.AI.exe` as a normal-user MCP stdio server and JSON/JSONL CLI that safely controls its own captures and reads durable Lemon serial-monitor sessions.

**Architecture:** One executable contains a bounded AI-pipe client, DPAPI CurrentUser lease vault, shared command handlers, a JSON CLI front end, and an MCP stdio front end. CLI and MCP use the same typed service client and validation, so neither path can expose commands absent from `Lemon.SerialMonitor.AI.v1`. MCP uses the official stable C# SDK and writes protocol messages only to stdout; every diagnostic goes to stderr.

**Tech Stack:** C# 12, `net8.0-windows`, win-x64, official `ModelContextProtocol` 1.4.1, `Microsoft.Extensions.Hosting` 10.0.7, Windows DPAPI CurrentUser, named pipes, `System.Text.Json`, xUnit.

## Global Constraints

- This plan begins only after the Lemon AI Service completion gate passes.
- Pin stable `ModelContextProtocol` 1.4.1; do not use the 2.0 preview line.
- Use stdio only; do not add HTTP, WebSocket, localhost ports, CORS or browser access.
- Run as the interactive standard user; never request elevation and never open COM, driver or SQLite files.
- No Clear, Delete, Send, Inject, Replay, arbitrary path, overwrite or device-configuration command may exist in CLI or MCP.
- MCP and CLI must expose the same stable DTOs, errors, filtering, integrity and quotas.
- MCP stdout contains only valid MCP JSON-RPC; CLI stdout contains exactly JSON or JSONL; all diagnostics use stderr.
- Lease secrets are DPAPI CurrentUser-protected in `%LocalAppData%\LemonSerialMonitor\AI\leases.json` and never printed or logged.
- Start uses prepare → atomic vault write → ACK/commit; no active capture may exist without recoverable owner state.
- Preserve existing source namespaces, service/driver identifiers and `%ProgramData%\CommMonitor` data root.
- Stage only task-owned files; do not stage artifacts, credentials, real capture data or existing unrelated changes.

---

## Planned File Map

### AI executable

- `src/Lemon.SerialMonitor.AI/Lemon.SerialMonitor.AI.csproj`: Win-x64 console executable and pinned packages.
- `src/Lemon.SerialMonitor.AI/Program.cs`: mode selection, DI and stable exit-code boundary.
- `src/Lemon.SerialMonitor.AI/Transport/IAiServiceClient.cs`: typed service API.
- `src/Lemon.SerialMonitor.AI/Transport/AiServiceClient.cs`: correlated bounded named-pipe client.
- `src/Lemon.SerialMonitor.AI/Security/ILeaseVault.cs`: lease persistence contract.
- `src/Lemon.SerialMonitor.AI/Security/DpapiLeaseVault.cs`: atomic DPAPI CurrentUser vault.
- `src/Lemon.SerialMonitor.AI/Application/LemonAiCommands.cs`: shared status/capture/session/read/wait/export operations.
- `src/Lemon.SerialMonitor.AI/Cli/CliApplication.cs`: argument parsing and JSON/JSONL output.
- `src/Lemon.SerialMonitor.AI/Cli/CliExitCodes.cs`: stable process exit codes.
- `src/Lemon.SerialMonitor.AI/Mcp/LemonMcpTools.cs`: approved MCP tools only.
- `src/Lemon.SerialMonitor.AI/Mcp/LemonMcpResources.cs`: schema/document resources.
- `src/Lemon.SerialMonitor.AI/Mcp/McpApplication.cs`: official SDK stdio host.

### Tests and examples

- `tests/Lemon.SerialMonitor.AI.Tests/Lemon.SerialMonitor.AI.Tests.csproj`
- `tests/Lemon.SerialMonitor.AI.Tests/Transport/AiServiceClientTests.cs`
- `tests/Lemon.SerialMonitor.AI.Tests/Security/DpapiLeaseVaultTests.cs`
- `tests/Lemon.SerialMonitor.AI.Tests/Application/LemonAiCommandsTests.cs`
- `tests/Lemon.SerialMonitor.AI.Tests/Cli/CliApplicationTests.cs`
- `tests/Lemon.SerialMonitor.AI.Tests/Mcp/McpApplicationTests.cs`
- `tests/Lemon.SerialMonitor.AI.Tests/Integration/AiExecutableTests.cs`
- `examples/ai/python/read_session.py`
- `examples/ai/csharp/LemonAiExample.csproj`
- `examples/ai/csharp/Program.cs`
- `examples/ai/powershell/Read-LemonSession.ps1`
- `examples/ai/mcp-config.json`
- `docs/AI_INTEGRATION.md`
- `docs/AI_API_REFERENCE.md`

---

### Task 1: AI executable and typed pipe client

**Files:**
- Create: `src/Lemon.SerialMonitor.AI/Lemon.SerialMonitor.AI.csproj`
- Create: `src/Lemon.SerialMonitor.AI/Program.cs`
- Create: `src/Lemon.SerialMonitor.AI/Transport/IAiServiceClient.cs`
- Create: `src/Lemon.SerialMonitor.AI/Transport/AiServiceClient.cs`
- Create: `tests/Lemon.SerialMonitor.AI.Tests/Lemon.SerialMonitor.AI.Tests.csproj`
- Create: `tests/Lemon.SerialMonitor.AI.Tests/Transport/AiServiceClientTests.cs`
- Modify: `CommMonitor.sln`

**Interfaces:**
- Produces: `IAiServiceClient` methods for status, ports, prepare/commit/recover/pause/resume/stop, sessions, read, wait, export and schema.
- Every request has a random request ID and protocol version 1; replies must match both before their result is accepted.
- One command connection is serialized; each wait uses a separately cancellable connection so it cannot block ordinary commands.

- [ ] **Step 1: Scaffold projects and write failing transport tests**

Create the project with exact metadata:

```xml
<PropertyGroup>
  <OutputType>Exe</OutputType>
  <TargetFramework>net8.0-windows</TargetFramework>
  <RuntimeIdentifier>win-x64</RuntimeIdentifier>
  <PlatformTarget>x64</PlatformTarget>
  <AssemblyName>Lemon.SerialMonitor.AI</AssemblyName>
  <Product>Lemon串口监控 AI 接口</Product>
  <Title>Lemon串口监控 AI 接口</Title>
  <Nullable>enable</Nullable>
  <ImplicitUsings>enable</ImplicitUsings>
</PropertyGroup>
```

Reference `CommMonitor.Core`. The test project references the AI project and xUnit versions already used by the solution. Add both projects to `CommMonitor.sln`.

Tests must cover connection, request correlation, version mismatch, structured error preservation, command timeout, wait cancellation, partial/oversized frames, reconnect after pipe failure, stdout independence and disposal.

- [ ] **Step 2: Run the transport tests and verify failure**

Run:

```powershell
dotnet test tests/Lemon.SerialMonitor.AI.Tests/Lemon.SerialMonitor.AI.Tests.csproj --filter AiServiceClientTests
```

Expected: FAIL because the client implementation and Program entry point do not exist.

- [ ] **Step 3: Implement the service client**

Define the typed surface:

```csharp
public interface IAiServiceClient : IAsyncDisposable
{
    Task<AiStatusDto> GetStatusAsync(CancellationToken cancellationToken);
    Task<IReadOnlyList<AiPortDto>> ListPortsAsync(CancellationToken cancellationToken);
    Task<PreparedCaptureDto> PrepareStartAsync(PrepareCaptureRequest request, CancellationToken cancellationToken);
    Task<ActiveCaptureDto> CommitStartAsync(CommitCaptureRequest request, CancellationToken cancellationToken);
    Task<ActiveCaptureDto> RecoverLeaseAsync(RecoverLeaseRequest request, CancellationToken cancellationToken);
    Task<AiStatusDto> PauseAsync(LeaseProof request, CancellationToken cancellationToken);
    Task<AiStatusDto> ResumeAsync(LeaseProof request, CancellationToken cancellationToken);
    Task<AiStatusDto> StopAsync(LeaseProof request, CancellationToken cancellationToken);
    Task<AiSessionPage> ListSessionsAsync(ListSessionsRequest request, CancellationToken cancellationToken);
    Task<AiEventPage> ReadEventsAsync(ReadEventsRequest request, CancellationToken cancellationToken);
    Task<AiEventPage> WaitEventsAsync(WaitEventsRequest request, CancellationToken cancellationToken);
    Task<AiExportDto> ExportAsync(ExportSessionRequest request, CancellationToken cancellationToken);
    Task<AiSchemaDto> GetSchemaAsync(CancellationToken cancellationToken);
}
```

Use `AiProtocol.PipeName`, `LengthPrefixedJsonCodec`, a five-second ordinary command timeout and the server-defined 30-second wait plus five seconds transport margin. Convert error envelopes to one `LemonAiException` without flattening code/retryable/correlation/details.

- [ ] **Step 4: Run transport tests and build the executable**

Run:

```powershell
dotnet test tests/Lemon.SerialMonitor.AI.Tests/Lemon.SerialMonitor.AI.Tests.csproj --filter AiServiceClientTests
dotnet build src/Lemon.SerialMonitor.AI/Lemon.SerialMonitor.AI.csproj --configuration Release --runtime win-x64 --nologo
```

Expected: PASS and `Lemon.SerialMonitor.AI.exe` is produced under the Release win-x64 output.

- [ ] **Step 5: Commit Task 1**

```powershell
git add -- CommMonitor.sln src/Lemon.SerialMonitor.AI tests/Lemon.SerialMonitor.AI.Tests/Lemon.SerialMonitor.AI.Tests.csproj tests/Lemon.SerialMonitor.AI.Tests/Transport
git commit -m "feat: add Lemon AI pipe client"
```

---

### Task 2: DPAPI lease vault and crash-safe shared commands

**Files:**
- Modify: `src/Lemon.SerialMonitor.AI/Lemon.SerialMonitor.AI.csproj`
- Create: `src/Lemon.SerialMonitor.AI/Security/ILeaseVault.cs`
- Create: `src/Lemon.SerialMonitor.AI/Security/DpapiLeaseVault.cs`
- Create: `src/Lemon.SerialMonitor.AI/Application/LemonAiCommands.cs`
- Create: `tests/Lemon.SerialMonitor.AI.Tests/Security/DpapiLeaseVaultTests.cs`
- Create: `tests/Lemon.SerialMonitor.AI.Tests/Application/LemonAiCommandsTests.cs`

**Interfaces:**
- Produces: `ILeaseVault.ReadAsync/WritePendingAsync/ActivateAsync/RemoveAsync` and shared command methods used by both CLI and MCP.
- Vault records contain lease ID, secret, reservation ID, clientInstanceId, generation, state and timestamps; the JSON file on disk contains only DPAPI ciphertext plus format metadata.

- [ ] **Step 1: Write failing vault and two-phase Start tests**

Use a temporary LocalAppData root and a fake protector. Test owner-only ACL on Windows, atomic replace, no plaintext secret, corrupt ciphertext, concurrent writers, expired pending cleanup, prepare failure, disk failure before ACK, reservation expiry, ACK then driver failure, reply loss after commit, service restart, recovery rotation, replay rejection and Stop cleanup.

```csharp
ActiveCaptureDto active = await commands.PrepareAndStartAsync(request, ct);
Assert.Equal(
    ["prepare", "vault.write-pending", "commit", "vault.activate"],
    recorder.Steps);
Assert.DoesNotContain(active.LeaseSecret, await File.ReadAllTextAsync(vaultPath));
```

- [ ] **Step 2: Run focused tests and verify failure**

Run:

```powershell
dotnet test tests/Lemon.SerialMonitor.AI.Tests/Lemon.SerialMonitor.AI.Tests.csproj --filter "DpapiLeaseVaultTests|LemonAiCommandsTests"
```

Expected: FAIL because vault and shared commands do not exist.

- [ ] **Step 3: Implement atomic DPAPI persistence and reconciliation**

Add `System.Security.Cryptography.ProtectedData` version `8.0.0`. Use `%LocalAppData%\LemonSerialMonitor\AI\leases.json`. Serialize a versioned vault, protect bytes with `DataProtectionScope.CurrentUser`, write to a random sibling file, flush the file handle, atomically replace/move, then apply an ACL granting the current SID and SYSTEM only. Never log serialized records.

`LemonAiCommands.StartCaptureAsync` must execute prepare → `WritePendingAsync` → commit → `ActivateAsync`. On startup, reconcile each pending/active entry with service status: remove expired reservations, recover committed active captures, rotate the secret and persist the replacement before returning it to a caller.

- [ ] **Step 4: Run vault/command tests including crash matrix**

Run:

```powershell
dotnet test tests/Lemon.SerialMonitor.AI.Tests/Lemon.SerialMonitor.AI.Tests.csproj --filter "DpapiLeaseVaultTests|LemonAiCommandsTests"
```

Expected: PASS for every failure point without an orphan active capture or plaintext secret.

- [ ] **Step 5: Commit Task 2**

```powershell
git add -- src/Lemon.SerialMonitor.AI/Lemon.SerialMonitor.AI.csproj src/Lemon.SerialMonitor.AI/Security src/Lemon.SerialMonitor.AI/Application tests/Lemon.SerialMonitor.AI.Tests/Security tests/Lemon.SerialMonitor.AI.Tests/Application
git commit -m "feat: persist recoverable AI capture leases"
```

---

### Task 3: JSON and JSONL command-line interface

**Files:**
- Create: `src/Lemon.SerialMonitor.AI/Cli/CliApplication.cs`
- Create: `src/Lemon.SerialMonitor.AI/Cli/CliExitCodes.cs`
- Modify: `src/Lemon.SerialMonitor.AI/Program.cs`
- Create: `tests/Lemon.SerialMonitor.AI.Tests/Cli/CliApplicationTests.cs`

**Interfaces:**
- Produces the documented CLI commands and stable exit codes: 0 success, 2 invalid arguments, 3 access/protocol, 4 service unavailable, 5 conflict/lease, 6 integrity/data, 7 timeout/cancel, 10 unexpected.
- stdout has one JSON document except `events wait --jsonl`, which emits one event per line followed by one `_page` metadata line.

- [ ] **Step 1: Write failing argument/output tests**

Test these exact invocations:

```text
status --json
ports --json
capture start --device-id 0123456789ABCDEF --label bench --json
capture pause --lease-id <id> --json
capture resume --lease-id <id> --json
capture stop --lease-id <id> --json
sessions list --limit 100 --json
events read --session-id <id> --cursor <cursor> --limit 100 --json
events wait --session-id <id> --cursor <cursor> --timeout-seconds 30 --jsonl
export --session-id <id> --format jsonl --json
schema --json
```

Assert invalid device IDs, limits, formats, timeout and conflicting cursor/seek options exit 2 without contacting the service. Capture stdout/stderr separately; force errors and assert stdout remains valid JSON while diagnostics appear only on stderr. For start, recovery, pause, resume and stop, assert neither stdout nor stderr contains a lease secret or DPAPI vault record.

- [ ] **Step 2: Run CLI tests and verify failure**

Run:

```powershell
dotnet test tests/Lemon.SerialMonitor.AI.Tests/Lemon.SerialMonitor.AI.Tests.csproj --filter CliApplicationTests
```

Expected: FAIL because CLI parsing and output do not exist.

- [ ] **Step 3: Implement deterministic parsing and output**

Implement a small explicit parser—no shell expansion and no arbitrary path options. Parse 64-bit IDs from fixed hexadecimal strings; page limit is 1–1000; wait is 1–30 seconds; export formats are `json`, `jsonl`, `csv`, `txt`, and `raw`. Serialize with the shared AI JSON options. For JSONL wait, emit serialized `AiEventDto` lines and finish with:

```json
{"_page":{"nextCursor":"...","resumeReceipt":"...","hasMore":false,"scannedThroughSequence":"42","integrity":{}}}
```

Map `LemonAiException.Code` to stable exit codes and include the full structured error as JSON without a stack trace.

- [ ] **Step 4: Run CLI tests and executable smoke checks**

Run:

```powershell
dotnet test tests/Lemon.SerialMonitor.AI.Tests/Lemon.SerialMonitor.AI.Tests.csproj --filter CliApplicationTests
dotnet run --project src/Lemon.SerialMonitor.AI/Lemon.SerialMonitor.AI.csproj -- schema --json
```

Expected: tests PASS; smoke output is one valid JSON document even when the Windows service is unavailable.

- [ ] **Step 5: Commit Task 3**

```powershell
git add -- src/Lemon.SerialMonitor.AI/Cli src/Lemon.SerialMonitor.AI/Program.cs tests/Lemon.SerialMonitor.AI.Tests/Cli
git commit -m "feat: add Lemon AI JSON command line"
```

---

### Task 4: Official MCP stdio tools and resources

**Files:**
- Modify: `src/Lemon.SerialMonitor.AI/Lemon.SerialMonitor.AI.csproj`
- Create: `src/Lemon.SerialMonitor.AI/Mcp/LemonMcpTools.cs`
- Create: `src/Lemon.SerialMonitor.AI/Mcp/LemonMcpResources.cs`
- Create: `src/Lemon.SerialMonitor.AI/Mcp/McpApplication.cs`
- Modify: `src/Lemon.SerialMonitor.AI/Program.cs`
- Create: `tests/Lemon.SerialMonitor.AI.Tests/Mcp/McpApplicationTests.cs`

**Interfaces:**
- Produces exactly 11 MCP tools: `lemon_get_status`, `lemon_list_ports`, `lemon_start_capture`, `lemon_pause_capture`, `lemon_resume_capture`, `lemon_stop_capture`, `lemon_list_sessions`, `lemon_read_events`, `lemon_wait_events`, `lemon_export_session`, `lemon_get_schema`.
- Produces four text resources: `lemon://docs/ai-interface`, `lemon://schema/capture-event`, `lemon://schema/errors`, `lemon://schema/integrity`.

- [ ] **Step 1: Add pinned packages and write failing MCP discovery tests**

Add:

```xml
<PackageReference Include="ModelContextProtocol" Version="1.4.1" />
<PackageReference Include="Microsoft.Extensions.Hosting" Version="10.0.7" />
```

Using the official `McpClient` with in-memory or stdio transport, assert exact tool/resource names, descriptions and generated JSON schemas. Assert dangerous names/arguments are absent, all capture-tool results omit lease secrets and vault records, tool exceptions return structured AI JSON with `IsError=true`, cancellation reaches wait, no network listener exists, and a forced logger message appears on stderr but not stdout.

- [ ] **Step 2: Run MCP tests and verify failure**

Run:

```powershell
dotnet test tests/Lemon.SerialMonitor.AI.Tests/Lemon.SerialMonitor.AI.Tests.csproj --filter McpApplicationTests
```

Expected: FAIL because MCP types are not registered.

- [ ] **Step 3: Implement the stdio host and approved surface**

Configure the official SDK exactly as follows:

```csharp
HostApplicationBuilder builder = Host.CreateApplicationBuilder(args);
builder.Logging.AddConsole(options =>
    options.LogToStandardErrorThreshold = LogLevel.Trace);
builder.Services.AddSingleton<LemonAiCommands>();
builder.Services
    .AddMcpServer()
    .WithStdioServerTransport()
    .WithTools<LemonMcpTools>()
    .WithResources<LemonMcpResources>();
await builder.Build().RunAsync(cancellationToken);
```

Mark tool/resource classes with the SDK attributes and `[Description]`. Return JSON text serialized from the same DTOs as CLI. No args and the explicit `mcp` arg both start MCP; any other args route to CLI.

- [ ] **Step 4: Run MCP, CLI and stdout purity tests**

Run:

```powershell
dotnet test tests/Lemon.SerialMonitor.AI.Tests/Lemon.SerialMonitor.AI.Tests.csproj --filter "McpApplicationTests|CliApplicationTests"
```

Expected: PASS; captured MCP stdout parses as JSON-RPC only.

- [ ] **Step 5: Commit Task 4**

```powershell
git add -- src/Lemon.SerialMonitor.AI/Lemon.SerialMonitor.AI.csproj src/Lemon.SerialMonitor.AI/Mcp src/Lemon.SerialMonitor.AI/Program.cs tests/Lemon.SerialMonitor.AI.Tests/Mcp
git commit -m "feat: expose Lemon serial data over MCP stdio"
```

---

### Task 5: AI examples, documentation and executable integration tests

**Files:**
- Create: `examples/ai/python/read_session.py`
- Create: `examples/ai/csharp/LemonAiExample.csproj`
- Create: `examples/ai/csharp/Program.cs`
- Create: `examples/ai/powershell/Read-LemonSession.ps1`
- Create: `examples/ai/mcp-config.json`
- Create: `docs/AI_INTEGRATION.md`
- Create: `docs/AI_API_REFERENCE.md`
- Create: `tests/Lemon.SerialMonitor.AI.Tests/Integration/AiExecutableTests.cs`

**Interfaces:**
- Examples invoke only the installed CLI or MCP stdio command; they contain no machine-specific path, token, private data or direct database access.
- Documentation defines every DTO field, error, cursor, receipt, integrity warning and lease lifecycle.

- [ ] **Step 1: Write failing example/document integration tests**

Test that each example uses `Lemon.SerialMonitor.AI.exe`, every referenced command/tool exists, `mcp-config.json` is valid JSON with the documented install-directory token `%LEMON_INSTALL_DIR%`, Python passes `py_compile`, PowerShell parses without AST errors, C# builds, Markdown links resolve, and examples contain none of `CommMonitor.Service.v1`, `http://localhost`, PFX/private-key text or absolute developer paths.

- [ ] **Step 2: Run integration tests and verify failure**

Run:

```powershell
dotnet test tests/Lemon.SerialMonitor.AI.Tests/Lemon.SerialMonitor.AI.Tests.csproj --filter AiExecutableTests
```

Expected: FAIL because examples and documents do not exist.

- [ ] **Step 3: Write runnable examples and complete AI reference**

The Python and PowerShell examples run `sessions list`, take the first returned session ID, page `events read` until `hasMore=false`, preserve `nextCursor` and `resumeReceipt`, decode `payloadBase64`, and stop with a warning if integrity is incomplete. The C# example uses `System.Diagnostics.Process` with redirected stdout/stderr and deserializes the same JSON.

`AI_INTEGRATION.md` includes copyable MCP config and CLI quick start. `AI_API_REFERENCE.md` lists all 11 tools, four resources, CLI commands, filters, DTOs, 4-MiB/1000/30-second quotas, lease vault, seven-day cursor, 90-day receipt, explicit unverified seek, legacy v2 warning and the no-send/no-delete boundary.

- [ ] **Step 4: Run examples, integration and all managed tests**

Run:

```powershell
python -m py_compile examples/ai/python/read_session.py
dotnet build examples/ai/csharp/LemonAiExample.csproj --configuration Release --nologo
dotnet test CommMonitor.sln --configuration Release --nologo
```

Expected: all commands PASS; no example requires a real COM port for syntax/integration validation.

- [ ] **Step 5: Commit Task 5**

```powershell
git add -- examples/ai docs/AI_INTEGRATION.md docs/AI_API_REFERENCE.md tests/Lemon.SerialMonitor.AI.Tests/Integration
git commit -m "docs: add Lemon AI integration examples"
```

---

## AI Client Plan Completion Gate

Run:

```powershell
dotnet test CommMonitor.sln --configuration Release --nologo
dotnet publish src/Lemon.SerialMonitor.AI/Lemon.SerialMonitor.AI.csproj --configuration Release --runtime win-x64 --self-contained true --output artifacts/ai-smoke --nologo
& 'artifacts/ai-smoke/Lemon.SerialMonitor.AI.exe' schema --json | ConvertFrom-Json | Out-Null
rg -n "Clear|Delete|Send|Inject|Replay|http://localhost|CommMonitor\.Service\.v1" src/Lemon.SerialMonitor.AI examples/ai docs/AI_*.md
```

Expected:

- All managed tests pass.
- The self-contained AI executable starts and emits valid JSON.
- MCP and CLI tool sets match and contain no dangerous operation.
- stdout purity, DPAPI vault, two-phase Start crash recovery, cursors/receipts, examples and documentation are verified.
- `rg` has no dangerous command implementation; explanatory documentation references must be manually distinguished from implementation strings.
