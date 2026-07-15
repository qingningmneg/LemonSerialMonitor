# Lemon串口监控 AI 接口设计说明

- 日期：2026-07-13
- 状态：用户已确认总体设计，书面规范已完成内部复核，待用户批准后实施
- 目标平台：Windows 10/11 x64
- 使用场景：本机 AI、自动化脚本和开发工具读取串口监控数据，辅助软硬件开发

## 1. 目标

为 Lemon串口监控增加一个专门面向 AI 的稳定接口，使本机 AI 能发现串口、控制监控生命周期、可靠读取实时与历史 TX/RX 数据、检查数据完整性并安全导出会话，从而辅助协议分析、故障定位、固件开发、上位机开发和自动生成测试代码。

AI 接口必须保持产品原有的核心边界：

- 不独占或直接打开 COM 端口；
- 不发送、注入、阻断、重放或修改串口数据；
- 不给普通用户或 AI 进程 LocalSystem 权限；
- 不让慢速、断线或异常 AI 客户端反压原始串口 I/O；
- 不把截断、丢弃或统计未知的数据伪装成完整数据。

## 2. 已确认的功能边界

AI 可以：

- 查询驱动、服务、捕获和数据完整性状态；
- 枚举可监控串口；
- 在监控空闲时开始新的捕获；
- 暂停、继续和停止由该 AI 启动的捕获；
- 枚举历史会话；
- 使用持久化游标分页读取历史事件；
- 等待新的持久化事件并在断线后续读；
- 按端口、方向、事件类型和时间范围筛选；
- 以 JSON、JSONL、CSV、TXT 或 RAW 安全导出会话；
- 获取稳定的事件结构、错误代码和完整性字段说明。

AI 不可以：

- 打开 COM 端口或直接访问内核驱动控制设备；
- 向串口发送数据；
- 注入、修改、阻断或重放原业务程序的串口请求；
- 修改波特率、校验、流控、超时或其他设备配置；
- 清空或删除会话、导出、日志或其他数据；
- 停止或改变由 WPF 客户端启动的捕获；
- 传入任意文件系统路径让 LocalSystem 服务读写。

删除和清空继续只由图形客户端在人机确认后执行。

## 3. 方案比较

### 3.1 选定方案：MCP stdio + JSON CLI

新增一个普通用户进程 `Lemon.SerialMonitor.AI.exe`：

- 默认以 MCP stdio 服务方式运行，为 AI 提供可发现、带 JSON Schema 的工具和只读资源；
- 同一可执行文件提供 JSON/JSONL CLI 子命令，为 Python、C#、PowerShell、CI 和不支持 MCP 的 AI 提供备用入口；
- 两种入口共享同一个客户端库、数据模型、校验、错误码和安全限制。

MCP stdio 不监听 TCP 端口；AI 宿主启动子进程并重定向 stdin/stdout。stdout 只能写合法 MCP JSON-RPC 消息，日志只能写 stderr。

### 3.2 暂不采用：localhost HTTP/WebSocket

HTTP/WebSocket 便于浏览器和跨语言长连接，但需要处理本地端口、随机身份令牌、Origin/CORS、DNS rebinding、端口冲突、请求配额和会话恢复。首版不开放网络监听，减少 LocalSystem 数据桥的攻击面。

### 3.3 淘汰现有混合控制管道

现有 `CommMonitor.Service.v1` 同时包含 Start、Stop、Clear、Export 等控制命令，ACL 允许本地 BuiltinUsers 读写，而且协议缺少历史分页、会话枚举、断线续读和完整性状态。若继续监听该管道，同权限 AI 或脚本可以绕过新 AI 接口直接调用 Clear/Stop，因此新服务不能只把它标记为“内部协议”。

升级后的服务停止监听 v1，改为两个职责分离的端点：

- `Lemon.SerialMonitor.Control.v2`：只供经过安装清单验证的 WPF 客户端使用，包含需要人机确认的清空等命令；
- `Lemon.SerialMonitor.AI.v1`：只包含本设计明确允许的 AI 查询、捕获租约和非覆盖导出命令。

迁移必须原子升级 WPF 和服务；任一端协议版本不匹配时拒绝操作，不回退到不安全的 v1。

