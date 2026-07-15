# Task 9 Report: Bounded driver event transport

## Status

Task 9 is implemented. The driver now owns a 2048-slot nonpaged event ring,
secure global control device, fixed control ABI, four validated buffered IOCTLs,
and an explicit `Absent` / `Active` / `Deleting` PnP/control-device lifetime
state machine. The serial filter's parallel send-and-forget forwarding queue
remains separate from the control queue and unchanged in its forwarding
behavior. Portable tests execute the same production transport core that the
WDK driver links, and every supported driver build now runs all native gates
automatically.

No driver was installed, loaded, registered, or deployed, and no system driver
state was changed.

## TDD evidence

### Ring wrap/drop RED

`tests/driver/RingModelTests.cpp` was first added with the required calls and
assertions but without any `RingModel` definitions. It pushed `1,2,3` into
capacity two, checked that `1,2` remained and one event was dropped, popped
`1`, pushed `4`, and checked the remaining order `2,4`.

The amd64 VS 2022 command used `/std:c++17 /W4 /WX /EHsc` and failed for the
expected missing feature, not for a syntax error:

```text
LNK2019: unresolved RingModel constructor/Push/Pop/At/Count/Dropped
LNK1120: 6 unresolved externals
RING_MODEL_RED_EXIT_CODE=2
```

After the minimum test-local fixed-capacity model was added:

```text
RingModelTests.cpp
RING_MODEL_GREEN_EXIT_CODE=0
```

### Control ABI RED/GREEN

Size/offset assertions for the new version/config/stats structures were added
to the user-mode ABI test before those types existed in `Protocol.h`:

```text
C2065: CMON_VERSION_INFO / CMON_CONFIG_INPUT / CMON_STATS_INFO undeclared
CONTROL_ABI_RED_EXIT_CODE=2
```

The fixed packed ABI was then added to `Protocol.h`, including field-width
gates in both user-mode and kernel tests:

```text
sizeof(CMON_VERSION_INFO) = 12
FIELD_OFFSET(CMON_CONFIG_INPUT, DeviceHashes) = 8
sizeof(CMON_STATS_INFO) = 24
NATIVE_CONTROL_ABI_AND_RING_GREEN_EXIT_CODE=0
```

### Batch-boundary RED/GREEN

The portable model was extended with calls and assertions for variable wire
lengths before the two-argument `Push` and `PopBatch` existed:

```text
LNK2019: unresolved RingModel::Push(sequence, wireLength)
LNK2019: unresolved RingModel::PopBatch(outputLength)
RING_BATCH_MODEL_RED_EXIT_CODE=2
```

The minimum test-local implementation then passed these contracts:

- the first event does not fit: buffer-too-small, zero bytes, no dequeue;
- one event fits but the next does not: return only the complete first event
  and keep the second queued;
- an empty ring returns success with zero bytes.

```text
RingModelTests.cpp
RING_BATCH_MODEL_GREEN_EXIT_CODE=0
```

### Control deletion-window RED/GREEN

The portable lifecycle model was extended before its implementation with the
required `Absent` / `Active` / `Deleting` operations, reservation idempotence,
retained control generation, destroy callback, and deferred recreation worker.
The initial link failed for the missing lifecycle model API:

```text
LNK2019: unresolved ControlLifecycleModel constructor/Acquire/Release/Destroy
LNK2019: unresolved lifecycle worker/getters
LNK1120: 11 unresolved externals
CONTROL_LIFECYCLE_MODEL_RED_EXIT_CODE=2
```

The destroy-window assertion then failed at runtime while the incomplete model
transitioned directly to `Absent` instead of retaining `Deleting` until the
worker ran:

```text
CONTROL_DESTROY_WINDOW_RED_EXIT_CODE=347
```

Further RED runs first required a fallible worker and then a fallible later
DeviceAdd retry:

```text
LNK2019: unresolved ControlLifecycleModel::RunRecreateWorker(bool)
CONTROL_WORKER_FAILURE_RED_EXIT_CODE=2
LNK2019: unresolved ControlLifecycleModel::Acquire(PnpReservation&, bool)
CONTROL_LATER_ADD_RETRY_RED_EXIT_CODE=2
```

