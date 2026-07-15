# CommMonitor Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the first usable Windows 10/11 x64 release that non-invasively captures traffic from already-open COM ports, presents List/Dump/Terminal views, supports fast multi-format copying and search, saves minimal sessions, and ships with safe test-driver installation documentation.

**Architecture:** A KMDF upper class filter duplicates serial Read, Write, and phase-one configuration IOCTLs into a bounded kernel ring without changing the original requests. A .NET 8 LocalSystem service drains the driver, persists events to SQLite, and exposes a versioned named-pipe API; a WPF MVVM client renders virtualized views and performs all copy/search operations from immutable raw events.

**Tech Stack:** C17/KMDF with Visual Studio 2022 and WDK 10.0.26100; C# 12, .NET 8, WPF, `Microsoft.Data.Sqlite`, `System.Management`, xUnit; PowerShell 5.1+; Windows test signing and Driver Verifier.

## Global Constraints

- Target Windows 10/11 x64 only; do not add x86, ARM64, Windows Server, or pre-Windows-10 compatibility.
- Target `net8.0`/`net8.0-windows`; build the driver with WDK `10.0.26100.0` and KMDF.
- Personal-use package uses a locally generated test certificate; never bypass Secure Boot or silently change firmware/security settings.
- Monitoring is read-only: no blocking, mutation, replay, or injection of serial traffic.
- Driver failures must not alter the original request status, payload, length, order, or completion path.
- Driver hot paths must not perform file, registry, network, or user-mode synchronous work.
- Kernel event payload is capped at 4096 bytes and explicitly flagged when truncated.
- Ring overflow drops only monitor copies and increments an observable drop counter.
- The same immutable `CaptureEvent` model feeds views, search, copy, persistence, and export.
- Every view supports direct copy; `Ctrl+C` copies the current selection and `Ctrl+Shift+C` copies raw data.
- Phase-one copy formats are spaced HEX, compact HEX, decoded text, C array, Python bytes, TSV rows, CSV, and JSON.
- Do not reuse CEIWEI code, binaries, assets, trademarks, or private file formats.
- Use TDD for user-mode behavior, build/ABI tests for the driver, and commit after every task.

---

## Planned File Map

### Repository and build

- `CommMonitor.sln`: managed and driver project entry point.
- `global.json`: pins the installed .NET SDK family.
- `Directory.Build.props`: nullable, warnings, deterministic builds, and shared language settings.
- `.gitignore`: Visual Studio, WDK, .NET, test certificate, package, and session artifacts.
- `scripts/Build-All.ps1`: reproducible managed and driver build.

### Shared managed core

- `src/CommMonitor.Core/Models/CaptureEvent.cs`: immutable application event model.
- `src/CommMonitor.Core/Models/CaptureEnums.cs`: event/state/direction enums and flags.
- `src/CommMonitor.Core/Protocol/DriverProtocol.cs`: IOCTL constants and wire header definition.
- `src/CommMonitor.Core/Protocol/DriverEventCodec.cs`: validates and decodes driver batches.
- `src/CommMonitor.Core/Formatting/ByteFormatter.cs`: numeric and source-code byte formats.
- `src/CommMonitor.Core/Formatting/StreamingTextDecoder.cs`: stateful packet-boundary-safe decoding.
- `src/CommMonitor.Core/Copying/CopyFormatter.cs`: single-cell and multi-row clipboard output.
- `src/CommMonitor.Core/Search/CaptureSearchMatcher.cs`: HEX and text matching.
- `src/CommMonitor.Core/Sessions/SessionStore.cs`: SQLite session schema and batched persistence.
- `src/CommMonitor.Core/Export/CsvCaptureExporter.cs`: CSV export.
- `src/CommMonitor.Core/Export/TextCaptureExporter.cs`: readable TXT export.
- `src/CommMonitor.Core/Export/RawCaptureExporter.cs`: exact payload concatenation export.

### Service and Windows integration

- `src/CommMonitor.Service/Capture/ICaptureSource.cs`: driver/fake source seam.
- `src/CommMonitor.Service/Capture/CaptureCoordinator.cs`: capture state machine, batching, persistence, and broadcast.
- `src/CommMonitor.Service/Capture/FakeCaptureSource.cs`: deterministic development source.
- `src/CommMonitor.Service/Driver/NativeMethods.cs`: safe Win32 driver handle and IOCTL P/Invoke.
- `src/CommMonitor.Service/Driver/DriverCaptureSource.cs`: driver configuration and batch reader.
- `src/CommMonitor.Service/Ports/IPortCatalog.cs`: testable port enumeration seam.
- `src/CommMonitor.Service/Ports/WmiPortCatalog.cs`: COM friendly name and PNP ID enumeration.
- `src/CommMonitor.Core/Ipc/PipeContracts.cs`: named-pipe commands, replies, state and batches shared by service and app.
- `src/CommMonitor.Core/Ipc/PipeFrameCodec.cs`: length-prefixed JSON framing shared by service and app.
- `src/CommMonitor.Service/Ipc/PipeServer.cs`: ACL-restricted multi-client server.
- `src/CommMonitor.Service/Program.cs`: console/service host and dependency wiring.

### WPF client

- `src/CommMonitor.App/Infrastructure/ObservableObject.cs`: `INotifyPropertyChanged` base.
- `src/CommMonitor.App/Infrastructure/RelayCommand.cs`: sync/async commands.
- `src/CommMonitor.App/Services/IClipboardService.cs`: testable clipboard abstraction.
- `src/CommMonitor.App/Services/WpfClipboardService.cs`: STA clipboard adapter.
- `src/CommMonitor.App/Services/ServiceClient.cs`: pipe client and event stream.
- `src/CommMonitor.App/ViewModels/MainViewModel.cs`: ports, capture state, search, selection, and copy.
- `src/CommMonitor.App/ViewModels/ListViewModel.cs`: bounded live rows and virtualization input.
- `src/CommMonitor.App/ViewModels/DumpViewModel.cs`: offset/HEX/text dump rows.
- `src/CommMonitor.App/ViewModels/TerminalViewModel.cs`: per-port/direction streaming text.
- `src/CommMonitor.App/MainWindow.xaml`: toolbar, port picker, status bar and three views.
- `src/CommMonitor.App/MainWindow.xaml.cs`: composition only.

### Driver

- `src/CommMonitor.Driver/CommMonitor.Driver.vcxproj`: WDK x64 KMDF project.
- `src/CommMonitor.Driver/CommMonitor.Driver.inx`: primitive driver package metadata.
- `src/CommMonitor.Driver/Protocol.h`: packed ABI, limits, IOCTLs and event types.
- `src/CommMonitor.Driver/Driver.h`: WDF declarations and driver/device/request contexts.
- `src/CommMonitor.Driver/Driver.c`: `DriverEntry`, global context and cleanup.
- `src/CommMonitor.Driver/Device.c`: filter attachment, device-ID hash and I/O queue.
- `src/CommMonitor.Driver/Control.c`: secure global control device and IOCTL handling.
- `src/CommMonitor.Driver/Ring.c`: bounded fixed-slot nonpaged event ring.
- `src/CommMonitor.Driver/Capture.c`: Read/Write/DeviceControl forwarding and completion routines.
- `tests/driver/ProtocolLayoutTests.cpp`: native ABI assertions.