专用命令集和客户端身份检查约束的是本产品支持的接口，并不是同一 Windows 用户下任意恶意代码的绝对沙箱。若 AI 宿主本身拥有执行任意本机程序或操纵桌面应用的权限，它仍受该 Windows 用户原有权限边界约束。文档必须明确这一点。

## 4. 总体架构

```text
业务程序 ──独占/使用──> COM 端口
                         │
                         ▼
CommMonitorFilter ──复制事件──> CommMonitorService
                                      │
                                      ├─ 持久化到受保护 SQLite 会话
                                      ├─ WPF 内部控制管道
                                      └─ Lemon AI 专用管道
                                                │
                                                ▼
                              Lemon.SerialMonitor.AI.exe
                                      ├─ MCP stdio
                                      └─ JSON/JSONL CLI
                                                │
                                                ▼
                                           本机 AI/脚本
```

AI 进程永远不连接 COM 端口，不打开 `\\.\Global\CommMonitorFilter`，也不直接读取 `%ProgramData%\CommMonitor\Sessions`。只有 LocalSystem 服务访问受保护的驱动和会话文件，并通过受限 DTO 返回必要数据。

## 5. 组件设计

### 5.1 Core AI 合同

在 Core 中新增独立 AI 合同和 DTO，不复用展示用途的 CopyFormatter JSON，也不把 AI 命令加入现有 `PipeCommandName`。

合同包含：

- AI 协议版本和最大帧大小；
- 请求、回复、结构化错误和事件页；
- 状态、端口、会话摘要、完整性和捕获租约 DTO；
- 筛选、游标和导出参数；
- 稳定的 JSON 序列化选项和兼容性测试。

### 5.2 WPF 控制管道 v2

新增 `Lemon.SerialMonitor.Control.v2` 并停止监听旧 v1。服务使用 `GetNamedPipeClientProcessId` 获取客户端进程，验证：

- 进程映像是受保护安装清单记录的精确 `Lemon.SerialMonitor.exe`；
- 规范化最终路径位于记录的 AppRoot；
- 文件 SHA-256 与受保护清单一致；
- 客户端 SID 与安装授权 SID 一致；
- 协议版本和一次性连接 challenge 有效。

Clear 等破坏性命令只存在于该控制管道，WPF 必须先显示明确的人机确认，再使用当前连接的一次性 confirmation nonce 提交。nonce 单次使用、短时有效并绑定客户端进程、SID 和 capture generation。Export 默认不覆盖；覆盖已有文件同样需要 WPF 确认 nonce。

这些检查防止普通 AI 客户端直接使用受支持协议绕过限制；它们不声称能抵抗已经控制或注入官方 WPF 进程的同用户恶意代码。

### 5.3 LocalSystem AI 管道服务

新增独立命名管道：

```text
Lemon.SerialMonitor.AI.v1
```

该服务只注册本设计列出的安全命令。命令枚举中不存在 Clear、Delete、Send、Inject、Replay 或设备配置修改，因此不能仅靠 MCP 层“隐藏”危险命令。

管道规则：

- LocalSystem 和 Administrators：FullControl；
- 安装时记录的交互用户 SID：ReadWrite；
- Network SID：显式拒绝；
- 不授权通用网络身份；
- 最大并发实例与 WPF 管道分开计算，避免 WPF 已占两个实例时 AI 耗尽连接；
- 每个客户端有有界请求、响应字节和等待配额。

安装器将授权用户 SID 写入受保护的安装元数据；服务只读取经验证的值。SID 必须属于最初启动安装向导的交互用户，而不是 UAC“使用其他管理员账号”时临时提供的提升账号。两者不同时，安装向导必须显示将被授权的 Windows 账号并让用户明确确认。

### 5.4 会话目录与只读读取器

新增服务端 SessionCatalog 和只读 SessionReader：

- 只枚举 Sessions 根的直接数据库文件；
- 排除 `-wal`、`-shm`、`-journal`、隐藏临时文件和未知扩展名；
- 拒绝重解析点、符号链接、联接点以及越界路径；
- 不接受客户端提供的磁盘路径；
- 用服务签发的 opaque sessionId 定位会话；
- 支持 SQLite WAL 写入期间的一致只读查询；
- 使用受保护安装密钥和规范化安全文件名生成带认证的 opaque sessionId，无需为分配 ID 而改写现有 v2 数据库；
- 分页以已持久化 sequence 为基础。

