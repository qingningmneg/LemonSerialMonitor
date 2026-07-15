# Lemon Installer and Release Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rename the user-visible product to Lemon串口监控 and deliver a signed, single-file Chinese GUI installer with selectable client location, transactional migration, complete safe uninstall, documentation, reproducible release bundle and private GitHub release.

**Architecture:** Official Inno Setup 6.7.3 provides the UAC-elevated GUI shell and durable uninstall entry; hardened PowerShell performs system transactions and emits structured JSON results. Privileged service/driver/security state remains under fixed protected roots, while a native .NET uninstall helper uses handle-based no-follow deletion for user-writable roots. Build scripts publish the WPF, service, AI and helper payloads, sign before hashing, render/verify the manual, and attach binaries to a GitHub Release rather than Git history.

**Tech Stack:** Inno Setup 6.7.3 x64, PowerShell 5.1+, C# 12/.NET 8 win-x64, Win32 handle APIs, KMDF/WDK 10.0.26100, Visual Studio 2022 17.x with Spectre libraries, Authenticode/SignTool, Pester, xUnit, Python document generator, Git/GitHub CLI.

## Global Constraints

- Visible product name is `Lemon串口监控`; main EXE is `Lemon.SerialMonitor.exe`; AI EXE is `Lemon.SerialMonitor.AI.exe`.
- Keep internal service `CommMonitorService`, driver/filter `CommMonitorFilter`, CoreRoot `%ProgramFiles%\CommMonitor`, DataRoot `%ProgramData%\CommMonitor`, and driver identifiers.
- Single installer output is `Lemon串口监控-安装程序-x64.exe`, version `0.1.0`, fixed AppId `{F5B0783F-74F4-4058-90D1-5A4ACC4254A7}`.
- AppRoot defaults to `%ProgramFiles%\Lemon串口监控` and may be another safe local fixed-disk directory; CoreRoot/DataRoot/InstallerRoot remain fixed.
- Installer and uninstaller request UAC but never display a console; no user must run PowerShell manually.
- Pin the compiler to official Inno Setup 6.7.3 and invoke Windows PowerShell only by the absolute `%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe` path.
- Do not disable Secure Boot, change TESTSIGNING/BitLocker automatically, bypass Windows security, or claim a production Microsoft signature.
- Full uninstall deletes all product Sessions, Exports, configuration, logs and AI vault state after explicit red warning confirmation.
- Never use name wildcards or recursive string-path deletion; never affect CEIWEI `CommMonitor 12`.
- Never use `MoveFileEx` for AppRoot or user LocalAppData; restart cleanup must reopen, revalidate and delete by handle.
- A reboot-required uninstall remains `PendingReboot` with a working retry entry until post-boot verification succeeds.
- Installer artifacts, certificates, secrets, databases, logs, caches and real captures stay out of Git history.
- GitHub repository is private until the user separately selects a license and approves public history/identity handling.
- Preserve and verify the seven existing dirty security-fix files before further overlapping edits.

---

## Planned File Map

### Branding and repository hygiene

- `.gitignore`: all build/cache/credential/capture exclusions.
- `src/CommMonitor.App/CommMonitor.App.csproj`: Lemon assembly/product metadata.
- `src/CommMonitor.App/MainWindow.xaml`: Lemon title.
- `src/CommMonitor.App/Services/WpfClipboardService.cs`: visible worker name.
- `tests/CommMonitor.App.Tests/Infrastructure/AppArchitectureTests.cs`: assembly/product metadata.
- `tests/CommMonitor.App.Tests/MainWindowTests.cs`: Lemon title.

### Installer state and native cleanup

- `scripts/CommMonitor.InstallHelpers.psm1`: ownership schema v3, four roots and structured transaction helpers.
- `scripts/Install-CommMonitor.ps1`: fresh install and protected manual-install migration.
- `scripts/Uninstall-CommMonitor.ps1`: complete uninstall state machine.
- `scripts/Get-CommMonitorStatus.ps1`: expanded status/residual report.
- `src/Lemon.UninstallHelper/**`: manifest validation, handle identity, owned-tree deletion and completion token.
- `tests/Lemon.UninstallHelper.Tests/**`: reparse/TOCTOU/unknown-file/reboot safety tests.
- `installer/LemonSerialMonitor.iss`: Chinese Inno GUI, AppId, tasks and `/resume` finalizer.

### Build, docs and release