### Scripts, tests and documentation

- `tests/CommMonitor.Core.Tests/*`: protocol, format, copy, search, session and export tests.
- `tests/CommMonitor.Service.Tests/*`: state machine, framing, batching and port hash tests.
- `tests/CommMonitor.App.Tests/*`: view model and clipboard command tests.
- `scripts/Test-SignDriver.ps1`: local certificate creation and embedded/catalog signing.
- `scripts/Install-CommMonitor.ps1`: guarded service/filter installation with registry backup.
- `scripts/Uninstall-CommMonitor.ps1`: exact filter removal and rollback.
- `scripts/Get-CommMonitorStatus.ps1`: diagnostic state report.
- `docs/INSTALL.md`: test mode, Secure Boot, install, restart and verification.
- `docs/USER_GUIDE.md`: phase-one operating and copying guide.
- `docs/TROUBLESHOOTING.md`: driver load, service, COM and recovery procedures.
- `tests/manual/phase1-acceptance.md`: reproducible real-device acceptance record.

---

### Task 1: Managed solution and versioned capture protocol

**Files:**
- Create: `global.json`
- Create: `Directory.Build.props`
- Create: `.gitignore`
- Create: `CommMonitor.sln`
- Create: `src/CommMonitor.Core/CommMonitor.Core.csproj`
- Create: `src/CommMonitor.Core/Models/CaptureEnums.cs`
- Create: `src/CommMonitor.Core/Models/CaptureEvent.cs`
- Create: `src/CommMonitor.Core/Protocol/DriverProtocol.cs`
- Create: `src/CommMonitor.Core/Protocol/DriverEventCodec.cs`
- Create: `tests/CommMonitor.Core.Tests/CommMonitor.Core.Tests.csproj`
- Test: `tests/CommMonitor.Core.Tests/Protocol/DriverEventCodecTests.cs`

**Interfaces:**
- Produces: `CaptureEvent`, `CaptureKind`, `CaptureFlags`, `CaptureState`, `DriverProtocol.HeaderSize`, and `DriverEventCodec.DecodeBatch(ReadOnlySpan<byte>)`.
- `CaptureEvent.Payload` is an owned `ImmutableArray<byte>` so captured bytes remain deeply immutable.
- Wire ABI: little-endian, magic `0x4E4F4D43`, version `1`, packed header size `68`, followed by `PayloadLength` bytes.

- [ ] **Step 1: Scaffold the solution and write the failing codec test**

Run:

```powershell
dotnet new sln -n CommMonitor --format sln
dotnet new classlib -n CommMonitor.Core -o src/CommMonitor.Core -f net8.0
dotnet new xunit -n CommMonitor.Core.Tests -o tests/CommMonitor.Core.Tests -f net8.0
dotnet sln CommMonitor.sln add src/CommMonitor.Core/CommMonitor.Core.csproj
dotnet sln CommMonitor.sln add tests/CommMonitor.Core.Tests/CommMonitor.Core.Tests.csproj
dotnet add tests/CommMonitor.Core.Tests/CommMonitor.Core.Tests.csproj reference src/CommMonitor.Core/CommMonitor.Core.csproj
Remove-Item src/CommMonitor.Core/Class1.cs,tests/CommMonitor.Core.Tests/UnitTest1.cs
```

Remove the generated `Debug|x86` and `Release|x86` solution configurations and their project mappings from `CommMonitor.sln`; retain the supported `Any CPU` and `x64` configurations.

Create `tests/CommMonitor.Core.Tests/Protocol/DriverEventCodecTests.cs`:

```csharp
using System.Buffers.Binary;
using CommMonitor.Core.Models;
using CommMonitor.Core.Protocol;

namespace CommMonitor.Core.Tests.Protocol;

public sealed class DriverEventCodecTests
{
    [Fact]
    public void DecodeBatch_decodes_one_little_endian_event()
    {
        byte[] bytes = new byte[DriverProtocol.HeaderSize + 3];
        BinaryPrimitives.WriteUInt32LittleEndian(bytes, DriverProtocol.Magic);
        BinaryPrimitives.WriteUInt16LittleEndian(bytes.AsSpan(4), DriverProtocol.Version);
        BinaryPrimitives.WriteUInt16LittleEndian(bytes.AsSpan(6), DriverProtocol.HeaderSize);
        BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(8), (uint)bytes.Length);
        BinaryPrimitives.WriteUInt64LittleEndian(bytes.AsSpan(12), 7);
        BinaryPrimitives.WriteInt64LittleEndian(bytes.AsSpan(20), 1234);
        BinaryPrimitives.WriteUInt64LittleEndian(bytes.AsSpan(28), 99);
        BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(36), 42);
        BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(40), (uint)CaptureKind.Write);
        BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(44), 0);
        BinaryPrimitives.WriteInt32LittleEndian(bytes.AsSpan(48), 0);
        BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(52), 3);
        BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(56), 3);
        BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(60), 3);
        BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(64), 0);
        bytes[68] = 0x01; bytes[69] = 0x02; bytes[70] = 0x03;

        CaptureEvent item = Assert.Single(DriverEventCodec.DecodeBatch(bytes));

        Assert.Equal(7L, item.Sequence);
        Assert.Equal(CaptureKind.Write, item.Kind);
        Assert.True(item.Payload.AsSpan().SequenceEqual(new byte[] { 1, 2, 3 }));
    }

    [Fact]
    public void DecodeBatch_rejects_invalid_total_size()
    {
        byte[] bytes = new byte[DriverProtocol.HeaderSize];
        BinaryPrimitives.WriteUInt32LittleEndian(bytes, DriverProtocol.Magic);
        BinaryPrimitives.WriteUInt16LittleEndian(bytes.AsSpan(4), DriverProtocol.Version);
        BinaryPrimitives.WriteUInt16LittleEndian(bytes.AsSpan(6), DriverProtocol.HeaderSize);
        BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(8), 9999);

        Assert.Throws<InvalidDataException>(() => DriverEventCodec.DecodeBatch(bytes));
    }
}
```

Add focused decoder tests for bad magic, bad version, bad header size, oversized payload, oversized batch, trailing bytes, multi-record `TotalSize` advancement, full field mapping, and immutable payload ownership/isolation.

- [ ] **Step 2: Run the test and verify the protocol types are missing**

Run: `dotnet test tests/CommMonitor.Core.Tests/CommMonitor.Core.Tests.csproj --filter DriverEventCodecTests`

Expected: FAIL with compiler errors naming `DriverProtocol`, `CaptureEvent`, or `DriverEventCodec`.

- [ ] **Step 3: Implement the minimal immutable model and strict decoder**

Create `src/CommMonitor.Core/Models/CaptureEnums.cs`:

```csharp
namespace CommMonitor.Core.Models;

public enum CaptureKind : uint { Read = 1, Write = 2, Ioctl = 3, Create = 4, Close = 5, DropNotice = 6, DeviceArrival = 7, DeviceRemoval = 8 }
public enum CaptureState : uint { Stopped = 0, Running = 1, Paused = 2 }
[Flags]
public enum CaptureFlags : uint { None = 0, Truncated = 1, InputPayload = 2, OutputPayload = 4, Synthetic = 8 }
```