现有 `SessionStore.ReadAfterAsync(sequence, limit)` 的行为作为分页基础，但公开接口使用独立只读抽象，不能以 ReadWriteCreate 模式打开任意会话。

### 5.5 持久化捕获代际与完整性证据

会话数据库升级为向后兼容的 SQLite schema v3。迁移必须事务化且保留原 v2 事件表，新增：

- `capture_runs`：记录 runId、sessionId、capture generation、serviceInstanceId、发起端类型、授权 SID、选定设备、开始/结束 UTC、驱动统计起止快照、serviceDropped、truncationCount、statsKnown、cleanShutdown 和终止原因；
- `integrity_markers`：记录 sessionId、generation、markerType、发生时间、紧邻的已持久化 sequence 边界、增量计数和诊断 code，用于表示驱动丢弃、服务队列丢弃、持久化失败、来源重启和统计不可用；
- schema 和捕获代际元数据必须与事件数据位于同一受保护会话边界，不能只保存在服务内存或普通日志中。

每次 Start 在接收事件前采样驱动 `GET_STATS` 并创建 capture run；捕获期间定期采样，在检测到计数变化时写入 marker；Stop 在关闭会话前写入最终快照。服务启动时把没有正常结束记录的 run 标记为 interrupted，并将其完整性判定为未知。若 SQLite 暂时无法写入，服务先在受保护的恢复日志中记录持久化故障边界；恢复后将 marker 合并回对应会话。无法证明边界时宁可把整个 run 标为不完整，不能推断为零丢失。

旧 v2 会话不重写事件内容。读取时返回 `schemaVersion=2`、`statsKnown=false`、`completeForReturnedRange=false` 和 `LEGACY_INTEGRITY_UNKNOWN`。只有具备持久证据的 v3 范围才可能返回完整。

### 5.6 捕获控制租约

AI 只能在 CaptureCoordinator 为 Stopped 时开始捕获。成功后服务返回不可猜测的 `captureLeaseId` 和 capture generation。

- 服务通过命名管道模拟/令牌信息取得真实调用 SID 和 Windows 登录会话 LUID；租约绑定授权 SID、登录 LUID、随机 clientInstanceId 和 capture generation；
- Pause、Resume、Stop 必须同时提交有效 lease secret、clientInstanceId 和 generation，且当前管道身份必须与 owner 绑定一致；
- 租约只控制由该 AI Start 创建的捕获；
- WPF 已开始捕获时，AI 可以读取状态和事件，但 Start 返回 `CAPTURE_CONFLICT`；
- AI 不能停止或重置 WPF 启动的捕获；
- AI 进程断开后捕获继续，避免进程崩溃导致监控突然停止；
- MCP 和 JSON CLI 共用本机 lease vault：lease 使用 DPAPI CurrentUser 加密后保存在 `%LocalAppData%\LemonSerialMonitor\AI\leases.json`，目录 ACL 仅允许该用户和 SYSTEM，文件不得出现在 stdout、日志或示例中；
- Start 使用两阶段提交：服务先创建最长 10 秒的 pending reservation 和候选 lease，但尚不启动驱动捕获；AI 客户端把 pending lease 以“临时文件—FlushFileBuffers—原子替换”写入 vault 后提交 ACK；服务验证 ACK 后才开始捕获并激活 generation。超时、断线或写盘失败会释放 reservation，不能留下活动捕获；
- 若服务已提交 Start 但回复途中断线，已持久化的 owner 凭据仍可恢复；Stop 成功后客户端原子删除对应 vault 项。启动时发现过期 pending 项必须向服务核对后安全清除；
- 同一 SID、同一登录 LUID 和同一 clientInstanceId 可使用原 secret 恢复连接；成功恢复立即轮换 secret，并使旧值失效，避免并发重放；
- 注销、服务重启、capture generation 变化或显式 Stop 会撤销租约并返回 `LEASE_EXPIRED`；服务不提供按“同一用户名”或仅凭 sessionId 强制接管的入口；
- 租约丢失时，经过验证的 WPF 控制管道始终可让用户停止捕获；AI 没有绕过租约的强制接管入口；
- 所有创建、恢复、轮换、拒绝和撤销事件记录 correlationId、owner SID、登录 LUID、clientInstanceId 摘要和 generation，但不记录 secret。