The final model verifies that the last release retains the old generation in
`Deleting`; an Add during deletion increments the PnP count without creating;
destroy clears the old generation but remains `Deleting`; an Add in the
destroy-to-worker window still cannot create; the one-shot worker creates the
new generation; duplicate release of an old reservation is harmless; worker
failure leaves `Deleting` with no queued worker; and a later new Add queues one
new bounded worker instead of creating directly.

Final independent review exposed two further hotplug windows and they were
also driven through RED/GREEN portable contracts. First, a destroy with no
active anchor must remain `Deleting` because the named WDF object is not fully
deleted until `EvtDestroy` returns; a later Add must queue a worker rather than
attempting an immediate same-name create. Second, a raw worker must hold
per-device rundown so the anchor PnP cleanup cannot return while the worker is
still using its device context. Collision handling is bounded to one initial
attempt plus four 10ms retries, with a lifecycle-lock recheck before every
attempt:

```text
NO_ANCHOR_ADD_RED_EXIT_CODE=480
NO_ANCHOR_ADD_GREEN_EXIT_CODE=0
COLLISION_RETRY_MODEL_RED_EXIT_CODE=2
COLLISION_RETRY_MODEL_GREEN_EXIT_CODE=0
ANCHOR_RUNDOWN_MODEL_RED_EXIT_CODE=2
ANCHOR_RUNDOWN_MODEL_GREEN_EXIT_CODE=0
WORKER_COUNT_ZERO_MODEL_RED_EXIT_CODE=602
WORKER_COUNT_ZERO_MODEL_GREEN_EXIT_CODE=0
WORKER_UNSUCCESSFUL_TERMINAL_MODEL_RED_EXIT_CODE=532
WORKER_UNSUCCESSFUL_TERMINAL_MODEL_GREEN_EXIT_CODE=0
```

The rundown model proves that cleanup cannot return with an outstanding raw
worker and that no new worker can acquire an anchor after rundown starts. The
count-zero model proves that a queued worker whose last PnP device disappears
clears its queued flag, issues no create, and keeps `Deleting`. The unsuccessful
terminal model applies the same rule to non-collision creation failure and
collision-retry exhaustion, then verifies that a later Add queues a new worker
and can publish `Active` successfully.

```text
RingModelTests.cpp
CONTROL_LIFECYCLE_MODEL_GREEN_EXIT_CODE=0
```

### Production-coupled transport core RED/GREEN

`TransportCoreTests.cpp` was added first against the intended production
header. Its first compile failed because that production API did not exist:

```text
C1083: cannot open include file: '../../src/CommMonitor.Driver/TransportCore.h'
TRANSPORT_CORE_RED_EXIT_CODE=2
```

`TransportCore.c` and `TransportCore.h` now contain the production ring and
byte-level config logic. The C source is compiled as C with `/TC /W4 /WX`, then
the C++ test links that exact object. A subsequent invalid-config output test
failed at runtime before the validator initialized its optional outputs, then
passed after the production validator was corrected:

```text
TRANSPORT_CONFIG_OUTPUT_RED_EXIT_CODE=321
NATIVE_TRANSPORT_CORE_EXIT_CODE=0
```

The production-coupled tests cover invalid payload accounting, drop-new
capacity behavior, sequence gaps, exact wire headers/payloads, wrap/reuse,
first-event-too-small without dequeue, partial batches, empty batches, all
valid config states, the 64-device boundary, and invalid state/count/zero hash/
duplicate/trailing/truncated config bytes.

## Ring behavior

- `DRIVER_CONTEXT` owns `2048 * sizeof(CMON_EVENT_SLOT)` bytes allocated with
  `ExAllocatePool2(POOL_FLAG_NON_PAGED, ..., 'noMC')` and frees the same tagged
  allocation from driver cleanup.
- Head, tail, count, dropped count, sequence, capture state, and up to 64
  selected device hashes are protected by a WDF spin lock.
- Payload lengths over 4096 are rejected before acquiring the spin lock. They
  consume neither a sequence number nor a dropped count.
- Every valid capture attempt consumes the next sequence number under the
  lock. If the ring is full, the new event is discarded, `Dropped` is
  incremented, and `STATUS_BUFFER_OVERFLOW` is returned without changing
  head, tail, count, or any stored event. Thus later accepted events expose a
  sequence gap corresponding to overflow loss. `GET_STATS.Sequence` is the
  last valid capture-attempt sequence, not the last dequeued sequence.
