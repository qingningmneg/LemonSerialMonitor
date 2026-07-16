# Lemon Serial Monitor User Guide

[简体中文](USER_GUIDE.md) | [English](USER_GUIDE.en.md)

## Four Things to Remember

1. The software monitors communication that has already occurred; it does not actively send data to the device.
2. After selecting a port, you must still click **Start** (`开始`).
3. After **Start**, the original business application must actually read from or write to the same COM port.
4. When finished, click **Stop** (`停止`) before copying, exporting, or closing the window.

## First Use

1. Start the business application that normally uses the serial port and connect the device in the usual way.
2. Start Lemon Serial Monitor (the main executable is `Lemon.SerialMonitor.exe`).
3. Click **Refresh Ports** (`刷新端口`). The currently detected COM ports appear on the left.
4. Select one or more ports to monitor.
5. Enter a file name in the **Session** (`会话`) box, for example `board-test.db`. Enter only a file name here, not an arbitrary directory.
6. Click **Start** (`开始`).
7. Return to the original business application and perform sending, querying, upgrading, or other communication operations.
8. Confirm that events appear in the **List** (`列表`).

To monitor multiple ports at the same time, select several ports before starting. The software does not open those COM ports on behalf of the original business application merely because they are being monitored.

If no serial device is connected to the computer, an empty list after refresh is normal. The background service should remain running, and the status bar may show that the service is connected while the driver is temporarily unavailable. Connect a device and refresh again.

## Start, Pause, Resume, Stop, and Clear

- **Start** (`开始`): Creates the specified session or continues writing to it, and begins receiving monitored copies from the selected ports.
- **Pause** (`暂停`): Business serial communication continues normally, but monitored copies are not recorded while paused.
- **Resume** (`继续`): Resumes monitoring records for the current session.
- **Stop** (`停止`): Ends the current capture; recorded data and UI content are retained.
- **Clear** (`清空`): Permanently deletes records from the session currently bound by the service and clears the UI. The operation asks for confirmation again.

**Clear** (`清空`) is not an ordinary clear-screen operation. To start a separate recording, stop first, choose a new session file name, and start again.

Closing the desktop window does not automatically press **Stop** for you. Develop the habit of following the sequence **Stop → export/record → close**.

## Automatic Session Saving

After you click **Start**, events are written continuously to a protected local session database; there is no need to press **Save** again. The default session name is `capture.db`.

Reusing the same session file name continues writing to that database. Changing the session name while a capture is running affects only the next start; it does not switch the active capture to a new file.

The desktop UI primarily displays live events received after the current connection. To read historical sessions through automation, use the AI/command-line interface. When handing data to another tool or person, use **Export** (`导出`).

## Three Views

### List

The **List** (`列表`) is suitable for event-by-event analysis and contains:

- Sequence and time
- The process that initiated the operation
- COM port
- Read, Write, or Ioctl direction/type
- IOCTL operation code and NTSTATUS
- Completed length and event flags
- HEX data and text preview

Hold `Ctrl` or `Shift` to select multiple rows. After you select a List event, the Dump and Terminal views locate the same underlying event.

### Dump

The **Dump** (`Dump`) view displays 16 bytes per row: the offset on the left, HEX in the middle, and printable ASCII on the right. It is useful for checking protocol frames, field offsets, checksums, and binary content.

### Terminal

The **Terminal** (`终端`) displays only Read and Write payloads; it does not display configuration-only Ioctl events. The default colors are blue for Read and red for Write.

Available encodings:

- ANSI
- UTF-7
- UTF-8
- UTF-16LE
- UTF-16BE

You can also show or hide **Time** (`时间`), **Port** (`端口`), and **Direction** (`方向`), and toggle **Word Wrap** (`自动换行`) and **Auto Scroll** (`自动滚动`). Changing the encoding affects only new data that arrives afterward; it does not reinterpret content already displayed.

## Find

### HEX Find

Select **HEX** (`HEX`) as the find type and enter space-separated bytes:

```text
01 03 00 FF
```

`??` represents any single byte:

```text
03 ?? FF
```

Do not use the `0x` prefix or write bytes without spaces, such as `010300FF`. Clicking **Previous** (`上一个`) or **Next** (`下一个`) searches cyclically from the current position.

### Text Find

After selecting **Text** (`文本`), enter ordinary text. The search interprets payloads as UTF-8 and ignores case. For a binary protocol or data in a non-UTF-8 encoding, prefer HEX find.