Create `src/CommMonitor.Core/Models/CaptureEvent.cs`:

```csharp
using System.Collections.Immutable;

namespace CommMonitor.Core.Models;

public sealed record CaptureEvent(
    long Sequence,
    long QpcTicks,
    ulong DeviceId,
    int ProcessId,
    CaptureKind Kind,
    uint IoctlCode,
    int NtStatus,
    int RequestedLength,
    int CompletedLength,
    CaptureFlags Flags,
    ImmutableArray<byte> Payload)
{
    public string PortName { get; init; } = string.Empty;
    public string ProcessName { get; init; } = string.Empty;
    public DateTimeOffset Timestamp { get; init; }
}
```

Create `src/CommMonitor.Core/Protocol/DriverProtocol.cs`:

```csharp
namespace CommMonitor.Core.Protocol;

public static class DriverProtocol
{
    public const uint Magic = 0x4E4F4D43;
    public const ushort Version = 1;
    public const ushort HeaderSize = 68;
    public const int MaxPayload = 4096;
    public const int MaxBatchBytes = 64 * 1024;
}
```

Create `src/CommMonitor.Core/Protocol/DriverEventCodec.cs` with bounds checks before every slice and a loop that advances by `TotalSize`. Construct `CaptureEvent` from offsets `12,20,28,36,40,44,48,52,56,60,64` and copy the payload into an owned immutable value with `ImmutableArray.CreateRange(payload.ToArray())`. Throw `InvalidDataException` for bad magic, version, header size, total size, payload size, or trailing bytes.

- [ ] **Step 4: Add reproducible build settings and run all managed tests**

Create `global.json`:

```json
{ "sdk": { "version": "10.0.301", "rollForward": "latestPatch", "allowPrerelease": false } }
```

Create `Directory.Build.props`:

```xml
<Project>
  <PropertyGroup>
    <LangVersion>12.0</LangVersion>
    <Nullable>enable</Nullable>
    <ImplicitUsings>enable</ImplicitUsings>
    <TreatWarningsAsErrors>true</TreatWarningsAsErrors>
    <Deterministic>true</Deterministic>
  </PropertyGroup>
</Project>
```

Create `.gitignore` with `.vs/`, `**/bin/`, `**/obj/`, `artifacts/`, `packages/`, `*.pfx`, `*.cer`, `*.cmsession`, `*.etl`, `*.dmp`, and `TestResults/`.

Run: `dotnet test CommMonitor.sln -c Debug`

Expected: PASS, 11 tests.

- [x] **Step 5: Commit**

```powershell
git add CommMonitor.sln global.json Directory.Build.props .gitignore src/CommMonitor.Core tests/CommMonitor.Core.Tests
git commit -m "feat: define capture event wire protocol"
```

---

### Task 2: Byte formatting, streaming decoding, search and copy

**Files:**
- Create: `src/CommMonitor.Core/Formatting/ByteFormatter.cs`
- Create: `src/CommMonitor.Core/Formatting/StreamingTextDecoder.cs`
- Create: `src/CommMonitor.Core/Copying/CopyOptions.cs`
- Create: `src/CommMonitor.Core/Copying/CopyFormatter.cs`
- Create: `src/CommMonitor.Core/Search/CaptureSearchMatcher.cs`
- Test: `tests/CommMonitor.Core.Tests/Formatting/ByteFormatterTests.cs`
- Test: `tests/CommMonitor.Core.Tests/Formatting/StreamingTextDecoderTests.cs`
- Test: `tests/CommMonitor.Core.Tests/Copying/CopyFormatterTests.cs`
- Test: `tests/CommMonitor.Core.Tests/Search/CaptureSearchMatcherTests.cs`

**Interfaces:**
- Produces: `ByteFormatter.Format(ReadOnlySpan<byte>, ByteFormat)`, `StreamingTextDecoder.Decode`, `CopyFormatter.Format`, and `CaptureSearchMatcher.IsMatch`.
- Consumes: immutable `CaptureEvent` from Task 1.

- [ ] **Step 1: Write failing tests for every phase-one copy format and split UTF-8**

Use fixed payload `01 03 00 FF` and assert exact outputs:

```csharp
Assert.Equal("01 03 00 FF", ByteFormatter.Format(data, ByteFormat.HexSpaced));
Assert.Equal("010300FF", ByteFormatter.Format(data, ByteFormat.HexCompact));
Assert.Equal("new byte[] { 0x01, 0x03, 0x00, 0xFF }", ByteFormatter.Format(data, ByteFormat.CArray));
Assert.Equal("b'\\x01\\x03\\x00\\xff'", ByteFormatter.Format(data, ByteFormat.PythonBytes));
```

For `StreamingTextDecoder`, feed UTF-8 bytes for `串` in two calls and assert the first call returns empty and the second returns `串`. For row copying, create two events and assert TSV contains one header and two CRLF-terminated rows. For HEX search, assert pattern `03 ?? FF` matches `01 03 00 FF`.

- [ ] **Step 2: Run focused tests and verify missing formatter/search types**

Run: `dotnet test tests/CommMonitor.Core.Tests/CommMonitor.Core.Tests.csproj --filter "FullyQualifiedName~Formatting|FullyQualifiedName~Copying|FullyQualifiedName~Search"`

Expected: FAIL at compile time for the new types.

- [ ] **Step 3: Implement formatters and stateful decoding**

Define:

```csharp
public enum ByteFormat { HexSpaced, HexCompact, Decimal, Octal, Binary, CArray, PythonBytes }
public enum CopyFormat { HexSpaced, HexCompact, Text, CArray, PythonBytes, Tsv, Csv, Json }
public sealed record CopyOptions(CopyFormat Format, bool IncludeSequence, bool IncludeTimestamp, bool IncludePort, bool IncludeDirection, bool IncludeProcess);
```

`ByteFormatter` must use `Convert.ToHexString`, invariant culture, uppercase HEX except Python bytes, and return an empty string for an empty span. `StreamingTextDecoder` owns an `Encoding.GetDecoder()` instance, calls `Convert` with `flush: false`, and exposes `Reset()`.

`CopyFormatter.Format(IReadOnlyList<CaptureEvent>, CopyOptions, Encoding)` must read `Payload` directly, escape CSV according to RFC 4180, serialize JSON with `System.Text.Json`, and use CRLF for table formats. `CaptureSearchMatcher` parses tokens `00`-`FF` and `??`; invalid HEX patterns return a validation error rather than silently matching.

- [ ] **Step 4: Run the complete Core suite**

Run: `dotnet test tests/CommMonitor.Core.Tests/CommMonitor.Core.Tests.csproj -c Debug`

Expected: PASS, including exact copy strings and the split UTF-8 test.

- [ ] **Step 5: Commit**

```powershell
git add src/CommMonitor.Core tests/CommMonitor.Core.Tests
git commit -m "feat: add reliable copy and search formatting"
```

---

