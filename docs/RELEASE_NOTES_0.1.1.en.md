# Lemon Serial Monitor 0.1.1 Release Notes

[简体中文](RELEASE_NOTES_0.1.1.md) | [English](RELEASE_NOTES_0.1.1.en.md)

Version 0.1.1 is a maintenance and release-integrity update relative to 0.1.0. It focuses on license distribution, equivalent bilingual public documentation, and version consistency; it is not a release of new capture, UI, or AI features.

## What Changed

- The root [MIT License](../LICENSE) is the canonical license text. Individuals and companies may use the software free of charge, including for commercial and for-profit purposes, and may modify, merge, publish, redistribute, sublicense, and sell copies. Any copy or substantial portion of the software must retain the `Copyright (c) 2026 qingningmneg` copyright notice and the MIT license notice.
- The installed files now include `docs\LICENSE.txt`. Setup also retains the third-party source and license notice for the Inno Setup Simplified Chinese translation; a third-party translation helps with understanding but does not replace the corresponding canonical license text.
- The public Release adds a separate `LICENSE.txt` as its sixth public file, so the complete MIT terms can be read before installation.
- The README, installation, build, security, discovery, and download copy is now equivalent in Chinese and English, while retaining the stable installer download name.
- The product version, Windows file version, installer, installation, uninstall, build, and release verifier are aligned to product version `0.1.1`; the Windows file version remains `0.1.1.0`.

## Release Assets

Each 0.1.1 public release directory contains exactly these six ordinary files:

1. `Lemon串口监控-安装程序-x64.exe`
2. `Lemon串口监控-完整操作手册.pdf`
3. `RELEASE-NOTES.md`
4. `BUILD-INFO.json`
5. `LICENSE.txt`
6. `SHA256SUMS.txt`

`SHA256SUMS.txt` lists and verifies only the other five files, excluding the manifest itself. Verify the same-version manifest before running Setup.

## Installation and Security

Version 0.1.1 still uses a local test certificate, not Microsoft WHQL, Attestation, or production signing. The release files have no Microsoft production trust chain and no RFC 3161 public timestamp; local test signing is not a substitute for production release signing.

Setup verifies the payload, certificate, and hashes, imports the public certificate after explicit consent, and enables `TESTSIGNING` when required. Changes to system policy and loading the Ports class filter may require a restart. The software does not disable Secure Boot; installation stops when Secure Boot is enabled or organizational policy prohibits `TESTSIGNING`.

Version 0.1.1 does not perform an in-place overwrite of an existing modern installation. Do not directly overwrite a running service, loaded driver, or protected installation record.

## Functional Boundaries

- Monitoring is passive and read-only: the desktop application and AI client do not open the monitored COM port, and the kernel filter driver only copies read, write, and supported control events that have already occurred.
- The software does not provide active sending, injection, modification, blocking, or replay of serial data.
- The CLI and MCP work only through protected local interfaces and read persisted capture events through pagination. They do not listen on HTTP/TCP or provide arbitrary file access.

## Evidence Boundary

Version 0.1.0 is the historical baseline for the existing physical Windows 11 and automated/contract Windows Server validation. Version 0.1.1 adds no new physical serial-device acceptance, Windows Server kernel-driver end-to-end acceptance, or full installation acceptance, and makes no universal-compatibility, hardware-certification, or production-signing claim.

The historical Windows Server 2022/2025 evidence covers only platform detection, managed tests, and installation-contract checks on GitHub-hosted desktop runners; it did not load the kernel driver. Server Core received component-layout contract tests only, and the Server 2019 self-hosted job was not run. Important environments must still validate driver installation, restart, capture, AI, and uninstall end to end on a test machine running the same version.

## Upgrade and Uninstall

To update from an older version, stop monitoring and export or back up the data you need to keep, then perform a full uninstall with the old version's uninstaller. Restart when prompted and wait for cleanup to finish before installing 0.1.1. Do not overwrite the old version in place.

Full uninstall permanently deletes this software's sessions, exports, settings, logs, caches, and AI state, along with the services, driver, filter, certificates, and program files owned by the software. First copy any data that must be retained outside the software-managed directories.
