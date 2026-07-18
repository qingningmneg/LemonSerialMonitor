# Lemon Serial Monitor Build Instructions

[简体中文](BUILD.md) | [English](BUILD.en.md)

This document is for developers who need to build, test, and generate the installer from source. Regular users should download the installer from the Release instead.

## Development Machine Requirements

- Windows x64
- Visual Studio 2022
- MSVC x64 C++ tools
- The Visual Studio WDK component and WDK 10.0.26100
- Spectre-mitigated libraries for the corresponding toolset
- The .NET SDK 10.0.301 specified by `global.json` (the project targets .NET 8)
- PowerShell 5.1 or later
- Pester 4.10.1
- Official Inno Setup 6.7.3

Install Inno Setup:

```powershell
winget install --id JRSoftware.InnoSetup --version 6.7.3 --exact
```

## Run Only the Managed Tests

```powershell
dotnet restore .\CommMonitor.sln
dotnet test .\CommMonitor.sln --configuration Release --no-restore --nologo
```

## Run the Installation Safety Tests

```powershell
Import-Module Pester
Invoke-Pester -Path .\tests\powershell -Output Detailed
```

## Build the Complete Payload

Unsigned development build:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Build-All.ps1 `
  -Configuration Release
```

Generate a payload for a locally test-signed installer:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Build-All.ps1 `
  -Configuration Release `
  -TestSignDriver
```

This command:

- Restores dependencies and runs all managed tests
- Runs all Pester installation/uninstallation safety tests
- Publishes the x64 self-contained desktop application, service, AI client, and uninstall helper
- Builds the x64 Release KMDF driver and runs code analysis
- Generates the CAT and creates or reuses a non-exportable test-signing certificate for the current user
- Locally test-signs the driver, catalog, desktop application, service, AI client, and uninstall helper
- Assembles `artifacts\phase1`
- Generates a strict `SHA256SUMS.txt`

## Generate the Single-File Graphical Installer

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Build-Installer.ps1 `
  -Configuration Release
```

By default, this first invokes the complete payload build. If you already have a verified payload, you can use `-SkipPayloadBuild`. Use `-SkipSigning` only when you explicitly need to retain an unsigned installer for debugging.

The default test-signing build does not request a public timestamp. Pass `-TimestampUrl` only when you have an available RFC 3161 HTTPS service and explicitly require it. Release records must accurately state whether the files actually carry a timestamp; do not describe an ordinary Authenticode signature as a production signature with a public timestamp.

Output:

```text
artifacts\installer\Lemon串口监控-安装程序-x64.exe
artifacts\release\0.1.0\
```

`artifacts\release\0.1.0` contains only six files that can be uploaded publicly: the installer, PDF user manual, release notes, build information, `LICENSE.txt`, and the SHA-256 manifest. `LICENSE.txt` is the project MIT license and can be read before installation; `SHA256SUMS.txt` covers the other five assets, excluding itself. The build script verifies the exact Inno Setup version and its official Authenticode publisher and rejects substitutes from unknown compilers. By default, it also locally test-signs the installer and, after assembly, rechecks the six files, version resources, signing certificate, and every hash for the five assets listed in the manifest.

The installation wizard uses the project's pinned Simplified Chinese translation file. Its source, commit, SHA-256, and MIT license are recorded in `installer\third-party\SOURCE.md` and the license file in the same directory.

If a release directory already exists, you can verify it independently again:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Test-ReleaseBundle.ps1 `
  -Version 0.1.0
```

On successful verification, the script outputs `Status: Verified`, the installer SHA-256, the signing-certificate fingerprint, and the file count. Verification fails if any file is added, missing, or modified in the directory.

## Build the User Manual

The repository's `manual` directory already contains DOCX and PDF files that have been inspected page by page. A normal source build uses these two files directly and does not require Python or LibreOffice to be installed first.

Regenerate the manual only when changing the manual-generation script or manual content. First install Python 3.12 and LibreOffice 26.2.4, then create an isolated environment and install the pinned versions:

```powershell
py -3.12 -m venv .\.venv-docs
& .\.venv-docs\Scripts\python.exe -m pip install `
  -r .\scripts\docs\requirements.txt
& .\.venv-docs\Scripts\python.exe `
  .\scripts\docs\build_commmonitor_manual.py
```

Copy the DOCX to a temporary directory whose path contains only English characters, convert it to PDF with an isolated LibreOffice profile, and then render every page. This avoids sharing a profile with a running LibreOffice instance and works around compatibility issues that some environments have with non-English paths:

```powershell
$manualStage = Join-Path $env:TEMP ("lemon-manual-" + [guid]::NewGuid().ToString("N"))
$manualInput = Join-Path $manualStage "input"
$manualOutput = Join-Path $manualStage "output"
$manualProfile = Join-Path $manualStage "profile"
New-Item -ItemType Directory -Path $manualInput, $manualOutput, $manualProfile | Out-Null
Copy-Item .\artifacts\manual\Lemon串口监控-完整操作手册.docx `
  (Join-Path $manualInput "manual.docx")

$profileUri = [uri]::new($manualProfile).AbsoluteUri
& "$env:ProgramFiles\LibreOffice\program\soffice.com" `
  "-env:UserInstallation=$profileUri" `
  --headless --nologo --nofirststartwizard --norestore `
  --convert-to pdf --outdir $manualOutput `
  (Join-Path $manualInput "manual.docx")

Copy-Item (Join-Path $manualOutput "manual.pdf") `
  .\artifacts\manual\Lemon串口监控-完整操作手册.pdf

& .\.venv-docs\Scripts\python.exe `
  .\scripts\docs\render_pdf_pages.py `
  .\artifacts\manual\Lemon串口监控-完整操作手册.pdf `
  --output-dir .\tmp\manual-render
```

You must inspect every page for missing characters, overlapping content, broken tables, and garbled text. After confirming that the result is correct, replace the files with the same names in the repository's `manual` directory with the newly generated DOCX/PDF, then rerun all tests and the installer build.

## Final Checks

```powershell
git diff --check
dotnet test .\CommMonitor.sln --configuration Release --no-restore --nologo
Invoke-Pester -Path .\tests\powershell -Output Detailed
```

Also check:

- The installer SHA-256
- That the EXE/SYS/CAT signer fingerprints match
- That the payload manifest has no missing files, extra files, or path escapes
- That public Git files contain no certificate private keys, tokens, user paths, logs, or session data
- Windows 10/11 and the Server platform/contract tests that were actually run; a hosted Server job cannot replace driver end-to-end acceptance testing
- Records for installation, restart, monitoring a real serial port, AI reads, full uninstall, and residual-state verification

Do not treat "compiled successfully" as "the installer is ready for release." A kernel-driver release requires real-system gates and evidence of recoverable uninstallation.