### Task 3: SQLite sessions and phase-one exporters

**Files:**
- Create: `src/CommMonitor.Core/Sessions/ISessionStore.cs`
- Create: `src/CommMonitor.Core/Sessions/SessionStore.cs`
- Create: `src/CommMonitor.Core/Export/ICaptureExporter.cs`
- Create: `src/CommMonitor.Core/Export/CsvCaptureExporter.cs`
- Create: `src/CommMonitor.Core/Export/TextCaptureExporter.cs`
- Create: `src/CommMonitor.Core/Export/RawCaptureExporter.cs`
- Test: `tests/CommMonitor.Core.Tests/Sessions/SessionStoreTests.cs`
- Test: `tests/CommMonitor.Core.Tests/Export/CaptureExporterTests.cs`

**Interfaces:**
- Produces: `ISessionStore.InitializeAsync`, `AppendAsync`, `ReadAfterAsync`, `ClearAsync`, and `ICaptureExporter.ExportAsync`.
- Consumes: `CaptureEvent`, `ByteFormatter`, and copy-safe raw payloads from Tasks 1-2.

- [ ] **Step 1: Add SQLite and write a failing round-trip test**

Run: `dotnet add src/CommMonitor.Core/CommMonitor.Core.csproj package Microsoft.Data.Sqlite --version 8.0.22`

The test must create a unique temporary `.cmsession`, initialize it, append two events in one call, reopen a second `SessionStore`, read after sequence `0`, and assert every scalar plus each payload byte. A second test calls `ClearAsync` and asserts no rows remain.

- [ ] **Step 2: Run the session tests and verify the store is missing**

Run: `dotnet test tests/CommMonitor.Core.Tests/CommMonitor.Core.Tests.csproj --filter SessionStoreTests`

Expected: FAIL with missing `SessionStore`/`ISessionStore`.

- [ ] **Step 3: Implement the schema and batched transactions**

Use this schema exactly:

```sql
PRAGMA journal_mode=WAL;
PRAGMA synchronous=NORMAL;
CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS events(
 sequence INTEGER PRIMARY KEY,
 qpc_ticks INTEGER NOT NULL,
 timestamp_utc TEXT NOT NULL,
 device_id INTEGER NOT NULL,
 port_name TEXT NOT NULL,
 process_id INTEGER NOT NULL,
 process_name TEXT NOT NULL,
 kind INTEGER NOT NULL,
 ioctl_code INTEGER NOT NULL,
 nt_status INTEGER NOT NULL,
 requested_length INTEGER NOT NULL,
 completed_length INTEGER NOT NULL,
 flags INTEGER NOT NULL,
 payload BLOB NOT NULL
);
CREATE INDEX IF NOT EXISTS ix_events_time ON events(timestamp_utc);
CREATE INDEX IF NOT EXISTS ix_events_device ON events(device_id, sequence);
```

Write metadata `schema_version=1`. Use one prepared INSERT command inside one transaction for each batch. Preserve all 64 device-ID bits by writing `unchecked((long)event.DeviceId)` and reading with `unchecked((ulong)reader.GetInt64(...))`. `ReadAfterAsync(long sequence, int limit, CancellationToken)` orders by sequence and rejects limits outside `1..10000`.

- [ ] **Step 4: Add exact CSV, TXT and raw export tests and implementations**

CSV uses UTF-8 with BOM, a fixed header, invariant integers and spaced HEX. TXT uses `[yyyy-MM-dd HH:mm:ss.fffffff] COMx TX 01 02` lines. Raw export concatenates only Read/Write payload bytes in sequence order without metadata. Run the entire Core test project and expect PASS.

- [ ] **Step 5: Commit**

```powershell
git add src/CommMonitor.Core tests/CommMonitor.Core.Tests
git commit -m "feat: persist and export capture sessions"
```

---

### Task 4: Capture coordinator and deterministic fake source

**Files:**
- Create: `src/CommMonitor.Service/CommMonitor.Service.csproj`
- Create: `src/CommMonitor.Service/Capture/ICaptureSource.cs`
- Create: `src/CommMonitor.Service/Capture/CaptureSelection.cs`
- Create: `src/CommMonitor.Service/Capture/CaptureCoordinator.cs`
- Create: `src/CommMonitor.Service/Capture/FakeCaptureSource.cs`
- Create: `tests/CommMonitor.Service.Tests/CommMonitor.Service.Tests.csproj`
- Test: `tests/CommMonitor.Service.Tests/Capture/CaptureCoordinatorTests.cs`

**Interfaces:**
- Produces: `ICaptureSource.ConfigureAsync`, `ReadAllAsync`, `CaptureCoordinator.StartAsync/PauseAsync/ResumeAsync/StopAsync/ClearAsync`, and `EventsPublished`.
- Consumes: `CaptureEvent`, `CaptureState`, and `ISessionStore`.

- [ ] **Step 1: Scaffold service/tests and write state-machine tests**

Run:

```powershell
dotnet new worker -n CommMonitor.Service -o src/CommMonitor.Service -f net8.0
dotnet new xunit -n CommMonitor.Service.Tests -o tests/CommMonitor.Service.Tests -f net8.0
dotnet sln CommMonitor.sln add src/CommMonitor.Service/CommMonitor.Service.csproj tests/CommMonitor.Service.Tests/CommMonitor.Service.Tests.csproj
dotnet add src/CommMonitor.Service/CommMonitor.Service.csproj reference src/CommMonitor.Core/CommMonitor.Core.csproj
dotnet add tests/CommMonitor.Service.Tests/CommMonitor.Service.Tests.csproj reference src/CommMonitor.Service/CommMonitor.Service.csproj
```

Tests must assert: stopped→running→paused→running→stopped; Pause while stopped throws `InvalidOperationException`; Stop does not clear persisted events; Clear is accepted only while stopped; published batches preserve event sequence.

- [ ] **Step 2: Run tests and verify coordinator types are missing**

Run: `dotnet test tests/CommMonitor.Service.Tests/CommMonitor.Service.Tests.csproj --filter CaptureCoordinatorTests`

Expected: FAIL at compile time.

- [ ] **Step 3: Implement interfaces and the coordinator loop**

Use these signatures:

```csharp
public interface ICaptureSource : IAsyncDisposable
{
    ValueTask ConfigureAsync(CaptureState state, IReadOnlySet<ulong> deviceIds, CancellationToken cancellationToken);
    IAsyncEnumerable<CaptureEvent> ReadAllAsync(CancellationToken cancellationToken);
}

public sealed record CaptureSelection(IReadOnlySet<ulong> DeviceIds, string SessionPath);
```

`CaptureCoordinator` owns one cancellation token source and one reader task. It buffers up to 64 events or 50 ms, calls `ISessionStore.AppendAsync` before publishing an immutable copy, and serializes state transitions with `SemaphoreSlim`. Stopping cancels and awaits the reader but does not call `ClearAsync`.

`FakeCaptureSource` uses a `Channel<CaptureEvent>` and exposes `EmitAsync` only for development/tests.

- [ ] **Step 4: Run service and all managed tests**

Run: `dotnet test CommMonitor.sln -c Debug`

