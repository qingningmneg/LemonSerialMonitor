# Lemon Serial Monitor AI Integration Guide

[简体中文](AI_INTEGRATION.md) | [English](AI_INTEGRATION.en.md)

Lemon Serial Monitor provides two automation entry points: a standard MCP stdio server and a JSON command-line interface. Both connect to the background service through the trusted client installed on the local machine. They do not directly open COM ports or expose a network listener.

## What You Can Do

- View service, driver, capture, and data-integrity status
- List the current serial ports and their stable device identifiers
- Start, pause, resume, and stop capture
- List persisted sessions with pagination
- Read events by cursor or wait for new events
- Filter by port, event type, and UTC time
- Read HEX, Base64, and limited text previews
- Export JSON, JSONL, CSV, TXT, or RAW
- Read descriptions of fields, error codes, and the integrity protocol

The interface intentionally provides no ability to send, inject, replay, modify, clear, delete, or overwrite data, or to read or write arbitrary files.

## Security Model

The AI interface uses only a local named pipe. Before accepting a request, the background service verifies:

- The Windows user SID authorized during installation
- The current logon session identifier
- The canonical path of the client process image
- The client file's SHA-256
- Pipe access control and the protocol version

The lease secret is protected by DPAPI for the current Windows user and is never written to standard output, MCP return values, or documentation. Do not copy the AI executable to another directory to run it, and do not allow other users to share the same lease directory.

## Locate the Client

Default path:

```text
C:\Program Files\Lemon串口监控\ai\Lemon.SerialMonitor.AI.exe
```

If you selected another directory during installation, replace the path in the following examples with the actual installation location. On Server Core, you can first run `%ProgramData%\LemonSerialMonitor\Installer\scripts\Get-CommMonitorStatus.ps1` and obtain the core directory from `CoreRoot` in its output. The AI client is at `ai\Lemon.SerialMonitor.AI.exe` under that directory.

## MCP Configuration

Change the absolute path in [mcp-config.json](../examples/ai/mcp-config.json) to the actual installation location, then merge it into the configuration of a client that supports MCP stdio:

```json
{
  "mcpServers": {
    "lemon-serial-monitor": {
      "command": "C:\\Program Files\\Lemon串口监控\\ai\\Lemon.SerialMonitor.AI.exe",
      "args": ["mcp"]
    }
  }
}
```

Starting the AI client without arguments also enters MCP mode, but explicitly specifying `mcp` is easier to audit.

After a successful connection, you should see 11 tools and 4 resources. Call `lemon_get_status` first, followed by `lemon_list_ports`.

When no serial-port device is connected, `lemon_get_status` should still return `serviceState=available`, `driverState=unavailable`, and `captureState=stopped`; the warnings may include `DriverUnavailable`, and `lemon_list_ports` returns an empty array. This is a determinable no-device state. AI should not treat it as a background-service crash, and repeated reinstallation is unnecessary. Call the status and port tools again after connecting a device.

Recommended AI workflow:

1. `lemon_get_status`: confirm the service, driver, and capture states.
2. `lemon_list_ports`: obtain the 16-digit hexadecimal `deviceId`.
3. `lemon_start_capture`: pass one or more `deviceId` values and save the returned `leaseId`.
4. Let the original business application operate the hardware.
5. `lemon_list_sessions`: obtain the `sessionId`.
6. `lemon_read_events` or `lemon_wait_events`: read by cursor.
7. Check `integrity` and `warnings` on every page, and save `nextCursor` and `resumeReceipt`.
8. `lemon_stop_capture`: stop capture with the original `leaseId`.
9. Call `lemon_export_session` when you need a file.

## Quick Command-Line Check

PowerShell:

```powershell
$lemon = 'C:\Program Files\Lemon串口监控\ai\Lemon.SerialMonitor.AI.exe'
& $lemon status --json
& $lemon ports --json
& $lemon schema --json
```

Before starting capture, copy the complete 16-digit `deviceId` from the value returned by `ports --json`:

```powershell
& $lemon capture start --device-id 0000000000000011 --label board-test --json
```

The return value contains `leaseId`. To pause, resume, and stop:

```powershell
& $lemon capture pause  --lease-id '<leaseId>' --json
& $lemon capture resume --lease-id '<leaseId>' --json
& $lemon capture stop   --lease-id '<leaseId>' --json
```

List sessions:

```powershell
& $lemon sessions list --limit 100 --json
```

Read one page of events:

```powershell
& $lemon events read `
  --session-id '<sessionId>' `
  --limit 100 `
  --include-hex `
  --include-text-preview `
  --json
```

Wait up to 30 seconds for new events and produce JSONL output:

```powershell
& $lemon events wait `
  --session-id '<sessionId>' `
  --cursor '<nextCursor>' `
  --resume-receipt '<resumeReceipt>' `
  --limit 100 `
  --timeout-seconds 30 `
  --include-hex `
  --jsonl
```

Export:

```powershell
& $lemon export --session-id '<sessionId>' --format jsonl --label board-test --json
```

Available formats: `json`, `jsonl`, `csv`, `txt`, and `raw`. `label` is a safe label, not a file path. The service manages the output location, and the interface does not overwrite existing files.

## Pagination and Resuming

For normal reads, use the `nextCursor` and `resumeReceipt` returned by the service. Do not guess database sequence numbers. Together, the cursor and receipt prove that the resume position belongs to the same session and the same capture generation.

Use the following only when explicitly accepting that continuity cannot be verified:

```text
--after-sequence <decimal-sequence-number> --allow-unverified-seek
```

This type of read may omit or duplicate events, or cross a range that cannot be proven. Its result must be marked as an unverified seek.

## Determining Integrity

Check at least the following on every page:

```text
integrity.completeForReturnedRange
integrity.driverDropped
integrity.serviceDropped
integrity.truncationSeen
integrity.gapDetected
integrity.continuityProven
warnings
```

Only when `completeForReturnedRange` is `true` may you say that "the range returned on this page is complete." Otherwise, AI must clearly state that there is dropping, truncation, a gap, or insufficient continuity evidence. It must not invent missing data as fact.

## Using Event Payloads

- `payloadBase64`: the most stable machine-readable form for reconstructing the original bytes.
- `payloadHex`: returned only when `includeHex` is requested; useful for people and protocol analysis.
- `textPreview`: a limited-length, boundary-decoded preview that cannot replace the original bytes.
- `capturedLength`: the length actually saved.
- `completedLength`: the length completed by the serial operation.
- `truncated` or a truncation flag: indicates that the original event exceeded the capture limit.

Hardware-protocol analysis should rely on the Base64/HEX raw bytes and the protocol documentation, not only on the text preview.

## Example Scripts

- [PowerShell: Read the Latest Session](../examples/ai/read-latest-session.ps1)
- [Python: Call the JSON CLI](../examples/ai/read_events.py)
- [MCP Configuration](../examples/ai/mcp-config.json)

For complete tool parameters, resource URIs, exit codes, and stable error codes, see the [AI API Reference](AI_API_REFERENCE.en.md).
