# Lemon串口监控无串口设备启动 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 Windows 服务在没有连接串口设备时仍正常启动，并在设备随后出现时按需自动恢复驱动连接。

**Architecture:** 新增一个仅负责宿主启动边界的 `CaptureServiceStartup`，只把 `DRIVER_UNAVAILABLE` 转换为降级启动警告；`CaptureAuthority` 的未知内核状态保护和后续按需重试保持不变。`DriverCaptureSource` 已在打开失败后保留空设备引用，下一次状态调用会重新打开；新增回归测试固定这一行为。

**Tech Stack:** .NET 8 Worker Service、Microsoft.Extensions.Hosting、xUnit 2.5.3、Windows Service、现有捕获驱动协议。

## Global Constraints

- 公开产品名只能是 `Lemon串口监控`。
- 内部兼容标识 `CommMonitorService`、`CommMonitorFilter` 和内部存储路径不得在本任务中重命名。
- 未知驱动状态不得被视为已停止，不得在无法协调内核状态时开始捕获。
- WPF 的 Start、Pause、Resume、Stop 必须经过 `CaptureAuthority`；不得直接从管道调用 `CaptureCoordinator` 的同名状态变更。
- 只容忍错误码为 `DRIVER_UNAVAILABLE` 的启动异常；取消和其他异常必须继续向上传播。
- 不增加轮询器、定时器、设备通知服务或协议变更。
- 不修改安装/卸载事务、驱动启动类型、PnP 绑定或测试证书逻辑。
- 不修改 `docs/superpowers/plans/2026-07-13-commmonitor-complete-manual.md`。

---

### Task 1: 服务降级启动与设备恢复回归

**Files:**
- Create: `src/CommMonitor.Service/Hosting/CaptureServiceStartup.cs`
- Modify: `src/CommMonitor.Service/Program.cs`
- Create: `tests/CommMonitor.Service.Tests/Hosting/CaptureServiceStartupTests.cs`
- Modify: `tests/CommMonitor.Service.Tests/Driver/DriverCaptureSourceTests.cs`

**Interfaces:**
- Consumes: `CaptureLeaseException.Code`、`AiErrorCodes.DriverUnavailable`、`CaptureAuthority.InitializeAsync(CancellationToken)`、`ILogger`。
- Produces: `CaptureServiceStartup.InitializeAsync(Func<CancellationToken, Task>, ILogger, CancellationToken)`；调用完成表示宿主可继续启动，不表示驱动已经可用。

- [ ] **Step 1: 写启动边界失败测试**

创建 `CaptureServiceStartupTests.cs`，先声明期望 API 并覆盖三个分支：

```csharp
using CommMonitor.Core.Ai;
using CommMonitor.Service.Capture;
using CommMonitor.Service.Hosting;
using Microsoft.Extensions.Logging.Abstractions;

namespace CommMonitor.Service.Tests.Hosting;

public sealed class CaptureServiceStartupTests
{
    [Fact]
    public async Task Driver_unavailable_does_not_abort_service_startup()
    {
        await CaptureServiceStartup.InitializeAsync(
            _ => throw new CaptureLeaseException(
                AiErrorCodes.DriverUnavailable,
                "Scripted missing driver control device."),
            NullLogger.Instance,
            CancellationToken.None);
    }

    [Fact]
    public async Task Other_capture_errors_are_not_swallowed()
    {
        CaptureLeaseException error = await Assert.ThrowsAsync<CaptureLeaseException>(() =>
            CaptureServiceStartup.InitializeAsync(
                _ => throw new CaptureLeaseException("OTHER", "Scripted failure."),
                NullLogger.Instance,
                CancellationToken.None));

        Assert.Equal("OTHER", error.Code);
    }

    [Fact]
    public async Task Cancellation_is_not_swallowed()
    {
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            CaptureServiceStartup.InitializeAsync(
                token => Task.FromCanceled(token),
                NullLogger.Instance,
                cancellation.Token));
    }
}
```

- [ ] **Step 2: 运行启动边界测试并确认 RED**

Run:

```powershell
& artifacts\toolchain\dotnet-10.0.301-x64\dotnet.exe test `
  tests\CommMonitor.Service.Tests\CommMonitor.Service.Tests.csproj `
  --filter FullyQualifiedName~CaptureServiceStartupTests `
  --no-restore
```

Expected: FAIL，编译器报告 `CaptureServiceStartup` 不存在；失败原因只能是目标生产 API 尚未实现。

- [ ] **Step 3: 写设备重新出现的失败测试**

在 `DriverCaptureSourceTests.cs` 增加测试：第一次 `OpenAsync` 抛 `DriverUnavailableException`，第二次返回能正确响应 `GET_VERSION` 的设备；两次 `GetStatusAsync` 应依次得到 `DriverUnavailable` 和 `Ready`，并断言打开次数为 2。

```csharp
[Fact]
public async Task Missing_control_device_is_retried_on_the_next_status_request()
{
    var device = new ScriptedDriverDevice((code, _, output, _) =>
    {
        Assert.Equal(DriverProtocol.GetVersionIoControlCode, code);
        return ValueTask.FromResult(WriteVersion(output));
    });
    var factory = new RecoveringDriverDeviceFactory(device);
    await using var source = new DriverCaptureSource(
        factory,
        new StaticPortCatalog([]),
        new FixedQpcClock(0, DateTimeOffset.UnixEpoch, 10_000_000),
        new ImmediateCaptureDelay());

    CaptureSourceStatus first = await source.GetStatusAsync(CancellationToken.None);
    CaptureSourceStatus second = await source.GetStatusAsync(CancellationToken.None);

    Assert.Equal(CaptureSourceStatusKind.DriverUnavailable, first.Kind);
    Assert.Equal(CaptureSourceStatusKind.Ready, second.Kind);
    Assert.Equal(2, factory.OpenCalls);
}

private sealed class RecoveringDriverDeviceFactory(IDriverDevice device)
    : IDriverDeviceFactory
{
    public int OpenCalls { get; private set; }

    public ValueTask<IDriverDevice> OpenAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        OpenCalls++;
        return OpenCalls == 1
            ? ValueTask.FromException<IDriverDevice>(
                new DriverUnavailableException("driver missing"))
            : ValueTask.FromResult(device);
    }
}
```

- [ ] **Step 4: 单独运行设备恢复测试并确认现有行为**

Run:

```powershell
& artifacts\toolchain\dotnet-10.0.301-x64\dotnet.exe test `
  tests\CommMonitor.Service.Tests\CommMonitor.Service.Tests.csproj `
  --filter FullyQualifiedName~Missing_control_device_is_retried_on_the_next_status_request `
  --no-restore
```

Expected: PASS。该测试固定现有按需重试能力；如果失败，则停止并重新调查 `DriverCaptureSource.EnsureDeviceAsync`，不得继续写启动容错。

- [ ] **Step 5: 实现最小启动协调组件**

创建 `CaptureServiceStartup.cs`：

```csharp
using CommMonitor.Core.Ai;
using CommMonitor.Service.Capture;

namespace CommMonitor.Service.Hosting;

internal static class CaptureServiceStartup
{
    public static async Task InitializeAsync(
        Func<CancellationToken, Task> initializeCaptureAuthorityAsync,
        ILogger logger,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(initializeCaptureAuthorityAsync);
        ArgumentNullException.ThrowIfNull(logger);

        try
        {
            await initializeCaptureAuthorityAsync(cancellationToken)
                .ConfigureAwait(false);
        }
        catch (CaptureLeaseException exception) when (
            exception.Code == AiErrorCodes.DriverUnavailable)
        {
            logger.LogWarning(
                exception,
                "The capture driver is temporarily unavailable during service startup. " +
                "The service will remain running and retry when requested.");
        }
    }
}
```

- [ ] **Step 6: 让 Program 使用启动协调组件**

在 `Program.cs` 中先创建现有启动 logger，再调用新组件；保留后续 `GetStatusAsync` 和信息/警告日志：

