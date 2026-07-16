# Lemon Serial Monitor

[简体中文](README.md) | [English](README.en.md)

I built this tool to inspect serial-port communication that has already occurred on Windows while changing as little as possible about how the original software uses the port. A kernel filter driver copies serial-port read and write events. The desktop application itself does not open the COM port, so the original application remains the port's actual user.

The current version is `0.1.0`. It provides a Windows x64 installer, a desktop monitoring UI, a command-line interface, and an MCP interface. It is free for personal use. The repository currently has no open-source license: you may inspect the code and download the software for personal use, but do not rename and republish the code or installer without separate permission.

## Download and installation

The official installer is published on the project's GitHub **Releases** page under this filename:

```text
LemonSerialMonitor-Setup-x64.exe
```

You do not need to open PowerShell to install it:

1. Double-click the installer.
2. Read and accept the **Local Test Certificate Notice** (`本地测试证书使用说明`).
3. Choose where to install the desktop application.
4. Click **Install** (`安装`) and grant administrator permission when Windows prompts you.
5. If setup asks for a restart, save your work and restart as instructed. Open the application after Windows has restarted.

The current driver uses a local test certificate; it is not signed with Microsoft production signing. Setup verifies the installation package, imports the bundled public-key certificate, and may enable Windows `TESTSIGNING` when required. It does not disable Secure Boot or modify BitLocker. Setup stops when Secure Boot is enabled.

The test certificate cannot be imported until setup has administrator permission, so Windows may still show SmartScreen or “Unknown publisher” when you first double-click the installer. The 0.1.0 release files are locally test-signed, but they have no Microsoft trust chain and no RFC 3161 public timestamp. Download them only from this project's Release and verify `SHA256SUMS.txt` first.

Version 0.1.0 does not support overwriting an existing installation made by the current installer. Before updating, stop monitoring and back up your data, perform a full uninstall with the old version, restart if prompted, and then install the new version.

See [Installation and uninstall](docs/INSTALL.en.md) for the complete instructions.

The complete operating manual is available in Simplified Chinese: [PDF manual (Simplified Chinese)](manual/Lemon串口监控-完整操作手册.pdf) and [Word manual (Simplified Chinese)](manual/Lemon串口监控-完整操作手册.docx).

## Compatibility targets

- Windows 10 x64
- Windows 11 x64
- Windows Server 2019 x64 (Desktop Experience / Server Core)
- Windows Server 2022 x64 (Desktop Experience / Server Core)
- Windows Server 2025 x64 (Desktop Experience / Server Core)

Server Core does not install the WPF desktop application. It installs only the driver, background service, AI/command-line interfaces, and documentation. Setup rejects x86, ARM64, unknown Windows Server builds, and environments where Secure Boot is enabled.

The current 0.1.0 code candidate completed graphical installation, restart, service cold start, desktop connection, JSON CLI, and MCP checks on a physical Windows 11 x64 system. The candidate validation chain also completed a full uninstall of the previous candidate and a clean installation of the current code candidate. When no serial device is attached, the background service remains running. After you click **Refresh Ports** (`刷新端口`), an empty port list and a temporarily unavailable driver are normal; attach a real device and refresh again.

GitHub-hosted desktop runners for Windows Server 2022/2025 completed platform detection, managed tests, and installation-contract checks, but did not load the kernel driver. Server Core received component-layout contract tests only, and the Server 2019 self-hosted job was not run. No physical or virtual Server system received end-to-end acceptance testing for driver installation, restart, capture, AI, and uninstall in this release. These versions are compatibility targets, not hardware certification. See the [0.1.0 release notes](docs/RELEASE_NOTES_0.1.0.en.md) for the exact scope.

## Main features

