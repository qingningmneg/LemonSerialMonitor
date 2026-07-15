# CommMonitor Phase 1 实机验收记录（待执行模板）

> 本文件是**未填写、未通过**的证据清单。所有复选框故意保持空白；没有真实硬件、原始日志、命令输出和测试人签字，不得改为通过，也不得据此宣称 Phase 1 完成。

命令默认从源码仓库根运行，包根为 `.\artifacts\phase1`。若测试机只有已解压交付包，请先进入能直接看到 `app`、`service`、`driver`、`scripts` 的包根，并把命令中的 `.\artifacts\phase1` 替换为 `.`；第 3 节源码构建项应引用构建机证据，不要在包目录中重跑。

## 0. 验收结论

- 验收编号：`________________________`
- 开始时间（含时区）：`________________________`
- 结束时间（含时区）：`________________________`
- 测试人：`________________________`
- 审核人：`________________________`
- 结论：`[ ] PASS  [ ] FAIL  [ ] BLOCKED  [ ] NOT RUN`
- 未解决失败/阻塞数：`________`
- 证据根目录：`________________________`
- 备注：`____________________________________________________________`

**签字规则：** 只有本文件所有必需项都有原始证据、没有未解决 FAIL/BLOCKED、Driver Verifier 已关闭、系统恢复步骤已确认，才允许选择 PASS。

## 1. 当前已知实现缺口（测试前复核）

生成本模板时源码仍有以下缺口，若执行时尚未修复，对应验收项必须标为 BLOCKED/FAIL，不能豁免：

- UI“打开/保存”仍为后续阶段占位。
- Dump/终端能复制当前底层完整事件，但单元格、字节范围或任意终端文字子串的局部复制尚未实现。
- 驱动 `GET_STATS.Dropped` 未接入 UI；状态栏 `丢失 = 0` 不足以证明内核无丢包。
- 导出当前会先把完整会话加载到服务内存，超大数据库仍需压力验证。

执行版本是否仍存在这些缺口：`________________________________________`

## 2. 测试环境

### 2.1 软件与系统

| 项目 | 实际值 | 证据文件 |
|---|---|---|
| Commit SHA |  |  |
| 包 SHA-256 |  |  |
| Windows 产品 |  |  |
| Windows 版本 |  |  |
| OS build |  |  |
| 架构（必须 x64） |  |  |
| Secure Boot（测试前） |  |  |
| TestSigning（测试前） |  |  |
| 内存完整性/HVCI |  |  |
| BitLocker/设备加密状态 |  |  |
| Visual Studio 2022 版本 |  |  |
| WDK 版本 |  |  |
| MSVC/Spectre 库版本 |  |  |
| .NET SDK 版本 |  |  |
| CommMonitor 驱动版本/协议 |  |  |
| CommMonitor 服务版本 |  |  |
| CommMonitor 客户端版本 |  |  |

采集命令：

```powershell
Get-ComputerInfo |
  Select-Object WindowsProductName,WindowsVersion,OsBuildNumber,OsArchitecture
dotnet --info
try { Confirm-SecureBootUEFI } catch { $_.Exception.Message }
bcdedit.exe /enum '{current}'
git rev-parse HEAD
Get-FileHash -Algorithm SHA256 .\artifacts\phase1\driver\CommMonitor.Driver.sys
```

- [ ] 已保存完整输出，且能从证据目录重现以上表格。
- [ ] 测试机是可恢复的 Windows 10/11 x64，不是生产关键设备。
- [ ] 已保存 BitLocker 恢复密钥或确认不适用。
- [ ] 若改变 Secure Boot，操作由设备所有者明确执行并记录，脚本没有自动降低安全策略。

### 2.2 虚拟串口对

| 项目 | A 端 | B 端 |
|---|---|---|
| 软件/驱动名称和版本 |  |  |
| COM 号 |  |  |
| PNPDeviceID |  |  |
| 波特率 |  |  |
| 数据位 |  |  |
| 校验 |  |  |
| 停止位 |  |  |
| 流控 |  |  |

