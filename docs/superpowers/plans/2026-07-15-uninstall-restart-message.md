# 卸载重启提示准确性实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让卸载重启提示准确反映 Windows 驱动或设备栈清理，不再暗示应用进程未关闭文件。

**Architecture:** 保留现有 `PendingReboot`、退出码 3010 和 SYSTEM 开机续办机制，只修改 Inno Setup 用户提示及其回归契约。文档同步解释内核驱动清理与用户态文件占用的区别，不扩展卸载结果协议。

**Tech Stack:** Inno Setup 6.7.3、PowerShell 5.1、Pester 4.10.1、Markdown。

## Global Constraints

- 公共产名称只能使用 `Lemon串口监控`。
- 不改变卸载结果 JSON、退出码、续办任务、驱动删除命令或数据删除规则。
- 不强制重启或禁用其他串口设备。
- 新提示必须是：`Windows 正在完成驱动或设备栈的安全清理。请重新启动计算机，卸载会自动继续。`
- 测试必须禁止旧的“部分文件仍被 Windows 占用”表述回归。

---

### Task 1: 用测试锁定准确的卸载重启提示

**Files:**
- Modify: `tests/powershell/InnoInstaller.Tests.ps1`
- Modify: `installer/LemonSerialMonitor.iss:593`

**Interfaces:**
- Consumes: `ConvertFrom-TestCodePoints` 测试辅助函数和 `LemonSerialMonitor.iss` 文本契约。
- Produces: Pester 契约，要求新提示存在且旧提示不存在。

- [ ] **Step 1: 写入失败的回归测试**

在 `keeps pending uninstall retryable through a SYSTEM startup continuation` 测试之后加入：

```powershell
    It 'explains pending restart as Windows driver or device-stack cleanup' {
        $text = Get-Content -Raw -LiteralPath $innoPath -Encoding UTF8
        $accurateNotice = 'Windows ' + (ConvertFrom-TestCodePoints @(
                0x6b63, 0x5728, 0x5b8c, 0x6210, 0x9a71, 0x52a8,
                0x6216, 0x8bbe, 0x5907, 0x6808, 0x7684, 0x5b89,
                0x5168, 0x6e05, 0x7406, 0x3002, 0x8bf7, 0x91cd,
                0x65b0, 0x542f, 0x52a8, 0x8ba1, 0x7b97, 0x673a,
                0xff0c, 0x5378, 0x8f7d, 0x4f1a, 0x81ea, 0x52a8,
                0x7ee7, 0x7eed, 0x3002))
        $misleadingNotice = ConvertFrom-TestCodePoints @(
            0x90e8, 0x5206, 0x6587, 0x4ef6, 0x4ecd, 0x88ab,
            0x0020, 0x0057, 0x0069, 0x006e, 0x0064, 0x006f,
            0x0077, 0x0073, 0x0020, 0x5360, 0x7528)

        $text.Contains($accurateNotice) | Should Be $true
        $text.Contains($misleadingNotice) | Should Be $false
    }
```

- [ ] **Step 2: 运行目标测试并确认 RED**

Run:

```powershell
Import-Module Pester -MinimumVersion 4.10.1
$result = Invoke-Pester -Script .\tests\powershell\InnoInstaller.Tests.ps1 -PassThru
if ($result.FailedCount -ne 1) { exit 1 }
```

Expected: 新测试失败；失败原因同时显示新提示不存在或旧提示仍存在，其他 `InnoInstaller.Tests.ps1` 测试通过。

- [ ] **Step 3: 写入最小实现**

把 `installer/LemonSerialMonitor.iss` 中的旧提示替换为：

```pascal
      MsgBox('Windows 正在完成驱动或设备栈的安全清理。' +
          '请重新启动计算机，卸载会自动继续。',
        mbInformation, MB_OK);
```

- [ ] **Step 4: 运行目标测试并确认 GREEN**

Run:

```powershell
Import-Module Pester -MinimumVersion 4.10.1
$result = Invoke-Pester -Script .\tests\powershell\InnoInstaller.Tests.ps1 -PassThru
if ($result.FailedCount -ne 0) { exit 1 }
```

Expected: `InnoInstaller.Tests.ps1` 全部通过，失败数为 0。

- [ ] **Step 5: 提交提示修复**

```powershell
git add -- tests/powershell/InnoInstaller.Tests.ps1 installer/LemonSerialMonitor.iss
git commit -m "fix: 准确说明卸载重启原因"
```

### Task 2: 同步用户文档并执行完整验证

**Files:**
- Modify: `README.md:104`
- Modify: `docs/INSTALL.md:133,164`
- Modify: `docs/TROUBLESHOOTING.md:161-165`

**Interfaces:**
- Consumes: Task 1 的准确提示语义。
- Produces: 安装、卸载和故障排查说明，明确重启不等于应用进程仍占用文件。

- [ ] **Step 1: 更新安装与卸载说明**

将 `docs/INSTALL.md` 的重启说明写为：

```markdown
如提示重启，先保存工作再重启；Windows 会在开机后继续完成驱动或设备栈的安全清理，卸载程序随后自动核验并删除最后的安装记录。出现该提示不代表桌面程序或后台服务仍在占用文件。
```

- [ ] **Step 2: 更新故障排查说明**

将 `docs/TROUBLESHOOTING.md` 对应小节标题改为 `## 卸载提示需要重启`，正文写为：

```markdown
应用进程和后台服务关闭后，Windows 仍可能需要重启才能完成内核驱动、Driver Store 或串口设备栈的安全切换。卸载程序会安排受保护的开机续办；保存工作并重启，登录后等待卸载完成。不要在重启前删除安装目录或取消计划任务。

这类提示不等于应用没有关闭自己的文件。如果重启后仍失败，保留提示文字、卸载日志、系统版本和状态脚本输出；受保护安装记录丢失时，卸载会停止以避免误删其他软件。
```

- [ ] **Step 3: 更新 README 简要说明**

将 `README.md` 的卸载说明写为：

```markdown
可以从“设置 → 应用 → 已安装的应用 → Lemon串口监控 → 卸载”进入完整卸载。Windows 需要完成内核驱动、Driver Store 或串口设备栈切换时，卸载程序会安排重启后继续清理并再次核验残留；这不表示应用进程仍在占用文件。
```

- [ ] **Step 4: 运行完整验证**

Run:

```powershell
Import-Module Pester -MinimumVersion 4.10.1
$result = Invoke-Pester -Path .\tests\powershell -PassThru
if ($result.FailedCount -ne 0) { exit 1 }
.\scripts\Test-LemonBrand.ps1
.\scripts\Build-Installer.ps1
```

Expected: Pester 失败数 0；公开名称审计通过；Inno Setup 6.7.3 编译成功并产生签名安装包。

- [ ] **Step 5: 执行真实卸载回归**

用新安装包依次完成安装、重启、运行、交互式完整卸载、重启续办和零残留审计。验证用户看到的新提示准确，续办任务与现有安全事务保持不变。

- [ ] **Step 6: 提交文档和验证记录**

```powershell
git add -- README.md docs/INSTALL.md docs/TROUBLESHOOTING.md tests/manual/lemon-installer-acceptance.md
git commit -m "docs: 说明卸载重启与设备栈清理"
git push origin main
```