Expected: PASS with no unobserved task or disposal failures.

- [ ] **Step 5: Commit**

```powershell
git add CommMonitor.sln src/CommMonitor.Service tests/CommMonitor.Service.Tests
git commit -m "feat: coordinate capture state and batching"
```

---

### Task 5: Named-pipe protocol and Windows service host

**Files:**
- Create: `src/CommMonitor.Core/Ipc/PipeContracts.cs`
- Create: `src/CommMonitor.Core/Ipc/PipeFrameCodec.cs`
- Create: `src/CommMonitor.Service/Ipc/PipeServer.cs`
- Modify: `src/CommMonitor.Service/Program.cs`
- Modify: `src/CommMonitor.Service/CommMonitor.Service.csproj`
- Test: `tests/CommMonitor.Service.Tests/Ipc/PipeFrameCodecTests.cs`
- Test: `tests/CommMonitor.Service.Tests/Ipc/PipeServerTests.cs`

**Interfaces:**
- Produces: protocol version `1`, `PipeCommand`, `PipeReply`, `PipeEventBatch`, and `PipeServer` on pipe name `CommMonitor.Service.v1`.
- Consumes: `CaptureCoordinator` and immutable event batches.

- [ ] **Step 1: Write failing fragmented-frame and oversize-frame tests**

Frame format is four-byte little-endian JSON byte length followed by one UTF-8 JSON document. Test a stream that returns one byte per read, a zero-length frame, a `16 MiB + 1` length, malformed JSON, and a valid `Start` command containing two device IDs.

- [ ] **Step 2: Run focused tests and verify IPC types are missing**

Run: `dotnet test tests/CommMonitor.Service.Tests/CommMonitor.Service.Tests.csproj --filter "FullyQualifiedName~Ipc"`

Expected: FAIL at compile time.

- [ ] **Step 3: Implement strict framing and contracts**

Define command names `ListPorts`, `Start`, `Pause`, `Resume`, `Stop`, `Clear`, `Subscribe`, and `Export`. Every request contains a nonempty `RequestId`; every reply echoes it. Reject negative/zero/over-16-MiB lengths before allocating. Serialize with camelCase and string enums.

Create the server with `PipeTransmissionMode.Byte`, asynchronous options, four instances, and an ACL granting full control to LocalSystem/Administrators and read/write to Builtin Users. A disconnected client must only cancel that client session.

- [ ] **Step 4: Wire console/service modes and run tests**

Add `Microsoft.Extensions.Hosting.WindowsServices` version `8.0.1` and `System.IO.Pipes.AccessControl` version `5.0.0`. `Program.cs` uses `WindowsServiceHelpers.IsWindowsService()` to select service lifetime; `--console` forces interactive logging. Register `CaptureCoordinator`, `PipeServer`, and `FakeCaptureSource` until Task 11 replaces the source.

Run: `dotnet test CommMonitor.sln -c Debug`

Expected: PASS. Then run `dotnet run --project src/CommMonitor.Service -- --console`, connect the IPC test client, and stop with Ctrl+C without an exception.

- [ ] **Step 5: Commit**

```powershell
git add src/CommMonitor.Core src/CommMonitor.Service tests/CommMonitor.Service.Tests
git commit -m "feat: expose capture service over named pipes"
```

---

### Task 6: WPF shell, List view and copy commands

**Files:**
- Create: `src/CommMonitor.App/CommMonitor.App.csproj`
- Create: `src/CommMonitor.App/Infrastructure/ObservableObject.cs`
- Create: `src/CommMonitor.App/Infrastructure/RelayCommand.cs`
- Create: `src/CommMonitor.App/Services/IClipboardService.cs`
- Create: `src/CommMonitor.App/Services/WpfClipboardService.cs`
- Create: `src/CommMonitor.App/Services/ServiceClient.cs`
- Create: `src/CommMonitor.App/ViewModels/MainViewModel.cs`
- Create: `src/CommMonitor.App/ViewModels/ListViewModel.cs`
- Create: `src/CommMonitor.App/MainWindow.xaml`
- Modify: `src/CommMonitor.App/MainWindow.xaml.cs`
- Create: `tests/CommMonitor.App.Tests/CommMonitor.App.Tests.csproj`
- Test: `tests/CommMonitor.App.Tests/ViewModels/MainViewModelTests.cs`

**Interfaces:**
- Produces: `MainViewModel`, `SelectedEvents`, capture commands, search properties, `CopyCommand`, and `CopyRawCommand`.
- Consumes: named-pipe contracts and `CopyFormatter`.

- [ ] **Step 1: Scaffold WPF/tests and write failing copy-command tests**

Run:

```powershell
dotnet new wpf -n CommMonitor.App -o src/CommMonitor.App -f net8.0
dotnet new xunit -n CommMonitor.App.Tests -o tests/CommMonitor.App.Tests -f net8.0
dotnet sln CommMonitor.sln add src/CommMonitor.App/CommMonitor.App.csproj tests/CommMonitor.App.Tests/CommMonitor.App.Tests.csproj
dotnet add src/CommMonitor.App/CommMonitor.App.csproj reference src/CommMonitor.Core/CommMonitor.Core.csproj
dotnet add tests/CommMonitor.App.Tests/CommMonitor.App.Tests.csproj reference src/CommMonitor.App/CommMonitor.App.csproj
```

With a fake clipboard and fake service client, assert `Ctrl+C` copies the selected rows using the selected format, raw copy emits only spaced HEX, Start is disabled with no selected port, and Stop leaves rows intact.

- [ ] **Step 2: Run App tests and verify view models are missing**

Run: `dotnet test tests/CommMonitor.App.Tests/CommMonitor.App.Tests.csproj --filter MainViewModelTests`

Expected: FAIL at compile time.

- [ ] **Step 3: Implement MVVM infrastructure and view models**

`ObservableObject` implements `SetProperty<T>`. `RelayCommand` and `AsyncRelayCommand` implement `ICommand`, disable reentry, and surface exceptions through a view-model error property. `ListViewModel` exposes `ObservableCollection<CaptureEvent>` but retains at most 100,000 live rows; the full session remains in SQLite.

`MainViewModel` owns selected ports/events, `CopyOptions`, search text/type, and state. Commands call `ServiceClient`; copy always calls `CopyFormatter` using immutable selected events.

- [ ] **Step 4: Build a virtualized Chinese UI and verify keyboard bindings**

`MainWindow.xaml` must include:

- Port checklist and refresh button.
- Start, Pause, Resume, Stop, Clear, Open, Save, Export controls.
- A prominent `复制数据` split/dropdown area.
- Search box with previous/next buttons.
- A `TabControl` with `列表`, `Dump`, and `终端` tabs.
- A List `DataGrid` with sequence, time, process, COM, direction, operation, status, length, HEX and text columns.
- Row virtualization and recycling enabled.
- Input bindings for `Ctrl+C` and `Ctrl+Shift+C`.
- Status bar with service state, driver state, event count and drop count.

Run: `dotnet test CommMonitor.sln -c Debug` and `dotnet build src/CommMonitor.App/CommMonitor.App.csproj -c Debug`.

Expected: PASS/build success with zero warnings.

