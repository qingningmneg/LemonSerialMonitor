# Lemon Serial Monitor Installation and Uninstallation

[简体中文](INSTALL.md) | [English](INSTALL.en.md)

This document explains how to install, reboot, verify, migrate, and fully uninstall the official installer package. Regular users only need to double-click the installer; they do not need to open a console.

## Confirm Before Installation

The installer accepts the following x64 compatibility targets:

- Windows 10 and Windows 11
- Windows Server 2019, 2022, and 2025 with Desktop Experience
- Windows Server 2019, 2022, and 2025 Server Core

Installation requires local administrator privileges. The driver currently uses a local test certificate rather than Microsoft production signing, so the following conditions must also be met:

- Secure Boot must be disabled; setup stops if it detects that Secure Boot is enabled.
- If BitLocker or device encryption is enabled, first confirm that the recovery key is available.
- Setup may enable `TESTSIGNING`; that change takes effect only after a reboot.
- Obtain permission from the administrator or security team before installing on a company-managed computer.

Setup does not disable Secure Boot, suspend or modify BitLocker, or use `nointegritychecks` to bypass Windows security mechanisms.

The 0.1.0 installation files use local test signing and have no Microsoft trust chain and no RFC 3161 public timestamp. The test certificate cannot be imported until setup has obtained administrator privileges, so the first run may still show SmartScreen or **Unknown publisher** (`未知发布者`); this is not production code signing. Download only from this project's Release and verify the SHA-256.

## Verify After Downloading

Download the installer only from this project's GitHub Releases page. The release page also provides `SHA256SUMS.txt`; you can optionally verify it with PowerShell:

```powershell
Get-FileHash '.\LemonSerialMonitor-Setup-x64.exe' -Algorithm SHA256
```

The displayed SHA-256 must match the value on the release page for the same version. Do not run the file if its source or hash does not match.

## One-Click Installation

1. Double-click `LemonSerialMonitor-Setup-x64.exe`.
2. If Windows shows SmartScreen or **User Account Control** (`用户账户控制`), continue only after confirming that the download source and SHA-256 match the same-version Release.
3. Read the **Local Test Certificate Notice** (`本地测试证书使用说明`) in full, select the acceptance checkbox, and continue.
4. Choose the desktop application installation location. The default is:

   ```text
   C:\Program Files\Lemon串口监控
   ```

5. Choose whether to create a desktop shortcut.
6. On the **Ready to Install** (`准备安装`) page, verify the installation mode, target location, and test-signing notice.
7. Click **Install** (`安装`). Setup automatically validates the payload, certificate, system, directories, and existing installation state.
8. After installation, reboot when prompted. If a reboot is required, do not assess driver availability before rebooting.

If a Windows certificate confirmation window appears during installation, compare the displayed certificate fingerprint with `BUILD-INFO.json` from the same Release. If they do not match, select **No** (`否`) and cancel installation.

The installation process automatically performs the following actions:

- Validates the SHA-256 manifest for every file in the installer package.
- Validates the signing relationship among the driver, directory files, and test certificate.
- Imports the bundled public certificate precisely into the local machine's Root and TrustedPublisher certificate stores.
- Enables `TESTSIGNING` when required.
- Installs the serial-port filter driver and the LocalSystem background service.
- Appends the filter to the Ports class filter list while preserving other software's existing entries and their order.
- Installs the desktop application, AI/command-line interface, documentation, Start menu entry, and uninstaller.
- Writes a protected, integrity-checked installation record for rollback on failure and future uninstallation.

If the installation scripts find any identity, path, permission, hash, or signature mismatch, they stop and attempt to roll back the steps already completed during this installation.

## Installation Location Details

The location selected in the installation wizard is for the desktop application. To prevent regular users from replacing high-privilege service files, setup fixes the following directories and protects them with restricted permissions:

- Background service and driver files: an internal core directory under `%ProgramFiles%`
- Sessions, exports, and logs: an internal data directory under `%ProgramData%`
- Installation state and uninstall helper: `%ProgramData%\LemonSerialMonitor\Installer`
- AI lease for the currently authorized user: that user's `%LocalAppData%\LemonSerialMonitor\AI`

These internal directories do not need to be changed manually. The desktop application's executable is `Lemon.SerialMonitor.exe`. After desktop installation finishes, launch it from the Start menu or desktop shortcut; the complete PDF user manual can also be opened directly from the Start menu.

## Windows Server

Desktop Experience installs the complete desktop application, service, driver, AI interface, and documentation.

Server Core automatically omits the WPF desktop application and shortcuts, and installs only:

- Serial-port filter driver
- Background capture service
- AI/MCP/command-line interface
- Status, installation, and uninstallation support files
- Documentation

On Server Core, use the AI command line or MCP interface; see the [AI Integration Guide](AI_INTEGRATION.en.md). Setup accepts only known release builds of 2019, 2022, and 2025. It stops on unknown Server builds to avoid treating an unverified version as compatible.

Hosted desktop-runner checks on Windows Server 2022/2025 covered platform detection, managed tests, and installation-contract checks, but did not load the kernel driver. Server Core had component-layout contract tests only; the Server 2019 self-hosted job was not run. Before the 0.1.0 release, no physical or virtual Server system received end-to-end acceptance testing covering driver installation, reboot, capture, AI, and uninstallation. These versions are therefore compatibility targets, not completed hardware certifications. For important environments, first validate the full workflow on a test machine running the same version.