- [ ] 虚拟对在未安装 CommMonitor 时双向基线通过。
- [ ] 基线 TX/RX 日志和 SHA-256 已保存。

### 2.3 USB 转串口和真实设备

| 项目 | 实际值 |
|---|---|
| 芯片/适配器型号 |  |
| 厂商驱动和版本 |  |
| 友好名称 |  |
| COM 号 |  |
| PNPDeviceID |  |
| 对端设备 |  |
| 波特率 |  |
| 数据位 |  |
| 校验 |  |
| 停止位 |  |
| 流控 |  |

- [ ] USB 适配器在未安装 CommMonitor 时双向基线通过。
- [ ] 基线 TX/RX 日志和 SHA-256 已保存。

## 3. 构建、测试和签名证据

运行：

```powershell
New-Item -ItemType Directory -Force .\artifacts | Out-Null
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Build-All.ps1 `
  -Configuration Release `
  -TestSignDriver |
  Tee-Object .\artifacts\acceptance-build.log
git diff --check
git status --short
```

| 门禁 | 结果 | 证据/计数 |
|---|---|---|
| `dotnet restore` |  |  |
| Core tests |  |  |
| Service tests |  |  |
| App tests |  |  |
| 原生协议布局 |  |  |
| 原生环形缓冲 |  |  |
| 原生传输/捕获 |  |  |
| x64 Release 驱动 |  |  |
| WDK Code Analysis/PREfast |  |  |
| InfVerif |  |  |
| 自包含 win-x64 App/Service publish |  |  |
| `git diff --check` |  |  |

- [ ] `Build-All.ps1` 退出码为 0。
- [ ] 所有自动化测试通过，记录精确 Passed/Failed/Skipped 数。
- [ ] 驱动产物是 x64 native，不是 .NET 程序集。
- [ ] `artifacts\phase1\{app,service,driver,scripts,docs}` 齐全。
- [ ] 工作树只有预期变更。

签名由上面的 `-TestSignDriver` 在生成 `SHA256SUMS.txt` 之前执行。构建日志必须包含 `SIGNATURE_VERIFICATION=PASS`。不要在记录清单后再次签名；直接保存签名器、散列和清单（临时 CurrentUser 信任已恢复，所以安装前的 `Get-AuthenticodeSignature.Status` 可能显示尚未受信任）：

```powershell
Get-AuthenticodeSignature .\artifacts\phase1\driver\CommMonitor.Driver.sys |
  Format-List *
Get-AuthenticodeSignature .\artifacts\phase1\driver\CommMonitor.Driver.cat |
  Format-List *
Get-FileHash -Algorithm SHA256 .\artifacts\phase1\driver\CommMonitor.Driver.sys
Get-FileHash -Algorithm SHA256 .\artifacts\phase1\driver\CommMonitor.Driver.cat
Get-Content .\artifacts\phase1\SHA256SUMS.txt
```

| 项目 | 实际值 |
|---|---|
| 证书 Subject |  |
| Thumbprint |  |
| 私钥存储（应为 CurrentUser My） |  |
| NotBefore / NotAfter |  |
| 私钥可导出？（必须否） |  |
| SYS SHA-256 |  |
| CAT SHA-256 |  |
| SignTool SYS verify |  |
| SignTool CAT verify |  |

- [ ] SYS 和 CAT 均为 SHA-256 测试签名且验证成功。
- [ ] 仓库和提交中没有 CER/PFX/私钥。

## 4. 安装安全与回滚证据

安装前：

```powershell
$portsClass = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4D36E978-E325-11CE-BFC1-08002BE10318}'
(Get-ItemProperty -LiteralPath $portsClass -Name UpperFilters `
  -ErrorAction SilentlyContinue).UpperFilters
```

原始 `UpperFilters`（逐项、区分顺序）：

```text