- `CmonRingPopBatch` checks the complete `header + payload` wire length before
  copying or advancing the head. It never emits a partial event or stale slot
  tail bytes.
- If the first queued event cannot fit, it returns
  `STATUS_BUFFER_TOO_SMALL`, zero bytes, and leaves that event queued. If one
  or more events have already been copied and the next one cannot fit, it
  returns success with only the complete copied events and leaves the next
  event queued. An empty ring returns success with zero bytes.
- The spin lock is released after each event; at most one 4164-byte slot is
  copied per acquisition. The implementation never holds the spin lock while
  copying the complete roughly 8 MiB ring, allocating memory, completing a
  request, or calling a WDF request API.

## Control device and validation

- Control name: `\Device\CommMonitorFilter`.
- DOS link: `\DosDevices\Global\CommMonitorFilter`, opened as
  `\\.\Global\CommMonitorFilter`.
- Protected SDDL: `D:P(A;;GA;;;SY)(A;;GA;;;BA)`. It grants Generic All only to
  Local System and Builtin Administrators. `FILE_DEVICE_SECURE_OPEN` is set.
- The control device owns a non-power-managed sequential default queue whose
  only callback is `EvtIoDeviceControl`. Serial FDOs retain their separate
  parallel `EvtIoDefault` send-and-forget forwarding queue.
- `GET_VERSION` requires no input and at least 12 output bytes; it returns
  protocol version, 68-byte event header size, and 4096-byte maximum payload.
- `SET_CONFIG` requires zero output and exact input length
  `8 + DeviceCount * 8`. State must be stopped/running/paused, count must be at
  most 64, running/paused require at least one hash, and every hash must be
  nonzero and unique. Stopped accepts zero through 64 hashes. Validation is
  complete before the spin-locked atomic update, so invalid input cannot
  partially change state.
- `GET_BATCH` requires no input and at least one 68-byte header of output
  space, then follows the ring batch status rules above.
- `GET_STATS` requires no input and at least 24 output bytes and returns a
  locked snapshot of queued, dropped, sequence, and state.
- Unknown IOCTLs and malformed known IOCTL buffers complete with
  `STATUS_INVALID_PARAMETER`. A valid batch buffer that cannot hold the first
  full event completes with the distinct `STATUS_BUFFER_TOO_SMALL` capacity
  result.

The driver context owns an explicit `Absent` / `Active` / `Deleting` control
state, retained control-device handle, active PnP device list/count, deferred
recreation flag, and PASSIVE-level WDF wait lock. A PnP device is registered
only after both its `WdfDeviceCreate` and forwarding queue creation succeed;
control creation is best-effort and can never fail DeviceAdd. Registration is
idempotent through the device context's `Registered` flag.

The last registered device cleanup removes its list entry and decrements the
count under the lifecycle lock. If the control is `Active`, it transitions to
`Deleting` but retains the exact handle; `WdfObjectDelete` is called only after
the lock is released. An Add during deletion registers normally and requests
deferred recreation without racing a second named control device into
existence. The matching control `EvtDestroy` is the only path that clears the
retained handle. If an eligible PnP device exists, it acquires that device's
`EX_RUNDOWN_REF` under the lock, sets `RecreateWorkerQueued`, and queues one raw
`IoQueueWorkItemEx` item outside the lock. If no anchor exists, state remains
`Deleting`; a later Add sees the null retained handle and queues the one-shot
worker instead of directly creating a same-name object while `EvtDestroy` is
still returning. A driver-parented WDF work item is intentionally not used
because WDF work items require WDFDEVICE ancestry.

At PASSIVE level the worker rechecks `Deleting`, the null retained handle, and
the live PnP count under the lifecycle lock. A name collision restores
`Deleting`, deletes any partial device outside the lock, waits 10ms outside the
lock, and retries at most four times, so a collision cannot spin. Every
unsuccessful post-destroy terminal path—allocation failure, no live PnP device,
non-collision creation failure, or collision-retry exhaustion—clears
`RecreateWorkerQueued` but retains `Deleting`. The old named WDF object is not
proven gone until its `EvtDestroy` returns, and a raw worker may run before that
return; retaining `Deleting` guarantees that any later DeviceAdd queues another
bounded worker instead of attempting an unsafe direct create. Only successful
publication transitions to `Active`.