- `scripts/Build-All.ps1`: Lemon app/service/AI/helper payload build.
- `scripts/Build-Installer.ps1`: official Inno Setup 6.7.3 compile.
- `scripts/Sign-Release.ps1`: helper/setup Authenticode sign and verification.
- `scripts/Test-ReleaseBundle.ps1`: SHA/signature/content gate.
- `README.md`, `docs/INSTALL.md`, `docs/USER_GUIDE.md`, `docs/TROUBLESHOOTING.md`, `docs/BUILD.md`, `docs/SECURITY.md`.
- `scripts/docs/build_commmonitor_manual.py`: Lemon DOCX/PDF manual generation.
- `tests/manual/lemon-installer-acceptance.md`: real-machine acceptance record.
- `tests/powershell/InstallerTransaction.Tests.ps1`
- `tests/powershell/UninstallTransaction.Tests.ps1`
- `tests/powershell/ResidualVerification.Tests.ps1`
- `tests/powershell/InnoInstaller.Tests.ps1`
- `tests/powershell/ReleasePackage.Tests.ps1`

---

### Task 1: Preserve existing security fixes and harden repository exclusions

**Files:**
- Modify: `.gitignore`
- Verify/commit existing modifications: `docs/INSTALL.md`
- Verify/commit existing modifications: `scripts/CommMonitor.InstallHelpers.psm1`
- Verify/commit existing modifications: `scripts/Get-CommMonitorStatus.ps1`
- Verify/commit existing modifications: `scripts/Install-CommMonitor.ps1`
- Verify/commit existing modifications: `scripts/Test-SignDriver.ps1`
- Verify/commit existing modifications: `tests/powershell/DriverSigning.Tests.ps1`
- Verify/commit existing modifications: `tests/powershell/InstallHelpers.Tests.ps1`
- Preserve for later manual task: `scripts/docs/build_commmonitor_manual.py`
- Exclude: `scripts/docs/__pycache__/`, `src/CommMonitor.Driver/CommMonitor.Driver.vcxproj.user`, `tmp/`

**Interfaces:**
- Produces a verified baseline containing the current PowerShell 5.1 atomic-file, correct service/driver CIM and `/pa` test-signature fixes.
- Produces an ignore policy that prevents accidental staging of credentials, caches, local project files and captures.

- [ ] **Step 1: Add repository-hygiene assertions before changing `.gitignore`**

Extend `tests/powershell/Package.Tests.ps1` to assert these exact patterns exist:

```powershell
@(
  'tmp/', '**/__pycache__/', '*.py[cod]', '*.user', '*.suo', '.env*',
  '*.pfx', '*.p12', '*.p8', '*.pem', '*.key', '*.pvk', '*.snk',
  '*.cer', '*.crt', '*.der', '*.db', '*.db-wal', '*.db-shm',
  '*.cmsession', '*.log'
) | ForEach-Object { $gitignore.Contains($_) | Should Be $true }
```

Add a test that `git check-ignore` recognizes the existing `.vcxproj.user`, `tmp` PNGs and `__pycache__`, while `README.md` and source `.cs` are not ignored.

- [ ] **Step 2: Run Pester and inspect the seven dirty diffs**

Run:

```powershell
Invoke-Pester -Script tests/powershell -PassThru
git diff -- docs/INSTALL.md scripts/CommMonitor.InstallHelpers.psm1 scripts/Get-CommMonitorStatus.ps1 scripts/Install-CommMonitor.ps1 scripts/Test-SignDriver.ps1 tests/powershell/DriverSigning.Tests.ps1 tests/powershell/InstallHelpers.Tests.ps1
```

Expected: current 44 Pester tests pass; diff contains only the audited atomic replacement, CIM, test-signing and verification fixes.

- [ ] **Step 3: Implement `.gitignore` and retain all audited hunks**

Append the exact exclusions from Step 1. Do not remove the existing `artifacts/`, `packages/`, bin/obj, PFX/CER, session and dump exclusions. Do not delete user files from disk; only make them ignored.

- [ ] **Step 4: Run Pester, encoding and secret/large-file scans**

Run:

```powershell
Invoke-Pester -Script tests/powershell -PassThru
git diff --check
git status --short --ignored
git ls-files | ForEach-Object { if ((Get-Item -LiteralPath $_).Length -gt 50MB) { $_ } }
git grep -n -I -E 'BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|gh[pousr]_[A-Za-z0-9_]{20,}' -- . ':!docs/superpowers/specs/*'
```

Expected: Pester passes, scans return no tracked secret/large file, and local transient paths show `!!` ignored.

- [ ] **Step 5: Commit only the audited baseline**