- [ ] **Step 5: Commit**

```powershell
git add CommMonitor.sln src/CommMonitor.App tests/CommMonitor.App.Tests
git commit -m "feat: add list view and direct clipboard workflow"
```

---

### Task 7: Dump and Terminal views with packet-safe text

**Files:**
- Create: `src/CommMonitor.App/ViewModels/DumpRow.cs`
- Create: `src/CommMonitor.App/ViewModels/DumpViewModel.cs`
- Create: `src/CommMonitor.App/ViewModels/TerminalSegment.cs`
- Create: `src/CommMonitor.App/ViewModels/TerminalViewModel.cs`
- Modify: `src/CommMonitor.App/ViewModels/MainViewModel.cs`
- Modify: `src/CommMonitor.App/MainWindow.xaml`
- Test: `tests/CommMonitor.App.Tests/ViewModels/DumpViewModelTests.cs`
- Test: `tests/CommMonitor.App.Tests/ViewModels/TerminalViewModelTests.cs`

**Interfaces:**
- Produces: dump rows with 16-byte offsets and terminal segments keyed by `(DeviceId, CaptureKind)`.
- Consumes: `CaptureEvent`, `ByteFormatter`, `StreamingTextDecoder`, and the shared selection model.

- [ ] **Step 1: Write failing dump and split-character terminal tests**

Dump a 20-byte payload and assert two rows with offsets `00000000` and `00000010`, exact HEX spacing, and dots for nonprintable bytes. Feed a UTF-8 character split across two Read events and assert Terminal produces one character only after the second event. Assert Read and Write have separate decoder state and colors.

- [ ] **Step 2: Run tests and verify view models are missing**

Run: `dotnet test tests/CommMonitor.App.Tests/CommMonitor.App.Tests.csproj --filter "FullyQualifiedName~DumpViewModel|FullyQualifiedName~TerminalViewModel"`

Expected: FAIL at compile time.

- [ ] **Step 3: Implement the two view models**

`DumpViewModel.SelectEvent(CaptureEvent?)` rebuilds rows from that event only in phase one and never mutates payloads. `TerminalViewModel.Append(CaptureEvent)` accepts Read/Write only, maintains a decoder dictionary per device/direction/encoding, and caps visible text at 2 MiB by removing complete oldest segments.

- [ ] **Step 4: Bind views and cross-view selection**

Selecting a List event updates Dump immediately and highlights the associated Terminal segment when present. Terminal exposes encoding choices ANSI, UTF-7, UTF-8, UTF-16LE, and UTF-16BE, plus time/port/direction prefixes, wrap and auto-scroll. Run all App tests and build the WPF project.

- [ ] **Step 5: Commit**

```powershell
git add src/CommMonitor.App tests/CommMonitor.App.Tests
git commit -m "feat: add dump and streaming terminal views"
```

---

### Task 8: KMDF filter scaffold and ABI build gate

**Files:**
- Create: `src/CommMonitor.Driver/CommMonitor.Driver.vcxproj`
- Create: `src/CommMonitor.Driver/CommMonitor.Driver.inx`
- Create: `src/CommMonitor.Driver/Protocol.h`
- Create: `src/CommMonitor.Driver/Driver.h`
- Create: `src/CommMonitor.Driver/Driver.c`
- Create: `src/CommMonitor.Driver/Device.c`
- Create: `tests/driver/ProtocolLayoutTests.cpp`
- Create: `scripts/Build-Driver.ps1`

**Interfaces:**
- Produces: x64 `CommMonitor.Driver.sys`, packed `CMON_EVENT_HEADER`, filter `EvtDeviceAdd`, and fixed IOCTL values.
- ABI must exactly match Task 1: 68-byte header, magic/version/offsets, 4096-byte maximum payload.

- [ ] **Step 1: Write the native ABI test before the header exists**

Create `tests/driver/ProtocolLayoutTests.cpp`:

```cpp
#include <cstddef>
#include <cstdint>
#include "../../src/CommMonitor.Driver/Protocol.h"
static_assert(sizeof(CMON_EVENT_HEADER) == 68);
static_assert(offsetof(CMON_EVENT_HEADER, Sequence) == 12);
static_assert(offsetof(CMON_EVENT_HEADER, PayloadLength) == 60);
static_assert(CMON_MAGIC == 0x4E4F4D43u);
static_assert(CMON_PROTOCOL_VERSION == 1u);
int main() { return 0; }
```

Run it through `VsDevCmd.bat` and `cl /std:c++17 /W4 /WX /EHsc tests\driver\ProtocolLayoutTests.cpp`.

Expected: FAIL with C1083 because `Protocol.h` does not exist.

- [ ] **Step 2: Define the packed native protocol**

`Protocol.h` includes `ntddk.h` in kernel builds and `Windows.h`/`winioctl.h` in the native ABI test, then uses `uint16_t`, `uint32_t`, `uint64_t` and `int64_t` fields with `#pragma pack(push, 1)`. It defines the exact 68-byte `CMON_EVENT_HEADER`, `CMON_EVENT_SLOT` with `uint8_t Payload[4096]`, event/state/flag constants, and these buffered IOCTLs:

```c
#define IOCTL_CMON_GET_VERSION CTL_CODE(FILE_DEVICE_UNKNOWN, 0x800, METHOD_BUFFERED, FILE_READ_ACCESS | FILE_WRITE_ACCESS)
#define IOCTL_CMON_SET_CONFIG  CTL_CODE(FILE_DEVICE_UNKNOWN, 0x801, METHOD_BUFFERED, FILE_READ_ACCESS | FILE_WRITE_ACCESS)
#define IOCTL_CMON_GET_BATCH   CTL_CODE(FILE_DEVICE_UNKNOWN, 0x802, METHOD_BUFFERED, FILE_READ_ACCESS | FILE_WRITE_ACCESS)
#define IOCTL_CMON_GET_STATS   CTL_CODE(FILE_DEVICE_UNKNOWN, 0x803, METHOD_BUFFERED, FILE_READ_ACCESS | FILE_WRITE_ACCESS)
```

Re-run the native test. Expected: compiler exit code 0.

- [ ] **Step 3: Create the WDK project and transparent filter skeleton**

The `.vcxproj` has x64 Debug/Release, `ConfigurationType=Driver`, `DriverType=KMDF`, `PlatformToolset=WindowsKernelModeDriver10.0`, `WindowsTargetPlatformVersion=10.0.26100.0`, `/W4 /WX`, Spectre mitigation, Control Flow Guard, and no precompiled header. `DriverEntry` creates `WDFDRIVER`; `EvtDeviceAdd` calls `WdfFdoInitSetFilter`, creates the WDF device and a parallel default queue whose initial `EvtIoDefault` uses `WdfRequestSend(...SEND_AND_FORGET)`.

The INX is a System-class primitive driver package that installs service `CommMonitorFilter`, `ServiceType=1`, `StartType=3`, `ErrorControl=1`, destination DIRID 13 and KMDF library `$KMDFVERSION$`. Class-filter registration remains in the guarded install script, not the INF.

- [ ] **Step 4: Build, validate INF and add the driver project to the solution**