```

- [ ] 非管理员运行被拒绝，且证书/文件/服务/注册表均未改变。
- [ ] 不兼容 Secure Boot/TestSigning 状态被拒绝，脚本未自动修改 UEFI/BCD。
- [ ] 无签名、HashMismatch、错误签名器或错误 CER 在任何写入前被拒绝。
- [ ] 任意预存同名 `CommMonitorService`/`CommMonitorFilter` 或非空安装目录在任何写入前被拒绝。
- [ ] 含 reparse、非可信 owner、其他普通用户可写 ACL 的包树被拒绝；复制前后逐文件清单一致。
- [ ] 导入测试证书前出现明确确认。
- [ ] 导入后 SYS/CAT 必须为完整 `Valid` 且签名器指纹仍与 CER 一致。
- [ ] `%ProgramData%\CommMonitor\install-backup.json` 在首次系统更改前生成。
- [ ] 备份 JSON 可解析，准确保存原始状态以及精确发布 INF、INF SHA-256、服务 ImagePath、证书动作和安装 ID；安装标记与事务备份 SHA-256 一致。
- [ ] 在证书导入后、文件复制后、PnPUtil 后和服务创建后的注入失败都只回滚本次动作。
- [ ] 安装只追加一个 `CommMonitorFilter`，保留所有原过滤器和顺序。
- [ ] 安装结束明确要求重启，未在重启前声称过滤器 active。

安装命令和退出码：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Install-CommMonitor.ps1 `
  -PackageRoot .\artifacts\phase1 `
  -ImportTestCertificate `
  -Confirm
```

记录：`____________________________________________________________`

## 5. 重启后状态

```powershell
& .\scripts\Get-CommMonitorStatus.ps1 -PassThru |
  ConvertTo-Json -Depth 8 |
  Tee-Object .\acceptance-status-after-install.json