The worker derives the WDF device/context from its raw work item's `IoObject`;
it does not carry a nullable context or a driver-owned WDF object reference.
PnP cleanup first unregisters/removes the device under the lifecycle lock and
then calls `ExWaitForRundownProtectionRelease`. Allocation failure and the
worker's final path symmetrically release rundown, after which they never touch
the anchor context. This keeps all raw-worker device-context access within the
PnP cleanup contract. Destroy of an unpublished partial control takes an early
no-lock return. No `WdfObjectDelete`, work-item queue operation, wait, or retry
delay occurs while the lifecycle lock is held.

## Final verification

### Automatic portable native gates (`/W4 /WX`)

Every invocation of `Build-Driver.ps1` now compiles and runs three gates in the
configuration-specific isolated `artifacts/native-tests/<Configuration>/x64`
directory. `ProtocolLayoutTests.cpp` and `RingModelTests.cpp` use
`/std:c++17 /W4 /WX /EHsc`; `TransportCore.c` uses `/TC /W4 /WX /c`, and
`TransportCoreTests.cpp` links that production C object:

```text
ProtocolLayoutTests.cpp
RingModelTests.cpp
TransportCore.c
TransportCoreTests.cpp
NATIVE_PROTOCOL_LAYOUT_EXIT_CODE=0
NATIVE_RING_MODEL_EXIT_CODE=0
NATIVE_TRANSPORT_CORE_EXIT_CODE=0
```

### Debug x64 driver build and INF verification

```powershell
powershell -ExecutionPolicy Bypass -File scripts\Build-Driver.ps1 -Configuration Debug
```

The script used amd64 MSBuild, first passed the three automatic native gates,
rebuilt the independent kernel protocol gate, rebuilt all five production
driver sources, and invoked `InfVerif.exe /w`:

```text
KernelProtocolCompileTests.vcxproj -> KernelProtocolCompileTests.lib
Control.c
Device.c
Driver.c
Ring.c
TransportCore.c
CommMonitor.Driver.vcxproj -> CommMonitor.Driver.sys
INFVERIF_EXIT_CODE=0
FINAL_DEBUG_EXIT_CODE=0
```

Final `CommMonitor.Driver.sys` size: 19,456 bytes.

### Code Analysis hard gate

`Build-Driver.ps1` now supports a reproducible `-RunCodeAnalysis` switch. The
MSVC 14.44 ruleset parser emits C6800 when `/analyze:ruleset` itself is below a
path containing non-ASCII characters, even though the ruleset XML is valid.
The switch therefore restores the WDK packages to the system temporary cache
only when its path is ASCII; callers can provide any writable ASCII path with
`-PackagesDirectory`. No warning is suppressed and the driver minimum ruleset
and all WDK analysis plugins remain active.

The switch scans the complete driver MSBuild log and fails on any coded or
uncoded warning/error diagnostic, because PREfast warnings do not necessarily
make MSBuild return nonzero. It additionally requires exactly one production
`CL.exe /analyze` command and verifies that this command contains the driver
minimum ruleset, all three required analyzer DLLs, and all five production C
sources. This prevents a clean but accidentally disabled or partial analysis
run from satisfying the gate.

The strengthened gate immediately found two real diagnostics: the initial
`IO_WORKITEM_ROUTINE_EX` optional-context implementation dereferenced a nullable
value (`C28182`), and `CmonRingCorePopOne` needed to initialize `EventBytes`
before all invalid-state returns (`C6101`). The gate failed with exit 1. The
transport output was initialized immediately; the worker was subsequently
hardened further to derive its device context from the non-null `IoObject`
under rundown, eliminating the nullable carried context entirely.

```powershell
powershell -ExecutionPolicy Bypass -File scripts\Build-Driver.ps1 -Configuration Debug -RunCodeAnalysis
```

```text
RUN_CODE_ANALYSIS=True
Building 'CommMonitor.Driver' with amd64 MSBuild...
Running C/C++ Code Analysis...
CODE_ANALYSIS_DIAGNOSTIC_COUNT=0
CODE_ANALYSIS_UNCODED_DIAGNOSTIC_COUNT=0
CODE_ANALYSIS_COMMAND_COUNT=1
CODE_ANALYSIS_REQUIRED_MARKER_COUNT=9
INFVERIF_EXIT_CODE=0
FINAL_CODE_ANALYSIS_EXIT_CODE=0
```

### Managed regression