该绑定防止支持接口中的意外串用，不宣称能隔离已完全控制同一 Windows 用户会话、能够读取该用户 DPAPI 数据的恶意代码。

AI Start 默认创建唯一的新会话名，防止意外追加或覆盖旧会话。显式标签只作为安全文件名的一部分，仍由服务生成最终名称。

### 5.7 持久化游标和实时等待

实时读取不使用无限 stdout 推流。服务提供有界长轮询：

1. 先按游标查询 SQLite；
2. 若没有新事件，注册持久化通知；
3. 注册后立即再次查询，消除查询与注册之间的竞态；
4. 最长等待 30 秒；
5. 有新事件或超时后返回有界事件页和下一游标。

游标是服务签名的 opaque 值，包含协议版本、keyId、签发/过期时间、sessionId、已扫描 sequence 和筛选摘要。更换筛选条件时必须从新游标开始，防止重复、跳过或游标跨会话复用。

安装时生成独立的 256 位随机 HMAC 签名主密钥，用 DPAPI LocalMachine 加密后保存在仅 SYSTEM/Administrators 可修改的 CoreRoot 安全元数据中，并按用途派生 cursor、resume receipt 和 sessionId 子密钥。密钥在服务重启和兼容升级中保持不变。轮换后所有 retired key 都保留到其签发的最后一个游标和 resume receipt 过期；不能只保留一个 previous key。正常轮换间隔不得短于最大有效期，紧急吊销必须返回明确的 key-retired 错误。完整卸载必须删除整个 key ring。

游标最长有效 7 天。每个成功页除 `scannedThroughSequence` 外还返回最长有效 90 天的签名 `resumeReceipt`，其绑定 sessionId、筛选摘要、已扫描 sequence、keyId 和签发/过期时间。游标过期后只有有效 receipt 才能无缺口地签发新游标；retired key 至少保留到其最后一个 receipt 过期。

游标过期、密钥退役或密钥丢失分别返回稳定的 `CURSOR_EXPIRED`、`CURSOR_KEY_RETIRED` 或 `CURSOR_KEY_UNAVAILABLE`。服务不能从未通过认证的失效游标或客户端单独提交的 sequence 中推断连续性。调用方确需从任意 sequence 开始时必须显式设置 `allowUnverifiedSeek=true`；回复返回 `CONTINUITY_UNPROVEN`，并使跨越的范围 `completeForReturnedRange=false`，不能伪装成断线续读。

AI 客户端断线后使用上一次 nextCursor 恢复。慢客户端只会落后于 SQLite，不会阻塞 CaptureCoordinator 或驱动读取线程。

## 6. MCP 工具与资源

### 6.1 工具

首版提供以下工具：

| 工具 | 作用 | 是否改变监控状态 |
|---|---|---|
| `lemon_get_status` | 返回服务、驱动、捕获、当前会话和完整性状态 | 否 |
| `lemon_list_ports` | 返回可监控端口和稳定 deviceId | 否 |
| `lemon_start_capture` | 在空闲时开始新会话并返回 leaseId | 是 |
| `lemon_pause_capture` | 暂停 AI 自己启动的捕获 | 是 |
| `lemon_resume_capture` | 继续 AI 自己暂停的捕获 | 是 |
| `lemon_stop_capture` | 停止 AI 自己启动的捕获 | 是 |
| `lemon_list_sessions` | 分页列出历史会话摘要 | 否 |
| `lemon_read_events` | 按游标和筛选分页读取事件 | 否 |
| `lemon_wait_events` | 最长等待 30 秒后返回新事件页 | 否 |
| `lemon_export_session` | 用唯一文件名导出指定会话 | 只创建新文件 |
| `lemon_get_schema` | 返回事件、完整性、游标和错误结构 | 否 |

`lemon_export_session` 不接受任意目录，不覆盖已有文件，只能在服务管理的 Exports 目录创建新文件并返回实际路径。

### 6.2 资源

MCP 还暴露只读资源：

- `lemon://docs/ai-interface`：AI 接入和安全边界；
- `lemon://schema/capture-event`：事件字段说明；
- `lemon://schema/errors`：稳定错误码；
- `lemon://schema/integrity`：数据完整性含义。

