# Lemon串口监控 AI 接口参考

## 传输与版本

- MCP：标准输入/标准输出（stdio）
- CLI：标准输出为 UTF-8 JSON 或 JSONL，诊断写入标准错误
- 服务传输：仅本机命名管道
- 网络监听：无
- 页面大小：1–1000，默认 100
- 等待超时：1–30 秒，默认 30 秒
- 文本预览上限：1–4096 字节，默认 256 字节

运行 `schema --json` 或调用 `lemon_get_schema` 可读取当前协议版本、允许命令、事件字段和错误码。

## MCP 工具

### `lemon_get_status`

读取服务、驱动、捕获、所有者与数据完整性概况。无参数。

### `lemon_list_ports`

列出当前串口。返回显示名称和 16 位十六进制 `deviceId`。不会打开 COM 端口。

### `lemon_start_capture`

参数：

- `deviceIds`：一个或多个 16 位十六进制设备标识
- `label`：可选会话标签，不是路径

返回 `leaseId`、`sessionId`、`generation` 和捕获状态。租约密钥不会返回。

### `lemon_pause_capture`

参数：`leaseId`。暂停属于该租约的捕获。

### `lemon_resume_capture`

参数：`leaseId`。继续属于该租约的捕获。

### `lemon_stop_capture`

参数：`leaseId`。停止后从当前用户受保护租约库移除租约。

### `lemon_list_sessions`

参数：

- `cursor`：可选分页游标
- `limit`：1–1000

返回持久化会话的安全 `sessionId`。`sessionId` 不是文件路径。

### `lemon_read_events`

参数：

- `sessionId`：必填
- `cursor`：正常续页游标
- `resumeReceipt`：与上一页匹配的续读回执
- `afterSequence`：可选十进制序号，仅用于未验证定位
- `allowUnverifiedSeek`：使用 `afterSequence` 时必须为 `true`
- `limit`：1–1000
- `deviceIds`：可重复的设备过滤器
- `kinds`：可重复的事件类型过滤器，例如 `Read`、`Write`
- `includeHex`：是否返回 `payloadHex`
- `includeTextPreview`：是否返回有限文本预览

MCP 工具提供常用过滤字段；CLI 另提供 `fromUtc`、`toUtc` 和文本预览长度。

### `lemon_wait_events`

参数与 `lemon_read_events` 相同，另有 `timeoutSeconds`（1–30）。在超时或有已提交事件时返回一页，不返回未提交的内存事件。

### `lemon_export_session`

参数：

- `sessionId`
- `format`：`json`、`jsonl`、`csv`、`txt`、`raw`
- `label`：可选安全标签

服务创建唯一新文件，不接受目录，不覆盖已有文件。

### `lemon_get_schema`

读取协议版本、命令、事件字段和稳定错误码。

## MCP 资源

- `lemon://docs/ai-interface`：安全使用说明
- `lemon://schema/capture-event`：事件字段与负载说明
- `lemon://schema/errors`：错误信封和错误码
- `lemon://schema/integrity`：完整性字段与判定规则

## CLI 命令

```text
status --json
ports --json
capture start --device-id <16hex> [--device-id <16hex> ...] [--label <text>] --json
capture pause --lease-id <id> --json
capture resume --lease-id <id> --json
capture stop --lease-id <id> --json
sessions list [--cursor <cursor>] [--limit 1..1000] --json
events read --session-id <id> [options] --json
events wait --session-id <id> [options] --jsonl
export --session-id <id> --format <json|jsonl|csv|txt|raw> [--label <text>] --json
schema --json
```

`events read` / `events wait` 选项：

```text
--cursor <cursor>
--resume-receipt <receipt>
--after-sequence <decimal> --allow-unverified-seek
--limit 1..1000
--device-id <16hex>              可重复
--kind <Read|Write|...>          可重复
--from-utc <ISO-8601>
--to-utc <ISO-8601>
--include-hex
--include-text-preview
--text-preview-max-bytes 1..4096
--timeout-seconds 1..30          仅 wait
```

`events wait --jsonl` 每个事件输出一行 JSON，最后输出一行 `_page` 元数据，其中包含游标、回执、是否还有数据、扫描到的序号、完整性和警告。

## CLI 退出码

| 退出码 | 含义 |
|---:|---|
| 0 | 成功 |
| 2 | 参数无效 |
| 3 | 访问被拒绝或协议不匹配 |
| 4 | 服务或驱动不可用 |
| 5 | 捕获冲突或租约错误 |
| 6 | 数据缺口或完整性不足 |
| 7 | 超时或取消 |
| 10 | 未预期错误 |

即使失败，标准输出仍是结构化错误信封：

```json
{
  "success": false,
  "error": {
    "code": "SERVICE_UNAVAILABLE",
    "message": "...",
    "retryable": true,
    "correlationId": "..."
  }
}
```

自动化程序应判断进程退出码并解析 `error.code`，不要匹配本地化提示文字。

## 主要事件字段

| 字段 | 说明 |
|---|---|
| `sequence` | 会话内持久化序号 |
| `wireSequence` | 驱动/服务传输序号证据 |
| `timestampUtc` | UTC 时间 |
| `qpcTicks` | 高精度计数器时间证据 |
| `deviceId` | 稳定设备标识 |
| `portName` | 显示用 COM 名称 |
| `processId` / `processName` | 发起进程信息 |
| `kind` | Read、Write、Ioctl、DropNotice 等 |
| `ioctlCodeHex` | IOCTL 十六进制值 |
| `ntStatusHex` | NTSTATUS 十六进制值 |
| `requestedLength` | 请求长度 |
| `completedLength` | 完成长度 |
| `capturedLength` | 实际保存长度 |
| `flags` | 截断、丢失等标志 |
| `payloadBase64` | 原始字节 Base64 |
| `payloadHex` | 可选 HEX 视图 |
| `textPreview` | 可选有限文本预览 |

## 完整性字段

| 字段 | 说明 |
|---|---|
| `statsKnown` | 是否取得驱动/服务统计证据 |
| `driverDropped` | 驱动环形缓冲丢弃计数 |
| `serviceDropped` | 服务侧丢弃计数 |
| `truncationSeen` | 返回范围是否出现截断 |
| `gapDetected` | 是否发现序号或提交缺口 |
| `continuityProven` | 游标续读连续性是否成立 |
| `completeForReturnedRange` | 返回范围能否声明完整 |
| `statisticsSampledAtUtc` | 统计采样时间 |
| `generation` | 捕获代号 |

规则：只有 `completeForReturnedRange == true` 时，调用方才能把返回范围标为完整。

## 并发和租约

- 一个捕获状态由桌面客户端或一个 AI 租约拥有，冲突请求会返回稳定错误。
- AI 开始采用准备/提交两阶段流程，客户端把租约密钥写入当前用户 DPAPI 保险库后才提交。
- 客户端重启会先执行租约对账；过期、失效或不属于当前登录会话的租约会被清理。
- 不要把 `leaseId` 当作密钥；它只是引用，真正证明保存在受保护本机状态中。
