# Task 10 Report: Transparent Read, Write, and serial configuration capture

## Status

Task 10 implements fail-open capture for serial Read, Write, and the selected
phase-one serial configuration IOCTLs. Captured requests preserve the lower
driver's completion status and information exactly, while monitor preparation,
allocation, buffer-access, and ring-overflow failures affect only the monitor
copy. The driver hashes each device instance id, takes a coherent selected/
running snapshot under the existing spin lock, and stores bounded events in the
Task 9 ring.

No driver was installed, loaded, registered, started, or deployed. No system
driver, service, class-filter, registry, signing, or boot state was changed.

## TDD evidence

### Native device-id and capture-core RED/GREEN

The portable native tests were added before `CaptureCore.h` or its production
implementation existed. Both `/std:c++17 /W4 /WX` compiles failed for the
intended missing production feature:

```text
DeviceIdHashTests.cpp(1): fatal error C1083: cannot open include file:
  ../../src/CommMonitor.Driver/CaptureCore.h
NATIVE_DEVICE_ID_HASH_RED_EXIT_CODE=2

CaptureCoreTests.cpp(1): fatal error C1083: cannot open include file:
  ../../src/CommMonitor.Driver/CaptureCore.h
NATIVE_CAPTURE_CORE_RED_EXIT_CODE=2
```

`CaptureCore.c` and `CaptureCore.h` were then implemented and linked directly
into both tests. The golden device instance id is:

```text
USB\VID_1A86&PID_7523\5&1234&0&2
FNV-1a uppercase UTF-16LE = 0x01D944A5154C9461
decimal = 133213139801773153
```

The core tests exercise:

- upper/lower ASCII device-id equivalence and low-byte/high-byte FNV order;
- selected + Running decisions, including zero/unselected/stopped/paused;
- input/output/unsupported classification for all captured serial IOCTLs;
- payload boundaries 0, 4096, and 4097;
- short accessible input/output buffers being marked truncated;
- failed Read/GET output producing no payload;
- successful output using the safe minimum of completed, requested, and
  accessible lengths;
- exact lower NTSTATUS and completed-length metadata;
- 32-bit wire length representability on x64;
- an owned Write/SET snapshot remaining unchanged after the source buffer is
  modified.

Two further contracts were driven through their own RED/GREEN cycles. The x64
wire-length test first failed because the helper was missing, then passed after
the production helper was added:

```text
C3861: CmonCaptureLengthIsRepresentable: identifier not found
WIRE_LENGTH_RED_EXIT_CODE=2
WIRE_LENGTH_GREEN_EXIT_CODE=0
```

The owned-snapshot test likewise failed before the production copy helper
existed, then passed after `Capture.c` used that same helper for input and
output copies:

```text
C3861: CmonCaptureCopyPayload: identifier not found
WRITE_SNAPSHOT_RED_EXIT_CODE=2
WRITE_SNAPSHOT_GREEN_EXIT_CODE=0
```

Final native result:

```text
NATIVE_DEVICE_ID_HASH_EXIT_CODE=0
NATIVE_CAPTURE_CORE_EXIT_CODE=0
```

### Managed device-id hash RED/GREEN

The Service golden test was added before the reusable Task 11 hasher. Its
first build failed for the missing production namespace/type:

```text
CS0234: namespace CommMonitor.Service.Ports does not exist
MANAGED_DEVICE_ID_HASH_RED_EXIT_CODE=1
```

`CommMonitor.Service.Ports.DeviceIdHasher` now applies invariant uppercase to
each UTF-16 code unit and mixes the low byte followed by the high byte inside
an explicit unchecked FNV-1a block. Both uppercase and lowercase golden cases
pass:

```text
DeviceIdHasherTests: passed 2, failed 0
MANAGED_DEVICE_ID_HASH_GREEN_EXIT_CODE=0
```

## Device identity and selection

- `CommMonitorEvtDeviceAdd` queries the instance id immediately after
  `WdfDeviceCreate`, before publishing the parallel I/O queue.
- The plan's suggested `DevicePropertyDeviceInstanceId` enumerator does not
  exist in the actual WDK 10.0.26100 `DEVICE_REGISTRY_PROPERTY` enum. The
  supported unified-property equivalent is used instead:
  `WdfDeviceAllocAndQueryPropertyEx` with `DEVPKEY_Device_InstanceId`.
  KMDF 1.15 provides this Universal DDI. The returned property must have type
  `DEVPROP_TYPE_STRING`, an even byte length, at least one non-NUL code unit,
  and an in-range terminating NUL.