```powershell
git add -- .gitignore docs/INSTALL.md scripts/CommMonitor.InstallHelpers.psm1 scripts/Get-CommMonitorStatus.ps1 scripts/Install-CommMonitor.ps1 scripts/Test-SignDriver.ps1 tests/powershell/DriverSigning.Tests.ps1 tests/powershell/InstallHelpers.Tests.ps1 tests/powershell/Package.Tests.ps1
git diff --cached --check
git commit -m "fix: preserve installer security baseline"
```

---

### Task 2: Lemon WPF branding and publish identity

**Files:**
- Modify: `src/CommMonitor.App/CommMonitor.App.csproj`
- Modify: `src/CommMonitor.App/MainWindow.xaml`
- Modify: `src/CommMonitor.App/Services/WpfClipboardService.cs`
- Modify: `tests/CommMonitor.App.Tests/MainWindowTests.cs`
- Modify: `tests/CommMonitor.App.Tests/Infrastructure/AppArchitectureTests.cs`
- Modify: `tests/powershell/Package.Tests.ps1`

**Interfaces:**
- Produces `Lemon.SerialMonitor.exe` with Product/Title/FileDescription `Lemon串口监控` while retaining project and namespace names.
- Does not rename DataRoot, service, driver, C# namespace or test assembly friend identity.

- [ ] **Step 1: Write failing branding tests**

Assert `MainWindow.Title == "Lemon串口监控"`, `typeof(App).Assembly.GetName().Name == "Lemon.SerialMonitor"`, and version-resource attributes have Product/Title `Lemon串口监控`. Add a package static assertion requiring `Lemon.SerialMonitor.exe` and rejecting an installer shortcut to `CommMonitor.App.exe`.

- [ ] **Step 2: Run branding tests and verify failure**

Run:

```powershell
dotnet test tests/CommMonitor.App.Tests/CommMonitor.App.Tests.csproj --filter "MainWindowTests|AppArchitectureTests"
```

Expected: FAIL on old title/assembly name.

- [ ] **Step 3: Set visible product metadata only**

Add:

```xml
<AssemblyName>Lemon.SerialMonitor</AssemblyName>
<Product>Lemon串口监控</Product>
<Title>Lemon串口监控</Title>
<Description>不占用串口的串口通信监控工具</Description>
<Version>0.1.0</Version>
<FileVersion>0.1.0.0</FileVersion>
<InformationalVersion>0.1.0</InformationalVersion>
```

Change the XAML title and clipboard thread's visible name. Do not global-search/replace `CommMonitor`.

- [ ] **Step 4: Run App tests and publish-name check**

Run:

```powershell
dotnet test tests/CommMonitor.App.Tests/CommMonitor.App.Tests.csproj
dotnet publish src/CommMonitor.App/CommMonitor.App.csproj --configuration Release --runtime win-x64 --self-contained true --output artifacts/branding-smoke --nologo
Test-Path -LiteralPath 'artifacts/branding-smoke/Lemon.SerialMonitor.exe'
```

Expected: all App tests PASS and the final command returns `True`.

- [ ] **Step 5: Commit Task 2**

```powershell
git add -- src/CommMonitor.App/CommMonitor.App.csproj src/CommMonitor.App/MainWindow.xaml src/CommMonitor.App/Services/WpfClipboardService.cs tests/CommMonitor.App.Tests/MainWindowTests.cs tests/CommMonitor.App.Tests/Infrastructure/AppArchitectureTests.cs tests/powershell/Package.Tests.ps1
git commit -m "feat: brand the desktop app as Lemon serial monitor"
```

---

### Task 3: Ownership manifest v3 and four-root transaction helpers

**Files:**
- Modify: `scripts/CommMonitor.InstallHelpers.psm1`
- Modify: `tests/powershell/InstallHelpers.Tests.ps1`
- Create: `tests/powershell/InstallerTransaction.Tests.ps1`

**Interfaces:**
- Produces manifest schema v3 with AppId, InstallId, version, AppRoot/CoreRoot/DataRoot/InstallerRoot, authorized SID/profile, immutable/dynamic owned objects, service/driver/certificate/event-source/filter/key/reboot metadata.
- Produces `Resolve-LemonAppRoot`, `New-LemonOwnershipManifest`, `Test-LemonOwnershipManifest`, `Write-LemonTransactionResult` and exact UpperFilters uninstall-difference helpers.

- [ ] **Step 1: Write failing manifest/path/result tests**

Create tests for default Program Files AppRoot, safe `D:\Apps\Lemon`, Chinese/spaces, fixed local disk requirement, volume root/UNC/device/network/removable/reparse/nonempty rejection, immutable file SHA, dynamic `leases.json` without build-time SHA, SID/ProfileList binding, schema round trip/tamper, install rollback snapshot and uninstall-current snapshot difference.

Assert structured result JSON is one of:

```json
{"schemaVersion":1,"status":"Completed","exitCode":0,"rebootRequired":false,"installId":"...","message":"...","logPath":"..."}
```

`PendingReboot` uses exit code 3010; `Failed` uses a nonzero non-3010 code.

- [ ] **Step 2: Run Pester and verify failure**

Run:

```powershell
Invoke-Pester -Script tests/powershell/InstallHelpers.Tests.ps1,tests/powershell/InstallerTransaction.Tests.ps1 -PassThru
```

Expected: FAIL because schema v3 and four-root helpers do not exist.

- [ ] **Step 3: Implement manifest and pure transaction helpers**

Keep the current exact driver/package/service/certificate helpers. Add path normalization using local fixed-drive metadata and reject all reparse ancestors. Categorize each owned object as `ImmutableFile`, `DynamicFile`, `Directory`, `Shortcut`, `RegistryValue`, `RegistryKey`, `Service`, `DriverPackage`, `Certificate`, `EventSource`, or `ScheduledTask`. Sign/cross-check the manifest using protected install metadata; never trust a copy under AppRoot.

Implement UpperFilters uninstall result as the current snapshot with every case-insensitive exact `CommMonitorFilter` occurrence removed and every other item in original order. Installation-time snapshot remains rollback-only.

- [ ] **Step 4: Run all PowerShell unit tests**

Run:

```powershell
Invoke-Pester -Script tests/powershell -PassThru
```

Expected: all previous and new tests PASS under Windows PowerShell-compatible syntax.

- [ ] **Step 5: Commit Task 3**

```powershell
git add -- scripts/CommMonitor.InstallHelpers.psm1 tests/powershell/InstallHelpers.Tests.ps1 tests/powershell/InstallerTransaction.Tests.ps1
git commit -m "feat: add Lemon ownership manifest v3"
```

---

### Task 4: Handle-safe native uninstall helper

**Files:**
- Create: `src/Lemon.UninstallHelper/Lemon.UninstallHelper.csproj`
- Create: `src/Lemon.UninstallHelper/Program.cs`
- Create: `src/Lemon.UninstallHelper/Manifest/OwnershipManifest.cs`
- Create: `src/Lemon.UninstallHelper/Security/NativeMethods.cs`
- Create: `src/Lemon.UninstallHelper/Security/PathIdentity.cs`
- Create: `src/Lemon.UninstallHelper/Security/SafeOwnedTreeDelete.cs`
- Create: `src/Lemon.UninstallHelper/Completion/CompletionToken.cs`
- Create: `tests/Lemon.UninstallHelper.Tests/Lemon.UninstallHelper.Tests.csproj`
- Create: `tests/Lemon.UninstallHelper.Tests/SafeOwnedTreeDeleteTests.cs`
- Create: `tests/Lemon.UninstallHelper.Tests/CompletionTokenTests.cs`
- Modify: `CommMonitor.sln`

**Interfaces:**
- Produces `Lemon.UninstallHelper.exe verify-delete --manifest <protected> --install-id <id> --result <protected>`.
- Immutable files require relative path/type/product marker/SHA; dynamic files require an exact allow-listed relative path and ordinary no-reparse file identity.
- All user-writable deletions use a held no-follow handle and `SetFileInformationByHandle`; no recursive path delete and no user-root `MoveFileEx`.

- [ ] **Step 1: Write Windows-only failing safety tests**

Create a temporary approved root plus an outside sentinel. Cover normal immutable deletion, wrong SHA preserved/reported, exact dynamic lease deletion, unknown file preserved/reported, symlink/junction/mount point at every depth, hard link, root replacement race, child replacement race, locked file returning PendingReboot without `MoveFileEx`, post-reboot revalidation, empty-directory bottom-up deletion and malicious manifest traversal. Assert the outside sentinel always survives.

- [ ] **Step 2: Run helper tests and verify failure**

Run:

```powershell
dotnet test tests/Lemon.UninstallHelper.Tests/Lemon.UninstallHelper.Tests.csproj --configuration Release
```

Expected: FAIL because the helper project does not exist.

- [ ] **Step 3: Implement no-follow identity and deletion**

Open each component with `CreateFileW` using `FILE_FLAG_OPEN_REPARSE_POINT`, `FILE_FLAG_BACKUP_SEMANTICS`, delete/read-attributes access and delete-sharing. Use `GetFileInformationByHandleEx(FileAttributeTagInfo/FileStandardInfo)` and `GetFinalPathNameByHandleW`; reject every reparse tag, link count other than one for files, and any final path outside the approved held root. Keep handles open from identity check through `SetFileInformationByHandle(FileDispositionInfoEx)`.

