# Lemon Serial Monitor 0.1.0 Release Notes

[简体中文](RELEASE_NOTES_0.1.0.md) | [English](RELEASE_NOTES_0.1.0.en.md)

This is the first installable free and open-source release, intended for personal testing and hardware/software integration.

## What This Release Provides

- Windows x64 upper filter driver for the serial-port class
- LocalSystem capture and session service
- WPF List, Dump, and Terminal views
- Multi-port selection, Start, Pause, Resume, Stop, and confirmed Clear
- HEX/text search and eight copy formats
- CSV, TXT, and RAW desktop export
- JSON, JSONL, CSV, TXT, and RAW AI export
- Local JSON CLI and standard MCP stdio interface
- Graphical installation, migration from old manual installations, rollback on failure, and full uninstall
- Platform-specific handling for Windows 10/11 and Windows Server 2019/2022/2025

## Open-source License

The project is open source under the [MIT License](../LICENSE). Individuals and companies may use it free of charge, including for commercial and for-profit purposes, and may modify, merge, publish, redistribute, sublicense, and sell copies. Any copy or substantial portion of the software must retain the `Copyright (c) 2026 qingningmneg` copyright notice and the MIT license notice.

The public Release also includes `LICENSE.txt` separately, so the full license can be read without running the installer; `SHA256SUMS.txt` verifies that file as well.

## Special Installation Notes

The driver uses a local test certificate, not Microsoft production signing. Setup explicitly obtains consent before importing the public certificate and enables `TESTSIGNING` when required. It does not install while Secure Boot is enabled. Changes to system policy and loading the Ports class filter may require a restart.

The installation file is locally test-signed but has no Microsoft trust chain and no RFC 3161 public timestamp. On first run, the test certificate has not yet been imported, so Windows may still display SmartScreen or "Unknown publisher." Download only from this project's Release and verify `SHA256SUMS.txt`.

## Known Boundaries

- The desktop UI focuses on live events and does not reload historical sessions into its three views. Historical paginated reads are available through the AI/command-line interface.
- Desktop export supports CSV, TXT, and RAW; use the AI interface for JSON/JSONL.
- The per-event capture limit is 4096 bytes. Longer events are marked as truncated.
- The List and Terminal views have visible capacity limits. Persisted sessions and AI integrity fields are the primary basis for long-running analysis.
- There is currently no active sending, injection, replay, protocol simulation, Modbus decoding, or arbitrary file access.
- This test-signed release is unsuitable for organizational devices on which Secure Boot cannot be disabled or `TESTSIGNING` is prohibited.
- Version 0.1.0 does not perform an in-place overwrite of an existing modern installation. Before updating, export or back up the data, fully uninstall the old version, restart as prompted, and then install the new version.
- The background service continues to run normally when no serial-port device is connected. An empty port list and a temporarily unavailable driver after refresh are normal in this state.

## Validation Scope

- Windows 11 Pro x64 (build 26100): the current code candidate completed graphical installation, restart, automatic background-service startup, desktop connection, JSON CLI, and MCP checks. The candidate validation chain also completed full uninstall of an earlier candidate and a clean installation of the current code candidate. During a cold start with no physical serial-port device, the background service remained `Running`, and the post-start Service Control Manager and .NET runtime logs contained no failure event for this software's service.
- No-device interface checks: `status --json`, `ports --json`, `schema --json`, and `sessions list --json` all succeeded. MCP completed protocol initialization, listed 11 tools and 4 resources, and actually called the status and port tools. The current port result is an empty array because no physical serial port was connected during acceptance testing.
- Physical serial-port evidence: during hardware integration of an earlier candidate on the same machine, 3653 events were recorded, with UI and service drop counts of 0. AI pagination covered all 3653 events, and the integrity result found no driver drops, service drops, or sequence gaps. Because the device was not present for the current code candidate, hot-plugging and sustained capture were not repeated.
- Automated gates: 615 managed tests, 919 PowerShell installation safety tests, 5 native C/C++ test groups, kernel protocol compilation, a WDK Release driver build and code analysis (0 diagnostics), INF validation, and a public-name audit.
- Windows Server 2022/2025 hosted GitHub desktop runners completed platform detection, managed tests, and installation-contract checks, but did not load the kernel driver. Server Core received component-layout contract tests only; the Server 2019 self-hosted job was not run. This release received no end-to-end acceptance testing for driver installation, restart, capture, AI, and uninstall on a physical or virtual Server system. The Desktop Experience and Server Core variants of 2019/2022/2025 are therefore compatibility targets, not hardware certification.

## Uninstall

Full uninstall deletes this software's service, driver, filter, certificate, programs, and all local data. First copy any exports that must be retained outside the software directory. Cleanup and verification for an in-use driver or file continue after the restart.