- Query, type, shape, or termination failure stores hash zero and still lets
  DeviceAdd succeed. Hash zero can never be selected, so that device remains
  transparent and uncaptured.
- Kernel hashing uses `RtlUpcaseUnicodeChar` for each UTF-16 code unit and
  then mixes low byte followed by high byte with offset
  `14695981039346656037` and prime `1099511628211`.
- Capture reads Running state, selected count, and selected hashes under the
  existing WDF spin lock. The immutable per-device hash is compared by the
  production core. No allocation, request API, ring push, or request
  completion occurs while this lock is held.

## Transparent request forwarding

The PnP device keeps one parallel default queue with four paths:

- `CmonEvtIoRead` for Read capture;
- `CmonEvtIoWrite` for Write capture;
- `CmonEvtIoSerialDeviceControl` for selected configuration IOCTLs;
- `CommMonitorEvtIoDefault` for every other request.

The control device still uses the distinct `CmonEvtIoDeviceControl` callback;
serial requests cannot enter the control queue.

Unselected, stopped, unsupported, over-32-bit, context-allocation,
event-allocation, input-retrieval, and snapshot-preparation paths format the
request using its current type and forward with SEND_AND_FORGET. A fallback
send failure completes only with `WdfRequestGetStatus`, matching the existing
transparent skeleton.

Captured requests use a small dynamically attached `REQUEST_CONTEXT`; it does
not contain a payload array. A request-parented nonpaged `WDFMEMORY` allocation
holds one event slot and doubles as the pre-send input snapshot. Reused request
contexts are explicitly reset. Any stale child memory is deleted before reuse.
The child memory is explicitly deleted and the handle cleared on every
preparation failure, synchronous send failure, and completion path, even
though request parenting provides a final framework backstop.

For a prepared capture:

1. Write/SET input is retrieved and copied before the request is sent.
2. The current request type is formatted and one completion routine is set.
3. `WdfRequestSend(..., WDF_NO_SEND_OPTIONS)` sends to the lower target.
4. TRUE returns immediately, because completion can run inline; no request
   context is touched after that return.
5. FALSE deletes monitor storage and completes with
   `WdfRequestGetStatus`.
6. Completion reads only `Params->IoStatus.Status` and
   `Params->IoStatus.Information`. It never trusts `Params->Parameters.*`.
7. Successful Read/GET output is retrieved from the request before the filter
   completes it. Failed Read/GET events carry zero payload.
8. Ring push is best-effort and occurs outside the selection lock.
9. Monitor storage is deleted, then
   `WdfRequestCompleteWithInformation(Request, lowerStatus,
   lowerInformation)` preserves the exact lower completion.

If requested length or lower information cannot be represented by the
32-bit wire ABI, no event is emitted. The original request is still forwarded
or completed with the untouched pointer-sized information; the monitor never
casts or saturates a value and then claims it is exact.

## Payload and IOCTL scope

Every copied payload is bounded to 4096 bytes. A payload is marked truncated
when the requested/completed data exceeds 4096 or when less data is safely
accessible than the request/completion claims. A failed output operation has
the output-direction flag but zero payload. Write and SET input remains the
pre-send snapshot even if the lower request later fails.

Captured input IOCTLs:

- `IOCTL_SERIAL_SET_BAUD_RATE`
- `IOCTL_SERIAL_SET_LINE_CONTROL`
- `IOCTL_SERIAL_SET_HANDFLOW`
- `IOCTL_SERIAL_SET_TIMEOUTS`
- `IOCTL_SERIAL_SET_CHARS`
- `IOCTL_SERIAL_SET_DTR` / `IOCTL_SERIAL_CLR_DTR`
- `IOCTL_SERIAL_SET_RTS` / `IOCTL_SERIAL_CLR_RTS`
- `IOCTL_SERIAL_PURGE`

Captured output IOCTLs:

- `IOCTL_SERIAL_GET_BAUD_RATE`
- `IOCTL_SERIAL_GET_LINE_CONTROL`
- `IOCTL_SERIAL_GET_HANDFLOW`
- `IOCTL_SERIAL_GET_TIMEOUTS`
- `IOCTL_SERIAL_GET_CHARS`
- `IOCTL_SERIAL_GET_DTRRTS`

All other device-control requests remain uncaptured and transparent.

## Final verification

### Automatic native gates

Every `Build-Driver.ps1` invocation now builds and runs five isolated x64
native gates under `/W4 /WX`: protocol layout, ring lifecycle/model,
production transport core, production device-id hash core, and production
capture core.