Delete directories only after enumerating known direct children and reopening the empty directory by handle. Completion token is HMAC-bound to InstallId, manifest hash, status and UTC using a DPAPI LocalMachine-protected key from InstallerRoot. The helper writes a protected result and exits; it never deletes its running executable.

- [ ] **Step 4: Run helper tests, code analysis and sentinel checks**

Run:

```powershell
dotnet test tests/Lemon.UninstallHelper.Tests/Lemon.UninstallHelper.Tests.csproj --configuration Release
dotnet build src/Lemon.UninstallHelper/Lemon.UninstallHelper.csproj --configuration Release --runtime win-x64 --nologo
```

Expected: PASS; every adversarial test confirms no object outside approved roots changed.

- [ ] **Step 5: Commit Task 4**

```powershell
git add -- CommMonitor.sln src/Lemon.UninstallHelper tests/Lemon.UninstallHelper.Tests
git commit -m "feat: add handle-safe Lemon uninstall helper"
```

---

### Task 5: Transactional install, protected migration and complete uninstall state machine

**Files:**
- Modify: `scripts/Install-CommMonitor.ps1`
- Modify: `scripts/Uninstall-CommMonitor.ps1`
- Modify: `scripts/Get-CommMonitorStatus.ps1`
- Create: `tests/powershell/UninstallTransaction.Tests.ps1`
- Create: `tests/powershell/ResidualVerification.Tests.ps1`
- Modify: `tests/powershell/InstallerTransaction.Tests.ps1`

**Interfaces:**
- Install accepts `PackageRoot`, `AppRoot`, `AuthorizedUserSid`, `ResultPath`, and `Mode Fresh|Migrate`; CoreRoot/DataRoot/InstallerRoot are fixed internally.
- Uninstall accepts protected `InstallId`, `ResultPath`, and `Resume`; default behavior is full data deletion.
- Both scripts emit structured `Completed`, `PendingReboot`, or `Failed` and propagate native failures.

- [ ] **Step 1: Write failing transaction and residual tests**

Mock each mutation boundary and assert inverse rollback order. Cover fresh install, authorized SID different from UAC admin, existing verified manual marker migration, active capture refusal, service file atomic swap/rollback, session preservation during migration, unknown service/driver refusal, event-source ownership, certificate Added flags, PnP 0/3010/unexpected exit, service/driver delete failure, UpperFilters current-snapshot difference, full DataRoot removal, CEIWEI sentinel preservation and exact residual list.

- [ ] **Step 2: Run transaction tests and verify failure**

Run:

```powershell
Invoke-Pester -Script tests/powershell/InstallerTransaction.Tests.ps1,tests/powershell/UninstallTransaction.Tests.ps1,tests/powershell/ResidualVerification.Tests.ps1 -PassThru
```

Expected: FAIL on the current one-root install and best-effort uninstaller.

- [ ] **Step 3: Implement strict install/migration/uninstall workflows**

Fresh install verifies payload hashes, signer, roots, SID, Secure Boot/TESTSIGNING, service/driver absence and CEIWEI non-ownership before the first mutation. Migrate only a fully matching protected manual marker: stop capture, checkpoint SQLite, transactionally replace service/WPF files, retain driver and Sessions/Exports, then validate Control.v2 and AI CLI.

Replace `Invoke-NativeCommandBestEffort` with checked execution. Complete uninstall closes only exact manifest image paths, stops service, snapshots current UpperFilters and removes only the exact filter, deletes exact Driver Store package/service/cert/event source/shortcuts, invokes the native helper for user-writable roots, deletes DataRoot/CoreRoot, and verifies residuals. On any lock/3010, create protected pending state rather than claiming completion.

Status reports all four roots, AppId, event source, two pipe names, service/driver, certificates, driver package, task, Run/RunOnce, pending rename entries, AI vault and CEIWEI coexistence without mutating anything.

- [ ] **Step 4: Run all Pester tests and AST/encoding gates**

Run:

```powershell
Invoke-Pester -Script tests/powershell -PassThru
```

Expected: all tests PASS; no script contains parse errors, unsafe `-Command`, wildcard ownership deletion or success masking.

- [ ] **Step 5: Commit Task 5**

```powershell
git add -- scripts/Install-CommMonitor.ps1 scripts/Uninstall-CommMonitor.ps1 scripts/Get-CommMonitorStatus.ps1 tests/powershell/InstallerTransaction.Tests.ps1 tests/powershell/UninstallTransaction.Tests.ps1 tests/powershell/ResidualVerification.Tests.ps1
git commit -m "feat: add transactional Lemon install and uninstall"
```

---

