# Lemon Serial Monitor Troubleshooting

[简体中文](TROUBLESHOOTING.md) | [English](TROUBLESHOOTING.en.md)

## No Data Is Visible

Check in this order:

1. Click **Refresh Ports** (`刷新端口`) and confirm that the target COM port is present.
2. Select the target port.
3. Click **Start** (`开始`) and confirm that the button state has changed.
4. After starting, have the original business application actually send or read data.
5. Confirm that the COM number used by the original business application matches the selected port.
6. Check the red status-bar error and the driver status.
7. If the **List** (`列表`) contains only Ioctl events while the **Terminal** (`终端`) is empty, only configuration operations have occurred; there is no actual Read/Write payload.

The software does not actively send data for testing. When the original business application is not communicating, an empty monitoring view is normal.

## The Port List Is Empty or a Port Is Missing

- If Device Manager also shows no currently available serial port, an empty list is normal. The background service should remain running; a temporarily unavailable driver in the status does not mean that the service failed to start.
- Confirm that the port is visible in Device Manager.
- After unplugging and reconnecting a USB-to-serial adapter, click **Refresh Ports** (`刷新端口`) again.
- Confirm that the background service has started. With no serial device, it is normal for the demand-start filter driver to remain stopped. If a device is present and still cannot become ready, then check the driver service and device events.
- If the computer has not been restarted since installation, restart it first.
- Bluetooth, virtual serial ports, or vendor-specific device stacks may differ from the standard Ports class. Retain the hardware information and validate them separately.

## Service Not Connected

Check from an elevated PowerShell window:

```powershell
sc.exe query CommMonitorService
sc.exe qc CommMonitorService
sc.exe query CommMonitorFilter
```

If the service is not running:

```powershell
Start-Service CommMonitorService
```

If it stops again immediately, inspect the Application and System logs in Windows Event Viewer. Do not change the service to run as an ordinary user, and do not manually start a replacement file from a writable directory.

## Driver Not Ready

First confirm whether the computer actually has a currently available serial device. With no device, the filter driver has no device stack to attach to, so a temporarily unavailable driver in the UI is normal. Connect a device, click **Refresh Ports** (`刷新端口`), and check again.

Common causes:

- The computer was not restarted after installation.
- Secure Boot is still enabled.
- `TESTSIGNING` has not taken effect yet.
- The test certificate import failed, or the driver signature does not match.
- Security software or organizational policy blocked the driver package.
- The Ports class filter did not load correctly.

Administrator checks:

```powershell
bcdedit.exe /enum '{current}' | Select-String testsigning
sc.exe query CommMonitorFilter
```

Do not enable `nointegritychecks`, and do not download driver-signing patches from unknown websites.

## Setup Reports That Secure Boot Is Enabled

This is an expected safety gate. Setup does not disable Secure Boot for you.

1. First confirm that the BitLocker/device-encryption recovery key is available.
2. The computer owner must decide whether to disable Secure Boot in UEFI.
3. If you do not want to change the boot policy, cancel installation and wait for a future production-signed version.

Every computer has a different UEFI interface; a generic script cannot safely replace manual confirmation.

## Setup Requests a Restart

A restart is required when the filter driver, Ports class device stack, or `TESTSIGNING` changes. Save your work, restart, and then perform a real serial-port test. Before restarting, do not repeatedly uninstall and reinstall or manually edit the filter configuration.

## Garbled Terminal Text

- Select ANSI, UTF-8, UTF-16LE, or UTF-16BE according to the device protocol.
- Changing the encoding affects only data that arrives afterward; clearing the UI or starting a new test makes comparisons easier.
- Binary protocols are not suitable for terminal text in the first place; use HEX in the **List** (`列表`) or **Dump** (`Dump`) instead.
- For GBK or a local code page, ANSI is usually the appropriate choice, but the device protocol documentation remains authoritative.

## HEX Search Reports an Error

Correct:

```text
01 03 00 FF
03 ?? FF
```

Incorrect:

```text
0x01 0x03
010300FF
GG
```

Each byte must contain two hexadecimal characters and be separated by spaces; `??` can represent only one byte.

## Copied Data Is Missing the Port or Direction

HEX, text, C array, and Python bytes are payload-only formats. When multiple rows are selected, their payloads are concatenated directly. To retain the time, port, direction, process, and event boundaries, choose TSV, CSV, or JSON.

`Ctrl+Shift+C` always copies plain space-separated HEX without metadata. To use the currently selected format, press `Ctrl+C`.

## The Export Button Is Disabled

Export is enabled only while stopped. First click **Stop** (`停止`), then check that the export file name and format have been filled in.

Export processes the full persisted session, not only the selected rows. To copy only selected content, use **Copy Data** (`复制数据`).

## AI Client Cannot Connect

First run:

```powershell
& '<安装目录>\ai\Lemon.SerialMonitor.AI.exe' status --json
```

Check:

- Whether the background service is running.
- Whether you are using the original AI client from the installation directory; the service rejects a copy from another path.
- Whether the current Windows user is the interactive user authorized during installation.
- Whether you switched users or logon sessions.
- Whether `command` in the MCP configuration is an absolute path.
- Whether backslashes in JSON are written as `\\`.

The AI interface does not listen on TCP or HTTP, so it is expected that a network port scan will not find it.

## AI Reads Report Unknown Integrity or a Gap

Check every page for:

- `integrity.completeForReturnedRange`
- `integrity.driverDropped`
- `integrity.serviceDropped`
- `integrity.truncationSeen`
- `integrity.gapDetected`
- `warnings`
- `nextCursor` and `resumeReceipt`

Only when `completeForReturnedRange` is `true` may you declare the returned range complete. If the service restarts, a cursor becomes invalid, the driver drops events, the service drops events, or truncation occurs, mark the conclusion as incomplete and retain the relevant evidence.

## The Original Serial Application Malfunctions

Restore the business operation first:

1. Click **Stop** (`停止`) in the desktop application, if it is still operable.
2. Close the desktop application.
3. Record the exact time, COM number, device model, and business-application error.
4. Perform a full uninstall of Lemon Serial Monitor.
5. Restart when prompted.
6. Verify whether the original business application recovers without this tool installed.

Do not retry repeatedly, manually delete driver services, or directly edit the Ports class `UpperFilters`. These actions destroy the pre-installation baseline and make recovery more difficult.

## Uninstall Reports a File in Use

The uninstaller first closes this software's desktop application, AI client, and background service. If it still requests a restart, the usual reason is that the kernel driver, Ports class device stack, boot policy, or a Windows file lock has not yet been released—not that the user must manually terminate this software's processes. Save your work and restart; after signing in, wait for uninstall to finish. Do not delete the installation directory or cancel the scheduled task before restarting.

If it still fails after the restart, retain the message text, uninstall log, system version, and status-script output. If the protected installation record is missing, uninstall stops to avoid deleting another software product; this is a safety behavior.

## Collecting Diagnostic Information

When reporting an issue, provide at least:

- Windows version, build number, and Desktop Experience or Server Core
- Device model, USB-to-serial chipset, and COM number
- The original business application name and the operation during which the issue occurred
- An exact installation/restart/test/uninstall timeline
- Desktop status-bar error text
- Output from the status script run as administrator
- Windows System and Application events
- The `code` and `correlationId` from the AI error
- A minimal session export that can be shared publicly, together with its SHA-256 (do not upload sensitive business data)

For a rigorous reproduction, also retain sender logs, receiver logs, the session database/export, and file hashes.