首版不增加主动发送或自动修改设备的 prompt 模板。

## 7. JSON CLI

同一可执行文件提供脚本接口，stdout 始终是 JSON 或 JSONL，stderr 只输出诊断信息，退出码稳定。

示例形态：

```text
Lemon.SerialMonitor.AI.exe status --json
Lemon.SerialMonitor.AI.exe ports --json
Lemon.SerialMonitor.AI.exe capture start --device-id <id> --json
Lemon.SerialMonitor.AI.exe sessions list --json
Lemon.SerialMonitor.AI.exe events read --session-id <id> --cursor <cursor> --json
Lemon.SerialMonitor.AI.exe events wait --session-id <id> --cursor <cursor> --jsonl
Lemon.SerialMonitor.AI.exe export --session-id <id> --format jsonl --json
```

CLI 和 MCP 使用相同服务管道，不增加网络监听，也不允许绕过 MCP 的安全限制。

## 8. 稳定事件模型

每个 AI 事件至少返回：

- `schemaVersion`；
- `sequence`、`wireSequence`：JSON 字符串，避免 64 位整数精度丢失；
- `timestampUtc`：ISO-8601 UTC；
- `qpcTicks`：字符串；
- `deviceId`：固定格式十六进制字符串；
- `portName`、`processId`、`processName`；`processName` 无法可靠解析时为空并附带状态，不伪造名称；
- `kind`：Read、Write、Ioctl、Create、Close、DropNotice、DeviceArrival 或 DeviceRemoval；
- `ioctlCodeHex`、`ntStatusHex`；
- `requestedLength`、`completedLength`、`capturedLength`；
- `flags`：字符串数组；
- `payloadBase64`：无损原始负载；
- 可选 `payloadHex` 和安全长度限制的文本预览；
- `truncated`；
- 与该页对应的 `integrity` 摘要。

响应页包含：

- `events`；
- `nextCursor`；
- `hasMore`；
- `scannedThroughSequence`；
- `resumeReceipt`；
- `integrity`；
- `warnings`。

默认每页 100 条，硬上限 1000 条，同时受 4 MiB 响应字节预算限制。达到字节预算时提前结束并返回可恢复游标。

## 9. 数据完整性语义

当前驱动每个事件最多保存 4096 字节，内核 ring 为固定容量；极大单次请求会带 `Truncated`，极高吞吐下监控副本可能被丢弃。为了不改变原业务串口请求，驱动不能通过阻塞原 I/O 来承诺无限吞吐下绝对零丢包。

AI 接口必须返回：

- `statsKnown`；
- `driverDropped`；
- `serviceDropped`；
- `truncationSeen`；
- `gapDetected`；
- `continuityProven`；
- `completeForReturnedRange`；
- 统计采样时间和捕获 generation。

服务必须接入驱动 `GET_STATS`，不能把未知丢弃数显示为 0。只要发现截断、丢弃、游标间隙或统计未知，`completeForReturnedRange` 就不能为 true，并给出稳定 warning/error code。

“完整读取”在本设计中的含义是：AI 可读取驱动实际捕获并持久化的全部字段和字节，而且任何已知不完整状态都不会被隐藏。它不表示在任意硬件、驱动和无限数据速率下数学意义的绝对无损。

## 10. 错误处理

错误回复至少包含 `code`、`message`、`retryable`、`details` 和 `correlationId`。首版稳定错误码包括：

- `SERVICE_UNAVAILABLE`；
- `DRIVER_UNAVAILABLE`；
- `PROTOCOL_MISMATCH`；
- `ACCESS_DENIED`；
- `CAPTURE_CONFLICT`；
- `INVALID_LEASE`；
- `LEASE_EXPIRED`；
- `START_RESERVATION_EXPIRED`；
- `SESSION_NOT_FOUND`；
- `INVALID_CURSOR`；
- `CURSOR_FILTER_MISMATCH`；
- `LIMIT_EXCEEDED`；
- `RESPONSE_BUDGET_EXCEEDED`；
- `EXPORT_EXISTS`；
- `DATA_GAP`；
- `INTEGRITY_UNKNOWN`；
- `LEGACY_INTEGRITY_UNKNOWN`；
- `CURSOR_EXPIRED`；
- `CURSOR_KEY_RETIRED`；
- `CURSOR_KEY_UNAVAILABLE`；
- `CONTINUITY_UNPROVEN`；
- `TIMEOUT`；
- `CANCELLED`。