### Task 6: Official Inno Setup 6.7.3 Chinese GUI and reboot finalizer

**Files:**
- Create: `installer/LemonSerialMonitor.iss`
- Create: `tests/powershell/InnoInstaller.Tests.ps1`
- Create: `scripts/Build-Installer.ps1`

**Interfaces:**
- Produces one x64 installer with fixed AppId, AppRoot directory page, optional desktop shortcut, hidden PowerShell execution and red full-delete confirmation.
- `/resume <InstallId>` is fully noninteractive and retains a retry entry until authenticated completion.

- [ ] **Step 1: Install official Inno Setup 6.7.3 and write failing static tests**

Install official Inno Setup 6.7.3, verify its Authenticode signature and signer before use, and reject any other compiler file version. Then assert the `.iss` contains:

```text
AppId={{F5B0783F-74F4-4058-90D1-5A4ACC4254A7}
AppName=Lemon串口监控
AppVersion=0.1.0
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
DefaultDirName={autopf}\Lemon串口监控
OutputBaseFilename=Lemon串口监控-安装程序-x64
UninstallFilesDir={commonappdata}\LemonSerialMonitor\Installer
```

Tests also require `ChineseSimplified.isl`, `SW_HIDE`, `ewWaitUntilTerminated`, the absolute `{sys}\WindowsPowerShell\v1.0\powershell.exe` executable path, `-NoProfile`, `-NonInteractive`, `-File`, and forbid both bare `powershell.exe` and `-Command`.

- [ ] **Step 2: Run static tests and verify failure**

Run:

```powershell
Invoke-Pester -Script tests/powershell/InnoInstaller.Tests.ps1 -PassThru
```

Expected: FAIL because the Inno script does not exist.

- [ ] **Step 3: Implement wizard, transaction bridge and two-stage finalization**

Use Inno's modern Chinese wizard. Capture the original interactive SID before elevation handoff and show it on the summary page if different from the admin token. Execute install/uninstall PowerShell from `{sys}\WindowsPowerShell\v1.0\powershell.exe` with an argument list and hidden window, read the protected JSON result, and map status to Chinese pages.

On uninstall, show the irreversible red data warning and require explicit confirmation. For `PendingReboot`, keep only protected helper/finalizer/manifest/log, atomically point the AppId to `unins*.exe /resume <InstallId>`, and create an InstallId-named SYSTEM startup task. `/resume` launches the helper, waits for exit, verifies its completion token, then Inno deletes the task/AppId/files and uses its built-in self-delete. Failure or power loss leaves the entry retryable and never displays completed.

- [ ] **Step 4: Run static tests and compile the installer**

Run:

```powershell
Invoke-Pester -Script tests/powershell/InnoInstaller.Tests.ps1 -PassThru
& scripts/Build-Installer.ps1 -Configuration Release -SkipSigning
```

Expected: tests PASS and unsigned smoke installer is produced with the exact Chinese filename.

- [ ] **Step 5: Commit Task 6**

```powershell
git add -- installer/LemonSerialMonitor.iss scripts/Build-Installer.ps1 tests/powershell/InnoInstaller.Tests.ps1
git commit -m "feat: add Lemon graphical installer"
```

---

### Task 7: Reproducible release build, signing and verification pipeline

**Files:**
- Modify: `scripts/Build-All.ps1`
- Create: `scripts/Sign-Release.ps1`
- Create: `scripts/Test-ReleaseBundle.ps1`
- Create: `tests/powershell/ReleasePackage.Tests.ps1`
- Modify: `tests/powershell/Package.Tests.ps1`

**Interfaces:**
- Produces the scripts that will create `artifacts/release/0.1.0/Lemon串口监控-安装程序-x64.exe`, `Lemon串口监控-完整操作手册.pdf`, `RELEASE-NOTES.md`, `SHA256SUMS.txt`, and `BUILD-INFO.json` after Task 8 supplies the final manual and documentation.
- Signs helper and installer before computing SHA-256; verifies expected certificate thumbprint after signing.

- [ ] **Step 1: Write failing payload/release tests**

Assert the payload contains Lemon WPF, Service, AI, helper, driver SYS/INF/CAT, scripts, docs and config examples; it contains no PFX/private key, NuGet/WDK cache, real DB/log/capture or old executable shortcut. Assert release bundle exact names, valid Authenticode, matching SHA lines, build version, official Inno Setup 6.7.3 compiler path/version/signer and a single installer EXE rather than a loose payload.

- [ ] **Step 2: Run package tests and verify failure**

Run:

```powershell
Invoke-Pester -Script tests/powershell/Package.Tests.ps1,tests/powershell/ReleasePackage.Tests.ps1 -PassThru
```