```text
NATIVE_PROTOCOL_LAYOUT_EXIT_CODE=0
NATIVE_RING_MODEL_EXIT_CODE=0
NATIVE_TRANSPORT_CORE_EXIT_CODE=0
NATIVE_DEVICE_ID_HASH_EXIT_CODE=0
NATIVE_CAPTURE_CORE_EXIT_CODE=0
```

### Debug x64 WDK, Code Analysis, and INF

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File scripts/Build-Driver.ps1 -Configuration Debug -RunCodeAnalysis
```

```text
Capture.c
CaptureCore.c
Control.c
Device.c
Driver.c
Ring.c
TransportCore.c
Running C/C++ Code Analysis...
CODE_ANALYSIS_DIAGNOSTIC_COUNT=0
CODE_ANALYSIS_UNCODED_DIAGNOSTIC_COUNT=0
CODE_ANALYSIS_COMMAND_COUNT=1
CODE_ANALYSIS_REQUIRED_MARKER_COUNT=11
INFVERIF_EXIT_CODE=0
```

The unique production `/analyze` command contains all seven production C
sources, DriverMinimumRules, EspXEngine, WindowsPrefast, and drivers.dll.
Final Debug `CommMonitor.Driver.sys` size: 25,600 bytes.

### Managed regression

```powershell
dotnet test CommMonitor.sln --configuration Debug --no-restore --nologo
```

```text
CommMonitor.Core.Tests: passed 53, failed 0
CommMonitor.Service.Tests: passed 49, failed 0
CommMonitor.App.Tests: passed 56, failed 0
```

Total: **158 passed, 0 failed**.

### Static and binary checks

```text
POWERSHELL_AST_ERROR_COUNT=0
VCXPROJ_XML_OK=True
VCXPROJ_PRODUCTION_SOURCE_COUNT=7
COMPLETION_PARAMS_PARAMETERS_USE_COUNT=0
EXACT_LOWER_COMPLETION=True
REQUESTOR_PID_DDI=IoGetRequestorProcessId
LARGE_STACK_EVENT_COUNT=0
DEVICE_INSTANCE_PROPERTY_EX=True
ANALYSIS_COMMAND_COUNT=1
ANALYSIS_REQUIRED_MARKER_COUNT=11
ANALYSIS_CODED_DIAGNOSTIC_COUNT=0
X64_BINARY_CHECK_EXIT=0
DIFF_CHECK=OK
```

`dumpbin /headers` reported `8664 machine (x64)` for the driver and all five
native test executables. PowerShell AST parsing and vcxproj XML parsing both
passed. Source assertions additionally confirmed the distinct serial/control
callbacks, SEND_AND_FORGET fallback, current-type formatting, no
`WdfRequestGetRequestorProcessId`, no 4096-byte stack event, exact lower
completion call, and no use of completion-parameter buffer members.

## Files

Created:

- `src/CommMonitor.Driver/Capture.c`
- `src/CommMonitor.Driver/CaptureCore.c`
- `src/CommMonitor.Driver/CaptureCore.h`
- `src/CommMonitor.Service/Ports/DeviceIdHasher.cs`
- `tests/driver/DeviceIdHashTests.cpp`
- `tests/driver/CaptureCoreTests.cpp`
- `tests/CommMonitor.Service.Tests/Ports/DeviceIdHasherTests.cs`
- `.superpowers/sdd/task-10-report.md`

Modified:

- `src/CommMonitor.Driver/Driver.h`
- `src/CommMonitor.Driver/Device.c`
- `src/CommMonitor.Driver/CommMonitor.Driver.vcxproj`
- `scripts/Build-Driver.ps1`

## Self-review and residual risk

- Verified every monitoring allocation path has deterministic cleanup and
  every serial request has one forwarding/completion path.
- Verified no ring result, buffer-retrieval error, property-query error,
  allocation failure, or unsupported IOCTL changes lower serial traffic.
- Verified status/information are copied to the monitor header only when the
  wire fields can represent them, while the original completion always uses
  the exact pointer-sized lower values.
- Verified output bytes are touched only for successful lower completions and
  never beyond completed, requested, accessible, or 4096-byte bounds.
- Verified input bytes are snapshotted before send and never re-read after the
  lower driver can mutate or complete the request.
- Runtime capture against a live serial stack was not exercised because this
  task explicitly prohibits installing/loading the driver. Real-device,
  hotplug, stress, and Driver Verifier evidence remains part of the guarded
  Task 12 acceptance workflow.
