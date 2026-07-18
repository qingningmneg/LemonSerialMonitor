# Lemon Serial Monitor Security Notes

[简体中文](SECURITY.md) | [English](SECURITY.en.md)

## Design Boundaries

The software's monitoring function is read-only: it does not actively send, inject, modify, block, or replay serial data. The desktop application and AI client do not directly open the monitored COM port; the kernel filter driver participates in the Ports class device stack and copies completed read, write, and control events.

"Does not occupy the COM port" does not mean that no driver participates in the system. Any kernel filter driver should first be validated in a recoverable environment. For business-critical devices, retain the original software logs and an uninstall rollback plan.

## Local Test Signing

Version 0.1.1 uses a local test certificate; it is not Microsoft WHQL, Attestation, or production signing:

- The installer carries only the public `.cer` certificate, not the private key.
- The test certificate private key on the build machine is marked non-exportable.
- Before changing the system, Setup verifies the SYS, CAT, EXE, and CER fingerprints together with the payload SHA-256 values.
- Setup imports the exact certificate into LocalMachine Root and TrustedPublisher.
- Uninstall removes only the certificate entries actually owned and recorded by this installation.
- Installation may enable `TESTSIGNING`; uninstall disables it only if Setup actually changed it.

Installation stops when Secure Boot is enabled. The software does not disable Secure Boot, modify BitLocker, or bypass code integrity.

The 0.1.1 release files have no Microsoft trust chain and no RFC 3161 public timestamp. When Setup is first run, the test certificate has not yet been imported, so Windows may still show SmartScreen or "Unknown publisher". Local test signing is not a substitute for production release signing. After downloading, first verify the file against `SHA256SUMS.txt` from the Release; verify the certificate fingerprint against `BUILD-INFO.json` from the same build.

## Privileged Files

The service runs as LocalSystem, so the service, driver, uninstall helper, and installation state reside in locations that ordinary users cannot write. Installation and uninstall reject:

- Reparse points, symbolic links, or path traversal
- Untrusted owners or directories writable by ordinary users
- File hashes, sizes, paths, or product markers that do not match the records
- Services, driver packages, certificates, or shortcuts whose identities are unclear
- Transactions across unsupported volumes or unsafe root directories

The installation state uses a protected key and HMAC integrity verification, and physical file identities are also recorded for critical root directories. Uninstall cleans up by exact ownership; it does not delete by wildcard name matching.

## AI Interface

The AI interface does not listen on HTTP or TCP and uses only a local named pipe. The service verifies the Windows SID, logon LUID, client image path, and SHA-256. The initial request has a timeout, and an identity mismatch is disconnected before the request is read, preventing unauthorized or idle connections from exhausting pipe instances.

The AI lease secret is protected by DPAPI for the current user. MCP/CLI return values do not expose the lease secret. The interface does not provide arbitrary-path, send, inject, delete, clear, or overwrite operations.

## Data

Sessions, exports, logs, and installation state are all stored locally. The software does not upload data by itself. Before filing a public issue, check whether the serial payload contains keys, device identifiers, accounts, tokens, customer information, or firmware content.

Full uninstall deletes all data managed by this software by default. Any exports that must be retained must first be copied outside directories managed by the software.

## Integrity Evidence

The kernel ring buffer, service persistence, and client display all have capacity limits. Rigorous analysis cannot rely only on what is visible on screen:

- Check for truncation, driver drops, service drops, and sequence gaps.
- On every AI page, check `completeForReturnedRange` and `continuityProven`.
- Retain independent sender/receiver logs, event counts, and file SHA-256 values.
- Do not treat a text preview as raw-byte evidence.

## Reporting a Security Issue

Create a minimal reproduction that contains no sensitive serial data, and include the Windows build, hardware, installation method, exact timeline, and relevant `correlationId`. For potentially exploitable issues involving privileged paths, signing, pipe identity, or uninstall ownership, do not first publish session data or attack details; submit a private report through **Security → Report a vulnerability** in the GitHub repository.