```

| 状态 | 实际值 | 证据 |
|---|---|---|
| TestSigning |  |  |
| SecureBoot |  |  |
| 测试证书 Root |  |  |
| 测试证书 TrustedPublisher |  |  |
| UpperFilters 顺序 |  |  |
| `CommMonitorFilter` 服务 |  |  |
| 用户捕获服务 |  |  |
| 服务账户（必须 LocalSystem） |  |  |
| 控制设备 |  |  |
| 驱动协议状态 |  |  |
| AppPath |  |  |
| 会话目录 |  |  |

- [ ] `UpperFilters` 中恰好一个 `CommMonitorFilter`。
- [ ] 其他过滤器内容和顺序与预期一致。
- [ ] 控制设备可由服务打开。
- [ ] 服务显示真实 driver protocol 1 ready，不是 fake source。
- [ ] WMI 正确列出虚拟端口和 USB 端口的 PNPDeviceID。

## 6. 不占用串口和透明性

对虚拟端口和 USB 设备分别执行。目标串口程序先以其正常方式（包括独占打开）保持句柄，然后启动/暂停/继续/停止 CommMonitor。

| 场景 | 虚拟串口 | USB 串口 | 证据 |
|---|---|---|---|
| 目标程序先独占打开 |  |  |  |
| CommMonitor 刷新不改变句柄 |  |  |  |
| 开始不要求目标程序重连 |  |  |  |
| 暂停时原通信继续 |  |  |  |
| 继续时原通信继续 |  |  |  |
| 停止时原通信继续 |  |  |  |
| 关闭 App 时原通信继续 |  |  |  |
| 停止/重启服务时原通信继续 |  |  |  |
| App 强制结束时原通信继续 |  |  |  |
| 服务强制结束时原通信继续 |  |  |  |

- [ ] 原程序在整个流程中保持同一 COM 号和配置。
- [ ] 原程序无需关闭/重新打开串口句柄。
- [ ] 任何监控故障都没有改变原请求状态、长度、数据或顺序。

## 7. 字节准确性与哈希

使用确定性二进制向量，至少包含：`00`、`FF`、ASCII、随机字节、跨 4096 边界的大块、短包、高频小包和双向并发。发送/接收端必须独立保存原始日志。

```powershell
Get-FileHash -Algorithm SHA256 .\evidence\source-tx.bin
Get-FileHash -Algorithm SHA256 .\evidence\sink-rx.bin
Get-FileHash -Algorithm SHA256 .\evidence\monitor-tx.bin
Get-FileHash -Algorithm SHA256 .\evidence\monitor-rx.bin
```

| 路径 | 字节数 | SHA-256 |
|---|---:|---|
| 虚拟 source TX |  |  |
| 虚拟 sink RX |  |  |
| 虚拟 monitor TX（非截断范围） |  |  |
| 虚拟 monitor RX（非截断范围） |  |  |
| USB source TX |  |  |
| USB sink RX |  |  |
| USB monitor TX（非截断范围） |  |  |
| USB monitor RX（非截断范围） |  |  |

- [ ] 非截断范围 TX 与独立源日志逐字节一致。
- [ ] 非截断范围 RX 与独立接收日志逐字节一致。
- [ ] 事件方向、端口、完成长度、状态和顺序正确。
- [ ] 超过 4096 字节的事件明确带 `Truncated`，未被报告为完整捕获。
- [ ] 列表“标志”列直接显示 `Truncated`，并结合完成长度/HEX 字节数识别不完整负载。
- [ ] 数据库 `WireSequence` 连续，或每个驱动序号跳号都有准确 dropped 证据；列表本地 Sequence 不能替代此检查。
- [ ] 驱动 dropped、服务/IPC、UI dropped 均为 0；若非 0，本项 FAIL。

## 8. 多端口和状态机

- [ ] 同时勾选虚拟端口与 USB 端口可开始。
- [ ] 两个端口事件的 DeviceId/COM 映射正确且不串线。
- [ ] 刷新端口按 COM 数字自然排序，并清楚地要求重新勾选。
- [ ] Running 只能暂停/停止。
- [ ] Paused 只能继续/停止。
- [ ] Stopped 才能开始/清空。
- [ ] 暂停期间不产生新监控事件，恢复后本地 Sequence 和驱动 WireSequence 语义正确。
- [ ] 停止不删除既有记录。
- [ ] 清空显示 Yes/No 永久删除警告；No 不调用服务，只有显式 Yes 才删除，清空后 UI 和当前会话数据库一致。

## 9. 视图与查找

- [ ] 列表字段：序号、时间、进程、COM、方向、操作、状态、长度、标志、HEX、文本正确。
- [ ] 列表行虚拟化开启，超过 100,000 行保留策略符合说明。
- [ ] Dump 每行 16 字节，Offset/HEX/ASCII 正确。
- [ ] 终端 Read/Write 配色正确，IOCTL 不进入终端。
- [ ] ANSI、UTF-7、UTF-8、UTF-16LE、UTF-16BE 跨事件解码正确。
- [ ] 时间/端口/方向/自动换行/自动滚动开关正确。
- [ ] 终端约 2 MiB 裁剪不导致无界增长。
- [ ] 列表当前行能联动 Dump 和终端片段。
- [ ] HEX `03 ?? FF` 命中；非法 token 显示校验错误。
- [ ] HEX 不跨事件，文本固定 UTF-8 的限制与文档一致。
- [ ] 上一个/下一个循环定位正确。

## 10. 八种复制格式

测试负载 `01 03 00 FF`，保存剪贴板原文和 SHA-256/截图：

| 格式 | 精确期望/规则 | 结果 | 证据 |
|---|---|---|---|
| HEX（空格） | `01 03 00 FF` |  |  |
| HEX（紧凑） | `010300FF` |  |  |
| UTF-8 文本 | 代码点 `U+0001 U+0003 U+0000 U+FFFD` |  |  |
| C 数组 | `new byte[] { 0x01, 0x03, 0x00, 0xFF }` |  |  |
| Python bytes | `b'\x01\x03\x00\xff'` |  |  |
| TSV | 全表头、TAB、CRLF |  |  |
| CSV | RFC 4180 引号、CRLF |  |  |
| JSON | 小写驼峰键，Data 为空格 HEX |  |  |

- [ ] `Ctrl+C` 对列表选中行使用当前格式。
- [ ] `Ctrl+Shift+C` 只输出空格 HEX，不含元数据。
- [ ] 多行原始格式按选择顺序拼接。
- [ ] TSV/CSV/JSON 保留事件边界和全部默认元数据。
- [ ] 逗号、双引号、换行、空端口/进程字段边界正确。
- [ ] 没有列表多选时，Dump 当前事件可用工具栏、`Ctrl+C`、`Ctrl+Shift+C` 复制完整底层事件。
- [ ] 点选终端片段会更新当前事件、清除旧列表多选，并复制该片段的完整底层事件。
- [ ] Dump/终端目前不支持局部单元格、字节范围或任意文字子串复制，行为与文档一致且不会误复制旧列表选择。

## 11. 会话与导出

- [ ] 工具栏安全文件名在 `%ProgramData%\CommMonitor\Sessions` 创建/追加指定会话，目录/遍历/保留名被拒绝。
- [ ] 同名会话重新开始后本地 Sequence 单调追加，驱动 WireSequence 重置被保留且不冲突。
- [ ] schema v1 事务迁移到 v2，所有 CaptureEvent 字段、WireSequence 和原始 BLOB 一致。
- [ ] 打开/保存按钮完成用户流程，不再是占位提示。
- [ ] CSV 文件导出可用，UTF-8 BOM、表头和内容正确。
- [ ] TXT 文件导出可用，CRLF 和方向正确。
- [ ] raw 文件仅按序拼接 Read/Write 原始负载。
- [ ] 导出只在停止状态读取最近开始的完整持久化会话，不受 UI 100,000 行限制。
- [ ] 导出安全文件名限制在 `%ProgramData%\CommMonitor\Exports`，格式/扩展名一致，目录和遍历被拒绝。
- [ ] 导出以同目录临时文件写入并 Flush 后替换目标；失败不留下半截目标/临时文件。
- [ ] 同名导出成功覆盖旧目标且行为与“无覆盖确认”的文档一致。
- [ ] 成功后绿色状态显示完整输出路径；错误清除旧成功状态并显示红字。
- [ ] 服务异常退出后 WAL 恢复经过验证。
- [ ] 驱动重新加载/系统重启后新捕获不会与旧序号主键冲突，也不要求破坏性清空历史。
- [ ] 清空只影响最近一次成功开始的会话，且永久删除确认的 Yes/No 语义正确。
- [ ] 大会话导出峰值内存有记录，不因内存不足影响原串口通信或损坏数据库。

## 12. 数据丢失、压力和恢复

记录测试参数：

| 项目 | 实际值 |
|---|---|
| 持续时间 |  |
| 平均/峰值字节每秒 |  |
| 平均/峰值事件每秒 |  |
| 最大事件负载 |  |
| 总事件 |  |
| 驱动 queued/dropped/sequence |  |
| 服务/IPC 断开数 |  |
| UI pending dropped |  |
| 数据库事件数 |  |

- [ ] 驱动环形缓冲满时只丢监控副本，目标通信不受影响。
- [ ] 驱动 dropped 被服务读取并在 UI/状态中准确呈现。
- [ ] 截断和丢失都醒目显示，不能误报为完整数据。
- [ ] 客户端慢消费者触发有界断开，不导致服务无界内存增长。
- [ ] UI 10,000 pending 上限和丢失计数符合实现。
- [ ] 100,000 列表行和 2 MiB 终端限制符合实现。
- [ ] 服务重启、App 重启、设备热插拔后行为和错误提示可恢复。
- [ ] 数据库写入失败不影响原串口通信。

## 13. 定向 Driver Verifier

> Driver Verifier 可能导致蓝屏，只能在可恢复测试机上使用。必须只指定 `CommMonitor.Driver.sys`，绝不使用 `/all`。

启用前：

```powershell
verifier.exe /reset
verifier.exe /standard /driver CommMonitor.Driver.sys
verifier.exe /querysettings
Restart-Computer
```

重启后重复第 6、7、8、12 节关键流量与 PnP/电源路径，保存：

```powershell
verifier.exe /query
verifier.exe /querysettings
```

| 项目 | 实际值/证据 |
|---|---|
| 启用时间 |  |
| Verifier 驱动列表 |  |
| Verifier 标志 |  |
| 测试时长/流量 |  |
| 错误/蓝屏 |  |
| 转储路径 |  |

- [ ] 只验证 `CommMonitor.Driver.sys`。
- [ ] 标准检查下完成 Read/Write/IOCTL、并发、PnP、重启/停止路径。
- [ ] 没有 Verifier 错误、蓝屏、泄漏或未解决转储。

测试完成后必须关闭并重启：

```powershell
verifier.exe /reset
Restart-Computer
```

- [ ] `verifier /querysettings` 确认已无 CommMonitor 验证设置。
- [ ] 已保存关闭后的命令输出。

## 14. 卸载、精确回滚和普通启动

卸载前再次记录当前 `UpperFilters`。先验证默认“只移除”路径：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Uninstall-CommMonitor.ps1 -Confirm
Restart-Computer
```