## Copy Data

This is the most commonly used function in the software:

1. Select one or more rows in the List; you can also select the corresponding event in Dump or Terminal.
2. Choose a format to the right of **Copy Data** (`复制数据`).
3. Click **Copy Data** (`复制数据`), or press `Ctrl+C`.

Eight formats are available:

- **HEX (spaced)** (`HEX（空格）`): `01 03 00 00 00 02`
- **HEX (compact)** (`HEX（紧凑）`): `010300000002`
- **Text** (`文本`): copies the payload as UTF-8
- **C array** (`C 数组`): suitable for firmware or C/C++ test code
- **Python bytes** (`Python bytes`): suitable for Python scripts
- **TSV** (`TSV`): suitable for pasting directly into a spreadsheet
- **CSV** (`CSV`): suitable for saving or importing into a data tool
- **JSON** (`JSON`): retains event fields for programmatic processing

Keyboard shortcuts:

- `Ctrl+C`: Uses the format selected in the current drop-down list.
- `Ctrl+Shift+C`: Ignores metadata and copies only the selected payloads concatenated in event order as space-separated HEX.

When multiple rows are selected, HEX, text, C array, and Python bytes concatenate the raw payloads in event order. To retain the port, direction, time, and event boundaries, choose TSV, CSV, or JSON.

## Export

Export is available only while stopped:

1. Click **Stop** (`停止`).
2. Enter a safe file name in the export-file box, for example `board-test.csv`.
3. Select CSV, TXT, or RAW.
4. Click **Export** (`导出`).
5. After success, the output location appears on the right side of the status bar.

Export includes all persisted records in the session currently bound by the service, not only the selected rows, and it does not necessarily equal the rows still visible in the UI.

- **CSV**: Contains structured fields and is suitable for Excel, scripts, and archiving.
- **TXT**: A text representation convenient for human inspection.
- **RAW**: Concatenates raw payloads in order for further binary processing; it does not retain event boundaries or metadata.

An export with the same name replaces the old file. Choose a different file name first if you need to retain the old result.

The AI interface additionally supports JSON and JSONL exports.

## Reading the Status Bar

- **Service** (`服务`): Whether the desktop application is connected to the background capture service.
- **Driver** (`驱动`): The state of the driver or development data source.
- **Events** (`事件`): The number of events cumulatively received by the current UI.
- **Dropped** (`丢失`): The number of UI queue overflows or received drop notices.
- Green text on the right: The result path for export and similar operations.
- Red text on the right: The current error.

When there is no serial device, the filter driver has no device stack to attach to. **Service connected, driver temporarily unavailable, and an empty port list** is a normal combination; it does not mean that the service crashed and does not require repeated reinstallations.

"Dropped = 0" alone cannot prove that the entire path had absolutely no loss. For a rigorous conclusion, also inspect event `Truncated`/drop flags, the AI integrity fields, the original business logs, and independent send/receive counts.

## Capacity Limits

- A single kernel capture event stores at most 4096 bytes; longer data carries a truncation flag.
- The List retains the most recent 100,000 rows. Older rows are removed from the UI, but persisted events remain in the session.
- The Terminal retains approximately 2 MiB of visible text and trims the oldest portion when the limit is exceeded.
- The UI pending queue holds at most 10,000 items and records drops when the UI cannot keep up.

For high-throughput or long-running tests, prefer the session database and AI pagination; do not rely only on the current screen contents.

## Direction Conventions

- `Write` / `TX`: From the computer to the device.
- `Read` / `RX`: From the device back to the computer.
- `Ioctl`: Control operations such as baud rate, timeout, line control, flow control, DTR/RTS, and buffer clearing.

## End-of-Day Checklist

- You clicked **Stop**.
- You exported or copied the required data.
- For analysis that must account for possible loss, you recorded the session name, time range, and original business-application logs.
- Before full uninstall, you copied any files that must be retained outside the software's directories.

## AI and Automation

Without opening the desktop UI, AI clients, scripts, or development tools can list ports, control capture, read historical sessions, wait for new events, and export. The interface works only through a local named pipe and does not send serial data.

Start with the [AI Integration Guide](AI_INTEGRATION.en.md); see the [AI Interface Reference](AI_API_REFERENCE.en.md) for fields and integrity decisions.