- Monitor Read, Write, and configuration/control events on one or more serial ports without having the desktop application occupy the COM port.
- Three views: **List** (`列表`), **Dump**, and **Terminal** (`终端`).
- Display time, process, port, direction, operation code, status, length, flags, HEX, and text.
- Wrap-around HEX and text search; HEX accepts `??` as a single-byte wildcard.
- Copy multiple selected rows as spaced HEX, compact HEX, text, a C array, Python `bytes`, TSV, CSV, or JSON.
- `Ctrl+C` uses the currently selected copy format; `Ctrl+Shift+C` copies only the continuous spaced HEX data.
- Automatically persist sessions to a protected local database, then export CSV, TXT, or RAW after stopping.
- Use the local AI interface for status, ports, start/pause/resume/stop, session lists, paginated reads, waiting for new events, export, and protocol descriptions.
- Use a standard MCP stdio server. The AI interface does not expose an HTTP port and does not accept sending, injection, replay, or arbitrary file access.
- Run a graphical full uninstall that uses the protected installation record to remove software-owned files, services, drivers, filters, certificates, and data.

## Start monitoring in three minutes

1. Open the original application that uses the serial port and let it connect to the device normally.
2. Open Lemon Serial Monitor and click **Refresh Ports** (`刷新端口`).
3. Select the COM ports you want to inspect and enter a session filename such as `board-test.db`.
4. Click **Start** (`开始`).
5. Let the original application actually send or read data.
6. Switch among **List** (`列表`), **Dump**, and **Terminal** (`终端`) to inspect it.
7. When finished, click **Stop** (`停止`) first, then copy or export as needed.

If the list is empty, first confirm that you clicked **Start** and that the original application actually read from or wrote to the same COM port after monitoring started. The monitoring tool does not actively send data to the device.

With no serial device attached, seeing **Service connected** (`服务已连接`), an empty port list, and a temporarily unavailable driver after a refresh is normal. It does not mean the background service failed to start.

See the [User guide](docs/USER_GUIDE.en.md) for the complete UI instructions and [Troubleshooting](docs/TROUBLESHOOTING.en.md) for problem resolution.

## AI integration

The installed AI client is located here by default:

```text
C:\Program Files\Lemon串口监控\ai\Lemon.SerialMonitor.AI.exe
```

If you chose another installation location, use the actual path.

Quick command-line checks:

```powershell
& 'C:\Program Files\Lemon串口监控\ai\Lemon.SerialMonitor.AI.exe' status --json
& 'C:\Program Files\Lemon串口监控\ai\Lemon.SerialMonitor.AI.exe' ports --json
```

Example MCP configuration:

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

See the [AI integration guide](docs/AI_INTEGRATION.en.md) for detailed setup steps. Commands, tools, fields, and integrity rules are documented in the [AI API reference](docs/AI_API_REFERENCE.en.md).

## Data and complete uninstall

Sessions and export files are stored by default in a protected `%ProgramData%` data directory. The uninstaller gives an explicit warning: **a full uninstall permanently deletes every session, export, setting, log, and AI state item produced by this software**. Export or back up anything you need to keep before uninstalling.

Start a full uninstall from **Settings → Apps → Installed apps**, select **Lemon串口监控** (Lemon Serial Monitor), and choose **Uninstall**. The uninstaller first closes the desktop application, AI client, and background service. Cleanup relies on the protected installation record and exact object identity; if an identity does not match, uninstall stops that deletion rather than guessing ownership. Only when the Windows kernel is still using the driver, a boot policy must be restored, or a file remains locked by the system does uninstall schedule a restart to continue cleanup and verify the remaining objects again.

## Build from source

The repository already contains the validated DOCX/PDF manuals required to build the installer. Building from source also requires Visual Studio 2022, the WDK, Spectre libraries, the .NET SDK, Pester, and Inno Setup 6.7.3. See [Build instructions](docs/BUILD.en.md) for the build, signing, test, and installer commands.

See [Security](docs/SECURITY.en.md) for the security boundaries and threat model, and the [0.1.0 release notes](docs/RELEASE_NOTES_0.1.0.en.md) for version changes.

## Independent implementation

This project's code, protocols, session format, installation flow, and UI are independently implemented. It contains no binaries, icons, trademarks, private code, or other assets from other serial-port software.