- [ ] 用户服务停止并删除。
- [ ] `CommMonitorFilter` 服务和文件删除或明确安排重启后删除。
- [ ] 当前 `UpperFilters` 只移除 `CommMonitorFilter`，安装后其他合法项保留。
- [ ] 卸载脚本不自动修改 Secure Boot/TestSigning。
- [ ] 重启后所有串口设备和原业务通信正常。

从同一个包重新安装并重启，再验证显式精确恢复及公钥移除：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Install-CommMonitor.ps1 `
  -PackageRoot .\artifacts\phase1 `
  -ImportTestCertificate `
  -Confirm
Restart-Computer

powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\Uninstall-CommMonitor.ps1 `
  -RestoreBackup `
  -RemoveTestCertificate `
  -Confirm
Restart-Computer
```

- [ ] `-RestoreBackup` 把原始 UpperFilters 数组逐项、顺序、空/不存在状态完全恢复。
- [ ] 明确记录“精确”只覆盖 UpperFilters；旧同名服务的完整配置/运行状态不被误报为已恢复。
- [ ] `-RemoveTestCertificate` 只删除对应指纹的 LocalMachine Root/TrustedPublisher 公钥。

恢复普通启动：

```powershell
verifier.exe /reset
bcdedit.exe /set testsigning off
Restart-Computer
```

- [ ] 重启后 TestSigning 已关闭。
- [ ] 若测试人曾手工关闭 Secure Boot，已按设备流程手工恢复并记录。
- [ ] 若测试人曾暂停 BitLocker，已按组织/设备流程恢复保护。
- [ ] 测试证书按准确指纹处理，无其他证书被删除。
- [ ] 最终 `UpperFilters` 与选择的恢复策略完全一致。

最终状态证据：`________________________________________________________`

## 15. 失败/阻塞记录

| ID | 时间 | 步骤 | 现象 | 期望 | 证据 | 严重度 | 状态/负责人 |
|---|---|---|---|---|---|---|---|
|  |  |  |  |  |  |  |  |
|  |  |  |  |  |  |  |  |
|  |  |  |  |  |  |  |  |

## 16. 最终签字

- [ ] 所有必需复选框都有证据并已通过。
- [ ] 没有未解决 FAIL 或 BLOCKED。
- [ ] 虚拟串口和 USB 串口的字节哈希一致。
- [ ] 非占用/透明性经过目标程序独占句柄验证。
- [ ] 安装、更新、卸载和精确恢复均按文档复现。
- [ ] Driver Verifier 已关闭并确认。
- [ ] 系统启动安全状态已按测试计划恢复。
- [ ] 文档与本次测试包实际 UI/脚本一致。

测试人签字/日期：`________________________________________`

审核人签字/日期：`________________________________________`

最终结论：`[ ] PASS  [ ] FAIL  [ ] BLOCKED  [ ] NOT RUN`