```csharp
IHost host = builder.Build();
ILogger logger = host.Services
    .GetRequiredService<ILoggerFactory>()
    .CreateLogger("Lemon.SerialMonitor.Service.Startup");
CaptureAuthority authority = host.Services.GetRequiredService<CaptureAuthority>();
await CaptureServiceStartup.InitializeAsync(
    authority.InitializeAsync,
    logger,
    CancellationToken.None);
CaptureSourceStatus sourceStatus = await host.Services
    .GetRequiredService<ICaptureSourceStatusProvider>()
    .GetStatusAsync(CancellationToken.None);
```

不得增加捕获所有异常的 `catch`。

- [ ] **Step 7: 运行 GREEN 和服务项目测试**

Run:

```powershell
& artifacts\toolchain\dotnet-10.0.301-x64\dotnet.exe test `
  tests\CommMonitor.Service.Tests\CommMonitor.Service.Tests.csproj `
  --no-restore
```

Expected: 全部通过，失败数为 0；新启动测试 3 项通过，设备恢复测试 1 项通过。

- [ ] **Step 8: 运行全量托管与安装器回归**

Run:

```powershell
& artifacts\toolchain\dotnet-10.0.301-x64\dotnet.exe test `
  CommMonitor.sln --no-restore
Import-Module Pester -MinimumVersion 4.10.1
$result = Invoke-Pester -Script .\tests\powershell -PassThru
if ($result.FailedCount -ne 0) { exit 1 }
```

Expected: 全部通过，失败数为 0。

- [ ] **Step 9: 自审并提交**

检查变更仅为本任务四个文件，运行 `git diff --check`，确认受保护文件 SHA256 仍为 `06E9AB3B431DB17FB06C169150D890007B3F72D285EB230254BD4C494AEC0B6F`，然后提交：

```powershell
git add -- `
  src/CommMonitor.Service/Hosting/CaptureServiceStartup.cs `
  src/CommMonitor.Service/Program.cs `
  tests/CommMonitor.Service.Tests/Hosting/CaptureServiceStartupTests.cs `
  tests/CommMonitor.Service.Tests/Driver/DriverCaptureSourceTests.cs
git commit -m "fix: 无串口设备时保持服务运行"
```

- [ ] **Step 10: 独立审查**

使用基线提交生成审查包，由新的审查者分别验证规格符合性和代码质量。确认只吞掉 `DRIVER_UNAVAILABLE`，取消和其他错误仍传播，并确认设备打开失败后下一次状态请求确实重试。

---

### Task 2: WPF 状态变更统一经过 CaptureAuthority

**Files:**
- Create: `src/CommMonitor.Service/Capture/IWpfCaptureController.cs`
- Modify: `src/CommMonitor.Service/Capture/CaptureAuthority.cs`
- Modify: `src/CommMonitor.Service/Ipc/PipeServer.cs`
- Modify: `src/CommMonitor.Service/Program.cs`
- Modify: `tests/CommMonitor.Service.Tests/Capture/CaptureLeaseManagerTests.cs`
- Modify: `tests/CommMonitor.Service.Tests/Ipc/PipeServerTests.cs`
- Modify: `tests/CommMonitor.Service.Tests/Ipc/ServiceStorageSecurityTests.cs`

**Interfaces:**
- Consumes: `CaptureAuthority.StartWpfAsync`、`CaptureAuthority.StopWpfAsync`、`CaptureCoordinator` 的 Pause/Resume、现有 PipeServer 命令协议。
- Produces: 内部 `IWpfCaptureController`，包含 `StartWpfAsync(CaptureSelection, CancellationToken)`、`PauseWpfAsync(CancellationToken)`、`ResumeWpfAsync(CancellationToken)`、`StopWpfAsync(CancellationToken)`；`CaptureAuthority` 实现该接口。

- [ ] **Step 1: 写 Authority 的 WPF 状态转换失败测试**

在 `CaptureLeaseManagerTests.cs` 增加两个测试。第一个要求 WPF 启动、暂停、恢复、停止全部成功且状态依次为 Running、Paused、Running、Stopped；第二个先建立 AI 捕获，再要求 WPF Pause/Resume 返回 `CaptureConflict`，证明不能改变 AI 所有的运行。

```csharp
[Fact]
public async Task Wpf_state_changes_run_through_the_capture_authority()
{
    await using var context = new AuthorityContext();
    await context.Authority.StartWpfAsync(new CaptureSelection(
        Devices(),
        Path.Combine(context.Boundary.SessionRoot, "wpf.cmsession")));
    Assert.Equal(CaptureState.Running, context.Coordinator.State);

    await context.Authority.PauseWpfAsync();
    Assert.Equal(CaptureState.Paused, context.Coordinator.State);
    await context.Authority.ResumeWpfAsync();
    Assert.Equal(CaptureState.Running, context.Coordinator.State);
    await context.Authority.StopWpfAsync();
    Assert.Equal(CaptureState.Stopped, context.Coordinator.State);
}

