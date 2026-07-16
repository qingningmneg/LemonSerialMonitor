# Lemon Serial Monitor AI API Reference

[简体中文](AI_API_REFERENCE.md) | [English](AI_API_REFERENCE.en.md)

## Transport and Versions

- MCP: standard input/standard output (stdio)
- CLI: standard output contains UTF-8 JSON or JSONL; diagnostics are written to standard error
- Service transport: local named pipe only
- Network listener: none
- Page size: 1–1000; default 100
- Wait timeout: 1–30 seconds; default 30 seconds
- Text-preview limit: 1–4096 bytes; default 256 bytes

Run `schema --json` or call `lemon_get_schema` to read the current protocol version, allowed commands, event fields, and error codes.

## MCP Tools

### `lemon_get_status`

Reads an overview of service, driver, capture, ownership, and data-integrity status. No parameters.

### `lemon_list_ports`

Lists the current serial ports. Returns the display name and a 16-digit hexadecimal `deviceId`. Does not open COM ports.

### `lemon_start_capture`

Parameters:

- `deviceIds`: one or more 16-digit hexadecimal device identifiers
- `label`: optional session label, not a path

Returns `leaseId`, `sessionId`, `generation`, and the capture state. The lease secret is not returned.

### `lemon_pause_capture`

Parameter: `leaseId`. Pauses capture owned by that lease.

### `lemon_resume_capture`

Parameter: `leaseId`. Resumes capture owned by that lease.

### `lemon_stop_capture`

Parameter: `leaseId`. `lemon_stop_capture` stops capture and then removes the lease from the current user's protected lease store.

### `lemon_list_sessions`

Parameters:

- `cursor`: optional pagination cursor
- `limit`: 1–1000

Returns a safe `sessionId` for each persisted session. A `sessionId` is not a file path.

### `lemon_read_events`

Parameters:

- `sessionId`: required
- `cursor`: cursor for normal continuation to the next page
- `resumeReceipt`: resume receipt matching the previous page
- `afterSequence`: optional decimal sequence number, for unverified seeking only
- `allowUnverifiedSeek`: must be `true` when using `afterSequence`
- `limit`: 1–1000
- `deviceIds`: repeatable device filters
- `kinds`: repeatable event-type filters, such as `Read` and `Write`
- `includeHex`: whether to return `payloadHex`
- `includeTextPreview`: whether to return a limited text preview

The MCP tool provides commonly used filter fields. The CLI additionally provides `fromUtc`, `toUtc`, and the text-preview length.

### `lemon_wait_events`

Uses the same parameters as `lemon_read_events`, plus `timeoutSeconds` (1–30). Returns a page on timeout or when committed events are available. It does not return uncommitted in-memory events.

### `lemon_export_session`

Parameters:

- `sessionId`
- `format`: `json`, `jsonl`, `csv`, `txt`, or `raw`
- `label`: optional safe label

The service creates a unique new file. It does not accept a directory or overwrite an existing file.

### `lemon_get_schema`

Reads the protocol version, commands, event fields, and stable error codes.

## MCP Resources

- `lemon://docs/ai-interface`: safe-use instructions
- `lemon://schema/capture-event`: event fields and payload descriptions
- `lemon://schema/errors`: error envelope and error codes
- `lemon://schema/integrity`: integrity fields and evaluation rules

## CLI Commands

```text
status --json
ports --json
capture start --device-id <16hex> [--device-id <16hex> ...] [--label <text>] --json
capture pause --lease-id <id> --json
capture resume --lease-id <id> --json
capture stop --lease-id <id> --json
sessions list [--cursor <cursor>] [--limit 1..1000] --json
events read --session-id <id> [options] --json
events wait --session-id <id> [options] --jsonl
export --session-id <id> --format <json|jsonl|csv|txt|raw> [--label <text>] --json
schema --json
```

Options for `events read` / `events wait`:

```text
--cursor <cursor>
--resume-receipt <receipt>
--after-sequence <decimal> --allow-unverified-seek
--limit 1..1000
--device-id <16hex>              repeatable
--kind <Read|Write|...>          repeatable
--from-utc <ISO-8601>
--to-utc <ISO-8601>
--include-hex
--include-text-preview
--text-preview-max-bytes 1..4096
--timeout-seconds 1..30          wait only
```

With `events wait --jsonl`, each event is written as one line of JSON, followed by a final line of `_page` metadata containing the cursor, receipt, whether more data is available, the sequence number scanned through, integrity, and warnings.

## CLI Exit Codes

| Exit code | Meaning |
|---:|---|
| 0 | Success |
| 2 | Invalid arguments |
| 3 | Access denied or protocol mismatch |
| 4 | Service or driver unavailable |
| 5 | Capture conflict or lease error |
| 6 | Data gap or insufficient integrity evidence |
| 7 | Timeout or cancellation |
| 10 | Unexpected error |

Even on failure, standard output still contains a structured error envelope:

```json
{
  "success": false,
  "error": {
    "code": "SERVICE_UNAVAILABLE",
    "message": "...",
    "retryable": true,
    "correlationId": "..."
  }
}
```

Automation should evaluate the process exit code and parse `error.code`; it should not match localized message text.

## Main Event Fields

| Field | Description |
|---|---|
| `sequence` | Persisted sequence number within the session |
| `wireSequence` | Driver/service transport sequence evidence |
| `timestampUtc` | UTC time |
| `qpcTicks` | High-resolution counter timing evidence |
| `deviceId` | Stable device identifier |
| `portName` | COM name for display |
| `processId` / `processName` | Initiating process information |
| `kind` | Read, Write, Ioctl, DropNotice, and other kinds |
| `ioctlCodeHex` | IOCTL hexadecimal value |
| `ntStatusHex` | NTSTATUS hexadecimal value |
| `requestedLength` | Requested length |
| `completedLength` | Completed length |
| `capturedLength` | Length actually saved |
| `flags` | Truncation, loss, and other flags |
| `payloadBase64` | Raw bytes in Base64 |
| `payloadHex` | Optional HEX view |
| `textPreview` | Optional limited text preview |

## Integrity Fields

| Field | Description |
|---|---|
| `statsKnown` | Whether driver/service statistics evidence was obtained |
| `driverDropped` | Driver ring-buffer drop count |
| `serviceDropped` | Service-side drop count |
| `truncationSeen` | Whether truncation occurred in the returned range |
| `gapDetected` | Whether a sequence or commit gap was found |
| `continuityProven` | Whether cursor-resume continuity is established |
| `completeForReturnedRange` | Whether the returned range may be declared complete |
| `statisticsSampledAtUtc` | Statistics sample time |
| `generation` | Capture generation |

Rule: only when `completeForReturnedRange == true` may the caller mark the returned range as complete.

## Concurrency and Leases

- A capture state is owned by the desktop client or one AI lease. Conflicting requests return a stable error.
- AI start uses a two-phase prepare/commit flow. The client commits only after writing the lease secret to the current user's DPAPI vault.
- When the client restarts, it first reconciles leases. Leases that are expired, invalid, or do not belong to the current logon session are cleaned up.
- Do not treat `leaseId` as a secret. It is only a reference; the actual proof is retained in protected local state.