`scripts/Build-Driver.ps1` enters VS 2022 BuildTools through `VsDevCmd.bat`, runs MSBuild for x64, then runs WDK `InfVerif.exe /w` on the generated INF. Run:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/Build-Driver.ps1 -Configuration Debug
```

Expected: `CommMonitor.Driver.sys` produced under `artifacts/driver/Debug/x64` and InfVerif exit code 0.

- [ ] **Step 5: Commit**

```powershell
git add src/CommMonitor.Driver tests/driver scripts/Build-Driver.ps1 CommMonitor.sln
git commit -m "feat: scaffold transparent KMDF serial filter"
```

---

### Task 9: Bounded kernel ring and secure control device

**Files:**
- Create: `src/CommMonitor.Driver/Ring.c`
- Create: `src/CommMonitor.Driver/Control.c`
- Modify: `src/CommMonitor.Driver/Driver.h`
- Modify: `src/CommMonitor.Driver/Driver.c`
- Modify: `src/CommMonitor.Driver/CommMonitor.Driver.vcxproj`
- Create: `tests/driver/RingModelTests.cpp`

**Interfaces:**
- Produces: `CmonRingPush`, `CmonRingPopBatch`, `CmonCreateControlDevice`, `\\.\Global\CommMonitorFilter`, and version/config/batch/stats IOCTLs.
- Consumes: native protocol from Task 8.

- [ ] **Step 1: Write a portable ring-model test for wrap and drop semantics**

The test pushes sequence `1,2,3` into capacity two, asserts stored order `1,2`, drop count `1`, pops one, pushes `4`, and asserts remaining order `2,4`. Keep the model in the test file and use its assertions as the contract for the kernel implementation.

- [ ] **Step 2: Run the test, then implement a fixed-slot nonpaged ring**

`DRIVER_CONTEXT` owns 2048 `CMON_EVENT_SLOT` entries allocated with `ExAllocatePool2(POOL_FLAG_NON_PAGED, ..., 'noMC')`, head/tail/count, `ULONGLONG Dropped`, `ULONGLONG Sequence`, a WDF spin lock, capture state, and up to 64 selected device hashes. Free the allocation in driver cleanup.

`CmonRingPush` validates `PayloadLength <= 4096` before acquiring the spin lock. Full rings increment `Dropped` and return `STATUS_BUFFER_OVERFLOW`; no caller propagates that status to serial I/O. `CmonRingPopBatch` writes complete variable-length wire events only and never splits one across output buffers.

- [ ] **Step 3: Implement the control device and IOCTL validation**

Create one WDF control device named `\Device\CommMonitorFilter`, DOS link `\DosDevices\Global\CommMonitorFilter`, with SDDL granting Generic All to System and Builtin Administrators only. `GET_VERSION` returns protocol version/header/max payload; `SET_CONFIG` validates state and device count; `GET_BATCH` requires at least one header of output space; `GET_STATS` returns queued/dropped/sequence/state.

Every invalid input completes the control request with `STATUS_INVALID_PARAMETER`; serial requests do not use this queue.

- [ ] **Step 4: Build with Code Analysis and run native tests**

Run the native tests with `/W4 /WX`, build Debug x64, then run MSBuild `/p:RunCodeAnalysis=true`. Expected: zero warnings/errors and the ring-model process exits 0.

- [ ] **Step 5: Commit**

```powershell
git add src/CommMonitor.Driver tests/driver
git commit -m "feat: add bounded driver event transport"
```

---

### Task 10: Read, Write and configuration IOCTL capture

**Files:**
- Create: `src/CommMonitor.Driver/Capture.c`
- Modify: `src/CommMonitor.Driver/Driver.h`
- Modify: `src/CommMonitor.Driver/Device.c`
- Modify: `src/CommMonitor.Driver/CommMonitor.Driver.vcxproj`
- Create: `tests/driver/DeviceIdHashTests.cpp`

**Interfaces:**
- Produces: capture callbacks for Read/Write/DeviceControl, FNV-1a uppercase UTF-16 device hash, request completion forwarding, truncation/drop flags.
- Consumes: ring/control state from Task 9.

- [ ] **Step 1: Write device-hash golden tests**

Use 64-bit FNV-1a offset `14695981039346656037` and prime `1099511628211`; uppercase each UTF-16 code unit before mixing its low and high byte. Assert C++ and C# golden values for `USB\\VID_1A86&PID_7523\\5&1234&0&2` match. Add the same golden assertion to `CommMonitor.Service.Tests` for the later WMI mapping.

- [ ] **Step 2: Implement device identity and selected-device checks**

After `WdfDeviceCreate`, query `DevicePropertyDeviceInstanceId`, hash it, and store it in `DEVICE_CONTEXT`. If the property cannot be queried, set hash zero and do not capture that device. Capture only when state is Running and the hash occurs in the configured device list.

- [ ] **Step 3: Implement safe forwarding/completion**

Create a small `REQUEST_CONTEXT` containing start QPC, PID, kind, IOCTL, requested length and optional `WDFMEMORY` write/input snapshot capped at 4096 bytes. For captured requests:

1. Format with current request type.
2. Set one completion routine.
3. Send to the default lower I/O target.
4. If send fails synchronously, complete with `WdfRequestGetStatus`.
5. In completion, copy successful Read/output bytes or the saved Write/input bytes into a local `CMON_EVENT_SLOT`, push it, then complete with the exact lower status and information.

If allocating monitoring context/memory fails, forward the request with `SEND_AND_FORGET` and generate no event.

- [ ] **Step 4: Capture the phase-one IOCTL set and verify builds**

Capture set/get baud rate, line control, handflow, timeouts, chars, DTR, RTS and purge using WDK `ntddser.h` constants. SET operations store input payload; GET operations store successful output payload. Other IOCTLs forward unchanged and are added in phase two.

Run native tests, driver build, InfVerif and Code Analysis. Expected: all pass with zero warnings.

- [ ] **Step 5: Commit**

```powershell
git add src/CommMonitor.Driver tests/driver tests/CommMonitor.Service.Tests
git commit -m "feat: capture serial reads writes and configuration"
```

---

### Task 11: Real driver source, COM catalog and service integration

**Files:**
- Create: `src/CommMonitor.Service/Driver/NativeMethods.cs`
- Create: `src/CommMonitor.Service/Driver/DriverCaptureSource.cs`
- Create: `src/CommMonitor.Service/Ports/IPortCatalog.cs`
- Create: `src/CommMonitor.Service/Ports/WmiPortCatalog.cs`
- Modify: `src/CommMonitor.Service/Program.cs`
- Modify: `src/CommMonitor.Service/CommMonitor.Service.csproj`
- Test: `tests/CommMonitor.Service.Tests/Driver/DriverCaptureSourceTests.cs`
- Test: `tests/CommMonitor.Service.Tests/Ports/WmiPortCatalogParsingTests.cs`

**Interfaces:**
- Produces: real `ICaptureSource`, `PortInfo(Name, FriendlyName, PnpDeviceId, DeviceIdHash)`, and driver status mapping.
- Consumes: Task 8-10 IOCTLs and Task 1 decoder.

- [x] **Step 1: Write failing tests with an injectable device-control seam**

Tests feed a valid batch, a truncated batch, protocol version mismatch, zero events, cancellation and `ERROR_FILE_NOT_FOUND`. Assert valid events publish, invalid batches fault with a user-facing driver protocol error, cancellation exits cleanly, and missing driver reports `DriverUnavailable` without crashing the service.

- [x] **Step 2: Implement safe Win32 interop**

Open `\\.\Global\CommMonitorFilter` with `CreateFile`, read/write sharing, `OPEN_EXISTING`, overlapped I/O, and `SafeFileHandle`. Wrap `DeviceIoControl` in an interface so tests never call the kernel. Use pinned/owned buffers and always validate `bytesReturned <= buffer.Length` before decoding.

- [x] **Step 3: Implement driver polling and port mapping**

`DriverCaptureSource.ConfigureAsync` sends state plus sorted distinct device hashes. `ReadAllAsync` requests 64 KiB batches; an empty batch delays 10 ms with cancellation. Convert kernel QPC to `DateTimeOffset` using one service startup calibration pair.

Add `System.Management` version `8.0.0`. Query `Win32_PnPEntity` where `Name` contains `(COM`, parse the final parenthesized `COM[0-9]+`, use `PNPDeviceID`, and compute the exact Task 10 hash. Sort numeric COM names naturally.

- [x] **Step 4: Select real/fake source explicitly and run tests**

`--fake-source` enables fake data only in console development. Windows service mode always registers `DriverCaptureSource`; missing driver is visible through pipe status and does not silently fall back to fake data.

Run: `dotnet test CommMonitor.sln -c Debug`

Expected: all managed tests PASS.

- [ ] **Step 5: Commit**

```powershell
git add src/CommMonitor.Service tests/CommMonitor.Service.Tests
git commit -m "feat: connect capture service to serial filter"
```

---

### Task 12: Build, test-sign, install, recover and document Phase 1

**Files:**
- Create: `scripts/Build-All.ps1`
- Create: `scripts/Test-SignDriver.ps1`
- Create: `scripts/Install-CommMonitor.ps1`
- Create: `scripts/Uninstall-CommMonitor.ps1`
- Create: `scripts/Get-CommMonitorStatus.ps1`
- Create: `docs/INSTALL.md`
- Create: `docs/USER_GUIDE.md`
- Create: `docs/TROUBLESHOOTING.md`
- Create: `tests/manual/phase1-acceptance.md`
- Modify: `README.md`

**Interfaces:**
- Produces: reproducible `artifacts/phase1`, guarded local installation, exact rollback, Chinese operator documentation and signed acceptance evidence.
- Consumes: all preceding projects and artifacts.

- [ ] **Step 1: Write Pester-style safety assertions before install logic**

Extract pure helpers for `Add-MultiStringValue`, `Remove-MultiStringValue`, admin detection and backup serialization. Tests must prove adding preserves existing filters/order and avoids duplicates; removing deletes only `CommMonitorFilter`; restore reproduces the exact original array; non-admin install exits before writing.

- [ ] **Step 2: Implement reproducible build and test signing**

`Build-All.ps1` runs `dotnet restore`, `dotnet test -c Release`, publishes App/Service self-contained `win-x64`, builds the Release driver, and places results under `artifacts/phase1/{app,service,driver,scripts,docs}`.

`Test-SignDriver.ps1` creates or reuses a non-exported private-key code-signing certificate named `Lemon Serial Monitor Local Test Driver`, exports only `.cer`, signs SYS and CAT with SHA-256 using the WDK 26100 SignTool, and verifies both signatures. It never commits PFX/CER files.

- [ ] **Step 3: Implement guarded install, status and exact uninstall**

Use Ports class key `HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4D36E978-E325-11CE-BFC1-08002BE10318}`. Before any change, save its existing `UpperFilters`, service state, driver target and timestamp to `%ProgramData%\CommMonitor\install-backup.json`.

Install must:

1. Require elevation and x64 Windows 10/11.
2. Detect Secure Boot and current test-signing state; stop with explicit instructions instead of changing Secure Boot.
3. Import the public test certificate into LocalMachine Root and TrustedPublisher only after confirmation.
4. Copy the driver, create the kernel service, append `CommMonitorFilter` without replacing other filters, install the LocalSystem service, and copy the client.
5. Require reboot before reporting the filter active.

Uninstall must stop the user-mode service, remove only `CommMonitorFilter`, delete its services/files or schedule locked deletion after reboot, and offer exact backup restoration. Status reports TestSigning, SecureBoot, certificate, filter order, kernel/user services, control device and app paths.

- [ ] **Step 4: Write complete Chinese phase-one documentation and execute acceptance**

`INSTALL.md` contains prerequisites, Secure Boot/test mode, build, install, reboot, verify, update, uninstall and restoring normal boot. `USER_GUIDE.md` covers creating a session, multi-port capture, states, List/Dump/Terminal, encoding, HEX/text search, all eight copy formats, save/open/export and data-loss indicators. `TROUBLESHOOTING.md` maps exact symptoms to status commands and recovery steps.

Execute `tests/manual/phase1-acceptance.md` on Windows 11 x64 with one virtual COM pair and one USB-to-serial adapter. Record OS build, adapter ID, baud, source/sink SHA-256 data hashes, driver/service status, drop count, and each pass/fail checkbox. Run Driver Verifier for only `CommMonitor.Driver.sys`, then disable it after the test.

- [ ] **Step 5: Run the final verification and commit**

Run:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/Build-All.ps1 -Configuration Release
git diff --check
git status --short
```