[Fact]
public async Task Wpf_pause_and_resume_cannot_mutate_an_ai_owned_capture()
{
    await using var context = new AuthorityContext();
    _ = await context.StartAiAsync(Owner, Now);

    CaptureLeaseException pause = await Assert.ThrowsAsync<CaptureLeaseException>(
        () => context.Authority.PauseWpfAsync());

    Assert.Equal(AiErrorCodes.CaptureConflict, pause.Code);
    Assert.Equal(CaptureState.Running, context.Coordinator.State);
}
```

恢复分支用一个已暂停的 AI 捕获重复断言 `ResumeWpfAsync` 返回相同错误码。

- [ ] **Step 2: 运行 Authority 测试并确认 RED**

Run:

```powershell
& artifacts\toolchain\dotnet-10.0.301-x64\dotnet.exe test `
  tests\CommMonitor.Service.Tests\CommMonitor.Service.Tests.csproj `
  --filter "FullyQualifiedName~Wpf_state_changes_run_through_the_capture_authority|FullyQualifiedName~Wpf_pause_and_resume_cannot_mutate_an_ai_owned_capture" `
  --no-restore
```

Expected: FAIL，编译器报告 `PauseWpfAsync` 和 `ResumeWpfAsync` 不存在。

- [ ] **Step 3: 定义 WPF 控制接口并实现 Authority 状态转换**

创建 `IWpfCaptureController.cs`：

```csharp
namespace CommMonitor.Service.Capture;

internal interface IWpfCaptureController
{
    Task StartWpfAsync(
        CaptureSelection selection,
        CancellationToken cancellationToken = default);
    Task PauseWpfAsync(CancellationToken cancellationToken = default);
    Task ResumeWpfAsync(CancellationToken cancellationToken = default);
    Task StopWpfAsync(CancellationToken cancellationToken = default);
}
```

让 `CaptureAuthority` 实现该接口。新增 Pause/Resume，二者都必须获取 `_transitionGate`、调用 `EnsureStartupReconciledAsync`、验证 `_owner == CaptureAuthorityOwner.Wpf` 和预期状态后再调用协调器：

```csharp
public Task PauseWpfAsync(CancellationToken cancellationToken = default) =>
    ChangeWpfStateAsync(
        CaptureState.Running,
        static (coordinator, token) => coordinator.PauseAsync(token),
        cancellationToken);

public Task ResumeWpfAsync(CancellationToken cancellationToken = default) =>
    ChangeWpfStateAsync(
        CaptureState.Paused,
        static (coordinator, token) => coordinator.ResumeAsync(token),
        cancellationToken);
```

`ChangeWpfStateAsync` 在所有权不是 WPF 时抛 `Conflict("Capture is not controlled by WPF.")`；不得更改现有 AI 状态转换和 StopWpf 的强制停止语义。

- [ ] **Step 4: 运行 Authority 测试并确认 GREEN**

重复 Step 2 命令。

Expected: 两项通过，失败数为 0。

- [ ] **Step 5: 写 PipeServer 路由失败测试**