Expected: FAIL because Build-All still emits phase1 and no release scripts exist.

- [ ] **Step 3: Implement build, signing and verification order**

Update Build-All to test solution/Pester, publish `Lemon.SerialMonitor.exe`, `CommMonitor.Service.exe`, `Lemon.SerialMonitor.AI.exe`, and `Lemon.UninstallHelper.exe` self-contained win-x64, build/analyze/test-sign the driver, copy complete docs, and generate a payload manifest. `Build-Installer.ps1` locates only official Inno Setup 6.7.3, verifies `ISCC.exe` file version and Authenticode signer, and refuses an untrusted or mismatched compiler.

`Sign-Release.ps1` takes an explicit code-signing thumbprint, uses SHA-256/timestamp when available, verifies Authenticode signer and version resources, and never exports a key. Generate `SHA256SUMS.txt` only after all signing and manual rendering. `Test-ReleaseBundle.ps1` rehashes every asset and fails on any unlisted/extra item.

- [ ] **Step 4: Run pipeline tests and a clean payload build**

Run:

```powershell
& scripts/Build-All.ps1 -Configuration Release -TestSignDriver
Invoke-Pester -Script tests/powershell/Package.Tests.ps1,tests/powershell/ReleasePackage.Tests.ps1 -PassThru
```

Expected: managed/native/Pester gates and the complete Lemon payload build PASS. The final signed installer/hash bundle is deliberately deferred until Task 8 generates the verified manual.

- [ ] **Step 5: Commit Task 7**

```powershell
git add -- scripts/Build-All.ps1 scripts/Sign-Release.ps1 scripts/Test-ReleaseBundle.ps1 tests/powershell/Package.Tests.ps1 tests/powershell/ReleasePackage.Tests.ps1
git commit -m "build: add Lemon release pipeline"
```

---

### Task 8: Complete documentation and visually verified manual

**Files:**
- Modify: `README.md`
- Modify: `docs/INSTALL.md`
- Modify: `docs/USER_GUIDE.md`
- Modify: `docs/TROUBLESHOOTING.md`
- Create: `docs/BUILD.md`
- Create: `docs/SECURITY.md`
- Create: `docs/RELEASE_NOTES_0.1.0.md`
- Modify: `scripts/docs/build_commmonitor_manual.py`
- Create: `tests/manual/lemon-installer-acceptance.md`
- Remove from deliverables only: old-brand manual outputs

**Interfaces:**
- Produces complete install/use/copy/search/export/AI/uninstall/build/security guides and a Lemon PDF manual available from the Start menu.
- Documentation never claims production signing, absolute zero loss, open-source licensing or currently unimplemented WPF history-open features.

- [ ] **Step 1: Write documentation-content tests**

Extend package tests to require Lemon branding, GUI double-click install, AppRoot selection, reboot, first run, port selection, Start/Pause/Resume/Stop, all eight copy formats, HEX/text search, CSV/TXT/RAW export, MCP/CLI, integrity meanings, red full-uninstall warning, pending reboot retry, TESTSIGNING/Secure Boot, Authenticode/SHA verification, VS2022/WDK/Spectre/.NET/Inno build prerequisites and CEIWEI coexistence.

- [ ] **Step 2: Run documentation tests and verify failure**

Run:

```powershell
Invoke-Pester -Script tests/powershell/Package.Tests.ps1 -PassThru
```

Expected: FAIL on missing BUILD/SECURITY and old Phase 1 wording.

- [ ] **Step 3: Write docs and generate the manual**

Update all docs with exact installed paths and screenshots/instructions that match the built UI. `BUILD.md` records VS 2022 17.x, WDK/SDK 10.0.26100, Spectre x64 libraries, .NET SDK capable of targeting .NET 8, official Inno Setup 6.7.3, build commands and signature/hash verification. `SECURITY.md` documents test driver signing, AI SID/LUID/lease boundary, no network listener and same-user limitation.

Use the documents skill to update the Python generator, create a Lemon DOCX, render every page to PNG, fix layout, and export PDF. Then use the PDF skill to render and verify the final PDF. `RELEASE_NOTES_0.1.0.md` summarizes verified functions, test-signing requirements, integrity limitations and SHA/signature checks. The release pipeline copies it as `RELEASE-NOTES.md`.

- [ ] **Step 4: Run link/content/render checks**

Run:

```powershell
Invoke-Pester -Script tests/powershell/Package.Tests.ps1 -PassThru
python scripts/docs/build_commmonitor_manual.py
& scripts/Build-All.ps1 -Configuration Release -TestSignDriver
& scripts/Build-Installer.ps1 -Configuration Release
& scripts/Test-ReleaseBundle.ps1 -Version 0.1.0
```