断线、服务重启和长轮询超时是可恢复状态；路径越界、协议不匹配和权限错误不可自动重试。MCP 与 CLI 对同一服务错误使用相同 code。

## 11. 并发、配额和日志

- AI 管道至少支持 8 个独立实例，不占用 WPF 的 4 个实例配额；
- 每个客户端最多一个活动 wait 请求；
- wait 最长 30 秒；
- 单页最多 1000 条和 4 MiB；
- 取消或断开立即释放等待和缓冲；
- 多 AI 客户端读取同一会话不共享可变游标；
- 服务日志记录工具名、调用结果、耗时、用户 SID 和 correlationId；
- 默认日志不记录原始 payload、leaseId、完整游标或敏感数据；
- 日志失败不能影响捕获或持久化。

## 12. 安装、升级和卸载

图形安装包将 AI 组件作为 Lemon 客户端的一部分安装：

- `Lemon.SerialMonitor.AI.exe` 和共享依赖位于用户选择的 AppRoot；
- CoreRoot 包含 AI 管道服务代码和受保护授权 SID；
- 开始菜单包含《AI 接入说明》和《AI API 参考》；
- 安装器不自动修改 Codex、Claude、VS Code 或其他 AI 产品的配置；文档提供可复制配置，避免未经授权写入第三方设置；
- 升级保持 AI 协议主版本兼容，破坏性协议变化使用新管道名；
- 完整卸载先按精确路径终止 AI 子进程，再停止服务；
- 卸载删除 AI EXE、共享库、文档、安装器创建的配置样例和全部产品数据；
- 卸载还要按授权 SID 从 Windows ProfileList 推导并验证用户配置根，使用不跟随重解析点的安全删除逻辑，精确删除 `%LocalAppData%\LemonSerialMonitor\AI` 中由产品创建的 DPAPI 租约状态；身份或路径验证失败时保留并报告，不越界猜测删除；
- 用户手工复制到第三方 AI 配置中的文本不做猜测性编辑，文档明确说明如何移除；
- 不使用名称通配符删除其他 MCP 服务或第三方配置。

## 13. GitHub 文档与示例

仓库最终至少包含：

- `README.md`：Lemon串口监控简介、图形安装、快速开始和功能边界；
- `docs/INSTALL.md`：完整安装、迁移、重启和卸载；
- `docs/BUILD.md`：从源码构建客户端、服务、KMDF 驱动和安装器，列明 Visual Studio 2022、WDK、Spectre 缓解库、.NET SDK 与官方 Inno Setup 6 的版本和安装方法；
- `docs/USER_GUIDE.md`：全部界面操作；
- `docs/AI_INTEGRATION.md`：MCP 与 CLI 配置；
- `docs/AI_API_REFERENCE.md`：工具、参数、DTO、游标、错误和完整性；
- `docs/SECURITY.md`：权限、测试签名和 AI 安全边界；
- `docs/TROUBLESHOOTING.md`：驱动、服务、AI 连接和数据完整性排查；
- `examples/ai/python/`：Python JSON CLI 示例；
- `examples/ai/csharp/`：C# JSON CLI 示例；
- `examples/ai/powershell/`：PowerShell 示例；
- MCP 配置样例和可复制的协议分析工作流。

所有示例必须在构建或测试中实际运行；不能上传包含本机路径、账号、令牌、私钥或真实敏感串口数据的示例。

GitHub 发布规则：

- 首次创建私有仓库；在用户另行选择公开许可证并确认历史身份处理之前不设为公开；
- 源码 Git 历史只包含源文件、测试、文档和小型可复现样例；
- `artifacts/`、`tmp/`、`**/__pycache__/`、`*.py[cod]`、bin/obj、WDK/NuGet 缓存、`.user`、`.suo`、`.env*`、数据库、运行日志、PFX/P12/P8/PEM/KEY/PVK/SNK/CER/CRT/DER、令牌和真实捕获数据必须保持忽略；
- 最终安装 EXE、操作手册和 SHA-256 作为 GitHub Release 附件，不提交到源码 Git 历史；
- 上传前对全部待发布历史和工作树再次扫描秘密、私钥、凭据、本机路径、捕获数据以及超过 GitHub 普通 Git 单文件限制的文件；
- Release 页面和 `docs/INSTALL.md` 必须说明如何校验安装包 Authenticode 签名、发布者指纹和 `SHA256SUMS.txt`，构建文档还要给出可复现的签名后校验命令；
- 现有提交作者包含本机账号信息，私有仓库暂时保留；未来公开前只有在用户明确同意时才重写历史；
- GitHub 文档不得把未授权发布的软件宣称为开源或允许自由再分发。