在 `PipeServerTests.cs` 的测试宿主中增加实现 `IWpfCaptureController` 的 `RecordingWpfCaptureController`。它把四个方法委托给现有 `CaptureCoordinator` 并记录调用顺序。新增测试依次发送 Start、Pause、Resume、Stop，并断言：

```csharp
Assert.Equal(
    new[] { "Start", "Pause", "Resume", "Stop" },
    host.WpfController.Calls);
```

先保持 `PipeServer` 生产代码不变运行该测试。

- [ ] **Step 6: 运行 PipeServer 路由测试并确认 RED**

Run:

```powershell
& artifacts\toolchain\dotnet-10.0.301-x64\dotnet.exe test `
  tests\CommMonitor.Service.Tests\CommMonitor.Service.Tests.csproj `
  --filter FullyQualifiedName~Mutating_commands_are_routed_through_the_wpf_capture_controller `
  --no-restore
```

Expected: FAIL，记录列表为空，证明当前管道仍直接调用协调器。

- [ ] **Step 7: 将 PipeServer 四个命令改走 WPF 控制接口**

给 `PipeServer` 的内部构造函数增加必需的 `IWpfCaptureController` 参数并保存为 `_wpfCaptureController`。四个命令替换为：

```csharp
await _wpfCaptureController.StartWpfAsync(
    new CaptureSelection(command.DeviceIds.ToHashSet(), sessionPath),
    cancellationToken).ConfigureAwait(false);
await _wpfCaptureController.PauseWpfAsync(cancellationToken).ConfigureAwait(false);
await _wpfCaptureController.ResumeWpfAsync(cancellationToken).ConfigureAwait(false);
await _wpfCaptureController.StopWpfAsync(cancellationToken).ConfigureAwait(false);
```

`Program.cs` 创建 `PipeServer` 时传入已注册的 `CaptureAuthority`。测试构造器传入记录控制器；`ServiceStorageSecurityTests` 使用一个四个方法均返回完成任务的明确 stub。不得给生产构造器提供回退到直接协调器的默认值。

- [ ] **Step 8: 运行 PipeServer、Authority 和全量服务测试**

Run:

```powershell
& artifacts\toolchain\dotnet-10.0.301-x64\dotnet.exe test `
  tests\CommMonitor.Service.Tests\CommMonitor.Service.Tests.csproj `
  --no-restore
```

Expected: 全部通过，失败数为 0。

- [ ] **Step 9: 运行全量回归、自审并提交**

Run:

```powershell
& artifacts\toolchain\dotnet-10.0.301-x64\dotnet.exe test CommMonitor.sln --no-restore
Import-Module Pester -MinimumVersion 4.10.1
$result = Invoke-Pester -Script .\tests\powershell -PassThru
if ($result.FailedCount -ne 0) { exit 1 }
git diff --check
```

Expected: 全部通过，失败数为 0。确认只涉及 Task 2 七个文件且受保护文件哈希不变，然后提交：

```powershell
git add -- `
  src/CommMonitor.Service/Capture/IWpfCaptureController.cs `
  src/CommMonitor.Service/Capture/CaptureAuthority.cs `
  src/CommMonitor.Service/Ipc/PipeServer.cs `
  src/CommMonitor.Service/Program.cs `
  tests/CommMonitor.Service.Tests/Capture/CaptureLeaseManagerTests.cs `
  tests/CommMonitor.Service.Tests/Ipc/PipeServerTests.cs `
  tests/CommMonitor.Service.Tests/Ipc/ServiceStorageSecurityTests.cs
git commit -m "fix: 统一界面捕获状态控制"
```

- [ ] **Step 10: 独立审查与真实系统复测**

使用 Task 1 提交作为基线生成审查包，由新的审查者确认所有四个状态变更都经过 WPF Authority，且 ListPorts、Clear、Export、Subscribe 协议未改变。审查通过后重建并安装候选包；在没有串口设备时重启，确认服务 Running、AI `ping` 和 MCP smoke 可用，且自本次启动后没有该服务的新 SCM 7009/7000。若随后连接串口设备，再验证端口枚举和捕获启动无需重启。