Expected: all automated tests PASS, driver build/InfVerif/signature verification PASS, artifacts exist, manual results contain no unresolved failure, and only intentional source/docs changes remain.

Commit:

```powershell
git add README.md scripts docs tests/manual
git commit -m "docs: package and document CommMonitor phase one"
```

---

## Phase-One Completion Gate

Do not declare Phase 1 complete until all statements are evidenced:

- The target application keeps its COM handle and requires no port change while monitoring starts/stops.
- Captured TX/RX bytes match independent sender/receiver logs byte-for-byte for the non-truncated range.
- App/service crash or shutdown does not interrupt the target serial communication.
- Kernel overflow/truncation is visible and never reported as a complete capture.
- List, Dump and Terminal render live data without unbounded UI object growth.
- Every phase-one copy format has an automated exact-string test and works from keyboard shortcuts.
- Session reopen and CSV/TXT/raw exports pass round-trip tests.
- Install/uninstall preserves unrelated Ports class filters and includes a tested rollback path.
- Driver build, InfVerif, Code Analysis, targeted Driver Verifier, managed tests and manual device acceptance pass.
- Chinese install, usage and troubleshooting documents match the shipped scripts/UI.

## Follow-on Plans

After this gate, write separate plans for:

1. Phase 2: remaining IRPs/IOCTLs, Line view, complete view linking, filters, display customization, HTML/JSON exports, real-time redirection and large-session optimization.
2. Phase 3: Modbus RTU/ASCII frame reassembly and analysis, installer UI, compatibility/stress matrix, screenshots and full final documentation.