Expected: docs tests, visual rendering, complete signed installer build and release verification PASS; rendered pages have no clipping, overlap, blank pages or old product title.

- [ ] **Step 5: Commit Task 8**

```powershell
git add -- README.md docs/INSTALL.md docs/USER_GUIDE.md docs/TROUBLESHOOTING.md docs/BUILD.md docs/SECURITY.md docs/RELEASE_NOTES_0.1.0.md scripts/docs/build_commmonitor_manual.py tests/manual/lemon-installer-acceptance.md tests/powershell/Package.Tests.ps1
git commit -m "docs: add complete Lemon installation and user manual"
```

---

### Task 9: Real-machine install/uninstall gate and private GitHub release

**Files:**
- Modify with actual results: `tests/manual/lemon-installer-acceptance.md`
- No release binary is committed to Git history.

**Interfaces:**
- Produces a verified local install/reinstall and a private `qingningmneg/LemonSerialMonitor` repository with source history plus Release `v0.1.0` assets.

- [ ] **Step 1: Run non-destructive preflight and record baseline**

Record Secure Boot/TESTSIGNING, service/driver/package/cert/filter/event-source/AppId/tasks/pending-renames, all four roots, AI vault and CEIWEI `CommMonitor 12` identity. Verify final setup signature and SHA before execution.

- [ ] **Step 2: Exercise install, migration and monitoring**

Double-click the setup, pass UAC, choose a path containing Chinese/spaces, migrate the existing protected manual install, reboot when requested, and verify Service/driver/WPF/AI. With an existing program owning a real COM port, confirm Lemon and AI read TX/RX/config events without opening the port; verify copy/search/export and integrity reporting.

- [ ] **Step 3: Exercise complete uninstall, reboot finalizer and reinstall**

Start full uninstall, accept the red data warning, inject one locked-file/reboot path, confirm AppId remains “等待重启完成卸载”, reboot, and verify the noninteractive SYSTEM `/resume` flow. Run the residual report: no owned service/driver/filter/package/cert/event-source/file/data/vault/pipe/task/AppId/pending rename remains; CEIWEI is unchanged. Reinstall from the same EXE and repeat a short capture.

- [ ] **Step 4: Run final verification and publish privately**

Run:

```powershell
dotnet test CommMonitor.sln --configuration Release --nologo
Invoke-Pester -Script tests/powershell -PassThru
& scripts/Test-ReleaseBundle.ps1 -Version 0.1.0
git diff --check
git status --short
& 'C:\Program Files\GitHub CLI\gh.exe' auth login --hostname github.com --git-protocol https --web
& 'C:\Program Files\GitHub CLI\gh.exe' repo create qingningmneg/LemonSerialMonitor --private --source . --remote origin --push
```

Expected: every test and release gate passes; repository visibility is private and source is pushed without release binaries.

- [ ] **Step 5: Commit only the acceptance record and tag**

```powershell
git add -- tests/manual/lemon-installer-acceptance.md
git commit -m "test: record Lemon installer acceptance"
git tag -a v0.1.0 -m "Lemon serial monitor 0.1.0"
git push origin codex/commmonitor-phase1 --follow-tags
& 'C:\Program Files\GitHub CLI\gh.exe' release create v0.1.0 --repo qingningmneg/LemonSerialMonitor --title 'Lemon串口监控 0.1.0' --notes-file artifacts/release/0.1.0/RELEASE-NOTES.md artifacts/release/0.1.0/Lemon串口监控-安装程序-x64.exe artifacts/release/0.1.0/Lemon串口监控-完整操作手册.pdf artifacts/release/0.1.0/SHA256SUMS.txt
```

Expected: the tag exists locally/remotely; installer/manual/SHA are Release assets but remain untracked by Git.

---

## Installer and Release Completion Gate

Completion requires all of the following evidence:

- Managed, Pester, native-driver and code-analysis tests pass.
- Official Inno Setup 6.7.3 compiles the exact one-file Chinese setup.
- Driver/CAT/helper/setup signatures and final SHA-256 all verify after signing.
- Fresh install, protected manual migration, reboot, WPF/AI monitoring, copy/search/export and reinstall pass.
- Full uninstall deletes only Lemon-owned program/system/data/vault objects and remains retryable through a reboot.
- CEIWEI `CommMonitor 12` is unchanged.
- Complete docs/manual are rendered and visually verified.
- Secret/large/artifact scans pass; GitHub is private; source is pushed and `v0.1.0` assets are attached to the release.