```powershell
dotnet test CommMonitor.sln --configuration Debug --no-restore --nologo
```

```text
CommMonitor.Core.Tests: passed 53, failed 0
CommMonitor.Service.Tests: passed 47, failed 0
CommMonitor.App.Tests: passed 56, failed 0
FINAL_MANAGED_EXIT_CODE=0
```

Total: **156 passed, 0 failed**.

### Static/build-file checks

```text
POWERSHELL_AST_ERROR_COUNT=0
VCXPROJ_XML_OK=True
VCXPROJ_PRODUCTION_SOURCE_COUNT=5
WDF_OBJECT_DELETE_OUTSIDE_LOCK_COUNT=4
IO_WORKITEM_QUEUE_OUTSIDE_LOCK_COUNT=1
RETRY_DELAY_OUTSIDE_LOCK_COUNT=1
DESTROY_NEVER_PUBLISHES_ABSENT=True
WORKER_UNSUCCESSFUL_TERMINALS_DELETE_PENDING=True
LEGACY_WDF_REFERENCE_COUNT=0
RUNDOWN_ACQUIRE_CALL_SITES=2
RUNDOWN_RELEASE_CALL_SITES=2
RUNDOWN_INIT_CALL_SITES=1
RUNDOWN_WAIT_CALL_SITES=1
FINAL_ANALYSIS_LOG_DIAGNOSTIC_COUNT=0
FINAL_ANALYSIS_COMMAND_COUNT=1
DIFF_CHECK=OK
FINAL_STATIC_EXIT_CODE=0
```

Additional assertions checked capacity, maximum selected devices, nonpaged
tagged allocation/cleanup, drop-new behavior, first-event buffer-too-small
behavior, exact SDDL/global link, control/serial queue separation, control
lifecycle coordination, every `WdfObjectDelete` occurring outside the
lifecycle lock, the unpublished-partial destroy fast path, all three native
test inputs, and both transport-core files in the WDK project.

## Files

Created:

- `src/CommMonitor.Driver/Ring.c`
- `src/CommMonitor.Driver/Control.c`
- `src/CommMonitor.Driver/TransportCore.c`
- `src/CommMonitor.Driver/TransportCore.h`
- `tests/driver/RingModelTests.cpp`
- `tests/driver/TransportCoreTests.cpp`
- `.superpowers/sdd/task-9-report.md`

Modified:

- `src/CommMonitor.Driver/Driver.h`
- `src/CommMonitor.Driver/Driver.c`
- `src/CommMonitor.Driver/Device.c`
- `src/CommMonitor.Driver/Protocol.h`
- `src/CommMonitor.Driver/CommMonitor.Driver.vcxproj`
- `tests/driver/ProtocolLayoutTests.cpp`
- `tests/driver/KernelProtocolCompileTests.c`
- `scripts/Build-Driver.ps1`

`Protocol.h` and both ABI gates were necessarily updated so the control ABI is
fixed and consumable by the later service. `Device.c` was minimally updated
because KMDF requires a PnP device cleanup path to delete a control device
before unload. The serial request callback itself was not changed.

## Self-review and residual risks

- Applied the independent design review's Important control-device lifetime,
  SAL, ABI width, exact config length, duplicate/zero hash, queue isolation,
  and per-event lock-duration findings.
- Applied root review's duplicate-release, deletion-window state machine,
  retained-handle destroy ordering, PnP-anchored one-shot recreation, automatic
  production-coupled native gates, byte-level SAL validation, and strict
  zero-warning/analysis-activation findings.
- Final independent re-review of the current files reported no Critical,
  Important, or Minor findings and confirmed the failed-worker `Deleting`
  terminals, rundown symmetry, bounded collision retries, and lock-external
  partial deletion.
- Confirmed no ring status is currently propagated into the serial path;
  Task 10 can call `CmonRingPush` as best-effort transport while preserving the
  lower request's status/information.
- `ExAllocatePool2` requires Windows 10 version 2004 or later. This phase builds
  against WDK/SDK 10.0.26100.0; a downlevel allocation fallback is not part of
  Task 9.
- Driver runtime, live serial I/O, control-device open ACLs, and physical
  hotplug were not exercised because installation/loading/system mutation was
  explicitly prohibited. The implementation was verified through portable
  tests, real WDK builds, InfVerif, and PREfast Code Analysis.