## Migrating from an Older Manual Installation

If the computer has an earlier version installed by this project's scripts, setup displays **Migration** (`迁移`) mode. Migration runs only when the old installation record, backups, service path, driver package, filter, and certificate can all be verified against one another.

Migration first creates a protected backup, then stops the old service, moves the old files, and installs the new version. If it fails midway, it restores the old service and files according to the transaction record. If setup detects an ambiguous identity, multiple candidate driver packages, or modified old files, migration refuses to continue; do not delete records manually and force an overwrite.

## Verification After Reboot

On desktop systems:

1. Open `Lemon串口监控` (Lemon Serial Monitor).
2. Click **Refresh Ports** (`刷新端口`).
3. The status bar should show **Service Connected** (`服务已连接`), and the driver status should not indicate a development fake-data source.
4. Select a port, click **Start** (`开始`), and let the original business application complete an actual send-and-receive operation.
5. Read, Write, or Ioctl events should appear in the **List** (`列表`).

If the computer currently has no serial-port device, the background service should still remain running. After clicking **Refresh Ports**, a **Service Connected** status, an empty port list, and a **Driver Temporarily Unavailable** (`驱动暂不可用`) status are normal. Connect a real serial-port device and refresh again; there is no need to reinstall repeatedly because of this state.

Administrators can also run the read-only status script supplied with the installation:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File "$env:ProgramData\LemonSerialMonitor\Installer\scripts\Get-CommMonitorStatus.ps1"
```

Pay particular attention to the platform, Secure Boot, `TESTSIGNING`, test certificate, Ports class filter, driver service, background service, control device, and whether a reboot is required.

## Updating During Normal Use

The current 0.1.0 installer does not perform an in-place overwrite of an existing modern installation. When a new version is released:

1. **Stop** (`停止`) monitoring.
2. Export or back up the data you need to retain.
3. Perform a full uninstall with the old version's uninstaller.
4. Reboot when prompted and wait for cleanup to finish.
5. Install the new version.

Do not directly overwrite a running service, driver, or installation-state file.

## Full Uninstall

Recommended entry point:

1. Open Windows **Settings** (`设置`).
2. Go to **Apps** (`应用`) → **Installed apps** (`已安装的应用`).
3. Find `Lemon串口监控` (Lemon Serial Monitor).
4. Click **Uninstall** (`卸载`).
5. Read and confirm the data-deletion warning.
6. Allow administrator privileges.
7. If prompted to reboot, save your work and restart the computer; after reboot, the uninstaller automatically continues and verifies the result.

When troubleshooting a broken Windows Settings entry, an administrator can instead run the uninstaller from the protected installer directory in an elevated session:

```text
%ProgramData%\LemonSerialMonitor\Installer\unins000.exe
```

It is normal for regular users to be unable to browse this protected directory directly. For routine uninstallation, always use the Windows Settings entry above.

A full uninstall permanently deletes:

- This software's desktop application, AI client, documentation, and shortcuts
- Background service and serial-port filter driver
- Ports class filter entries added by this software
- Test certificates actually owned by this installation
- Sessions, exports, settings, logs, caches, and AI state
- Installation records, migration backups, and uninstall-continuation tasks

Uninstall cleans up only according to the protected installation record and exact object identities; it does not delete other software by fuzzy name matching. If the service path, driver INF, certificate fingerprint, or file identity does not match, uninstall stops the corresponding deletion to avoid removing an external object.

If this installation enabled `TESTSIGNING`, uninstall restores it to disabled and requires a reboot. If `TESTSIGNING` was already enabled before installation, uninstall does not change the user's existing policy.

After uninstallation starts, it actively closes this software's desktop application, AI client, and background service. Normal user-mode files should not require a reboot merely because this software itself is still running; the Ports class filter, kernel driver, boot policy, or Windows file locks may still require cleanup after reboot.

## Retaining Data Before Uninstallation

The simplest method is to stop monitoring in the desktop application, export CSV, TXT, or RAW, and copy the exported files outside this software's data directory.

To retain the complete session database, first stop monitoring, then have an administrator back up the entire Sessions directory, including the matching `-wal` and `-shm` files. Do not copy only the main database and then delete the WAL.

## Uninstallation Problems

- File-in-use prompt: close the desktop application and any tools using the relevant files, then reboot when prompted.
- Items remain after reboot: do not manually delete services or registry entries. Keep the uninstall log and prompt text, and collect status information as described in [Troubleshooting](TROUBLESHOOTING.en.md).
- Installation record is damaged or missing: uninstall refuses to guess ownership by name. First restore the protected record for the same version or perform a manual identity review; do not use wildcard cleanup.
- The original serial port behaves abnormally after installation: stop monitoring, perform a full uninstall, and reboot. Retain the business application's logs, status output, and Windows system events for diagnosis.

## Installation Logs

On the failure page, the installation wizard displays the error. The Inno Setup log, protected transaction result, and Windows service/driver events are the primary evidence for diagnosing installation problems. When submitting an issue, include:

- Windows version and build number
- Desktop Experience or Server Core
- Exact time of installation or uninstallation
- Complete error text from the installation wizard
- Whether the computer has been rebooted
- Secure Boot, BitLocker, and `TESTSIGNING` states