## 14. 测试与验收

### 14.1 单元和协议测试

- 事件 DTO 全字段与二进制 Base64 往返；
- 超过 JavaScript 安全整数范围的 sequence/deviceId 不丢精度；
- 分页边界、筛选游标、字节预算和 nextCursor；
- wait 的“查询—注册—再查询”竞态；
- lease owner SID/LUID/clientInstanceId 绑定、恢复轮换、重放拒绝、代际、过期和 WPF 捕获冲突；
- HMAC 游标密钥持久化、服务重启、轮换、过期、退役和 sequence 恢复；
- Start reservation、vault 原子持久化、ACK、提交回复丢失和超时回滚；
- ACK 已接收但驱动启动失败、服务在提交前/后崩溃时，vault pending 项、reservation、capture generation 和 SQLite capture run 的幂等对账；
- capture_runs 与 integrity_markers 的事务写入、统计差值和旧 v2 降级语义；
- WPF Control.v2 客户端身份、challenge、确认 nonce 及旧 v1 不再监听；
- 稳定错误码和 MCP/CLI 一致性；
- stdout 只包含合法 MCP JSON-RPC 或 CLI JSON/JSONL。
- 长度前缀超限/截断、非法 JSON、过深嵌套、超长字符串、未知字段洪泛、慢速分帧和连接洪泛的协议模糊测试；超限输入必须在分配大缓冲前被拒绝，且不能占用捕获线程或阻塞正常客户端。

### 14.2 文件系统和权限测试

- sessionId 不能越界到任意路径；
- 拒绝 symlink、junction、reparse point、WAL 临时文件和非法扩展；
- 标准用户可以连接 AI 管道，但不能直接读取 Sessions、打开驱动或 COM；
- 未授权 SID 和 Network SID 被拒绝；
- AI 命令枚举中不存在 Clear/Delete/Send/Inject；
- 导出不覆盖已有文件且只能写入 Exports。

### 14.3 背压和恢复测试

- 慢 AI、挂起 AI、多 AI 与 WPF 同时运行不阻塞落库；
- AI 断线后从游标恢复，无静默重复或缺口；
- 服务重启后历史游标按规则恢复或返回明确失效错误；
- 服务重启后未完成 run 被持久标记，历史范围不被误报为完整；
- 超额请求、超大响应和取消能及时释放资源；
- 驱动 dropped/truncated/unknown 被准确传播。

### 14.4 端到端验收

1. 假数据源捕获先持久化，再由 MCP 和 CLI 读取并逐字段比对。
2. 原业务程序独占真实 COM 时，Lemon 和 AI 同时观察 RX/TX/配置事件，原业务通信不改变。
3. AI 能独立开始新监控、读取、等待、导出并停止自己的捕获。
4. WPF 已捕获时 AI 只能读取，不能抢占控制。
5. 超过 4096 字节、环满、热插拔和服务重启时完整性状态诚实准确。
6. 图形安装后 AI 文档和 EXE 可用；完整卸载后 AI 进程、管道、文件和产品数据无残留。
7. GitHub 文档中的 MCP、Python、C#、PowerShell 示例全部通过。

## 15. 非目标

- 主动串口发送、注入、阻断、重放或设备配置修改；
- 远程网络 API、云端数据上传或浏览器 WebSocket；
- 让 AI 直接访问驱动、SQLite 文件或 LocalSystem 凭据；
- 自动修改任意第三方 AI 产品配置；
- 未经用户选择许可证就公开源码仓库；
- 在无限吞吐和任意硬件条件下牺牲原业务 I/O 来追求绝对零丢包；
- 清理或删除不属于 Lemon串口监控的文件和系统历史记录。
