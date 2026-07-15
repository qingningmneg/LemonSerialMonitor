# Lemon串口监控 AI 接入指南

Lemon串口监控提供两个面向自动化的入口：标准 MCP stdio 服务和 JSON 命令行。两者都通过安装在本机的受信任客户端连接后台服务，不直接打开 COM 端口，也不开放网络监听。

## 能做什么

- 查看服务、驱动、捕获和数据完整性状态
- 列出当前串口及稳定设备标识
- 开始、暂停、继续、停止捕获
- 分页列出持久化会话
- 按游标读取事件或等待新事件
- 按端口、事件类型和 UTC 时间过滤
- 读取 HEX、Base64 和有限文本预览
- 导出 JSON、JSONL、CSV、TXT 或 RAW
- 读取字段、错误码和完整性协议描述

接口故意不提供发送、注入、重放、修改、清空、删除、覆盖或任意文件读写能力。

## 安全模型

AI 接口只使用本机命名管道。后台服务在接受请求前会核验：

- 安装时授权的 Windows 用户 SID
- 当前登录会话标识
- 客户端进程映像的规范路径
- 客户端文件 SHA-256
- 管道访问控制与协议版本

租约密钥由当前 Windows 用户的 DPAPI 保护，不写入标准输出、MCP 返回值或文档。不要复制 AI 可执行文件到其他目录运行，也不要让其他用户共用同一租约目录。

## 找到客户端

默认路径：

```text
C:\Program Files\Lemon串口监控\ai\Lemon.SerialMonitor.AI.exe
```

安装时选择了其他目录，就把以下示例中的路径换成实际安装位置。Server Core 的 AI 客户端安装在受保护核心目录，安装文档会给出实际位置。

## MCP 配置

把 [mcp-config.json](../examples/ai/mcp-config.json) 中的绝对路径改成实际安装位置，再合并到支持 MCP stdio 的客户端配置中：

```json
{
  "mcpServers": {
    "lemon-serial-monitor": {
      "command": "C:\\Program Files\\Lemon串口监控\\ai\\Lemon.SerialMonitor.AI.exe",
      "args": ["mcp"]
    }
  }
}
```

不带参数启动 AI 客户端也会进入 MCP 模式，但明确写 `mcp` 更容易审计。

连接成功后应看到 11 个工具和 4 个资源。先调用 `lemon_get_status`，再调用 `lemon_list_ports`。

推荐的 AI 工作顺序：

1. `lemon_get_status`：确认服务、驱动和捕获状态。
2. `lemon_list_ports`：取得 16 位十六进制 `deviceId`。
3. `lemon_start_capture`：传入一个或多个 `deviceId`，保存返回的 `leaseId`。
4. 让原业务软件操作硬件。
5. `lemon_list_sessions`：取得 `sessionId`。
6. `lemon_read_events` 或 `lemon_wait_events`：按游标读取。
7. 每页检查 `integrity` 和 `warnings`，保存 `nextCursor` 与 `resumeReceipt`。
8. `lemon_stop_capture`：使用原 `leaseId` 停止。
9. 需要文件时调用 `lemon_export_session`。

## 命令行快速检查

PowerShell：

```powershell
$lemon = 'C:\Program Files\Lemon串口监控\ai\Lemon.SerialMonitor.AI.exe'
& $lemon status --json
& $lemon ports --json
& $lemon schema --json
```

开始捕获前，从 `ports --json` 返回值复制完整的 16 位 `deviceId`：

```powershell
& $lemon capture start --device-id 0000000000000011 --label board-test --json
```

返回值包含 `leaseId`。暂停、继续、停止：

```powershell
& $lemon capture pause  --lease-id '<leaseId>' --json
& $lemon capture resume --lease-id '<leaseId>' --json
& $lemon capture stop   --lease-id '<leaseId>' --json
```

列出会话：

```powershell
& $lemon sessions list --limit 100 --json
```

读取一页事件：

```powershell
& $lemon events read `
  --session-id '<sessionId>' `
  --limit 100 `
  --include-hex `
  --include-text-preview `
  --json
```

等待新事件，最长 30 秒，以 JSONL 输出：

```powershell
& $lemon events wait `
  --session-id '<sessionId>' `
  --cursor '<nextCursor>' `
  --resume-receipt '<resumeReceipt>' `
  --limit 100 `
  --timeout-seconds 30 `
  --include-hex `
  --jsonl
```

导出：

```powershell
& $lemon export --session-id '<sessionId>' --format jsonl --label board-test --json
```

可用格式：`json`、`jsonl`、`csv`、`txt`、`raw`。`label` 是安全标签，不是文件路径；输出位置由服务管理，接口不会覆盖已有文件。

## 分页与断点续读

正常读取使用服务返回的 `nextCursor` 和 `resumeReceipt`，不要自行猜测数据库序号。游标和回执共同证明续读位置属于同一会话、同一代捕获状态。

只有在明确接受“无法验证连续性”的情况下，才使用：

```text
--after-sequence <十进制序号> --allow-unverified-seek
```

这种读取可能漏掉、重复或跨过无法证明的范围，结果必须标注为未验证定位。

## 完整性判断

每一页至少检查：

```text
integrity.completeForReturnedRange
integrity.driverDropped
integrity.serviceDropped
integrity.truncationSeen
integrity.gapDetected
integrity.continuityProven
warnings
```

只有 `completeForReturnedRange` 为 `true`，才能说“本页返回范围完整”。否则 AI 应明确说明存在丢弃、截断、缺口或连续性证据不足，不能把缺失数据补写成事实。

## 事件正文怎么用

- `payloadBase64`：最稳定的机器读取形式，适合还原原始字节。
- `payloadHex`：仅在请求 `includeHex` 时返回，便于人和协议分析。
- `textPreview`：有限长度、按边界解码的预览，不能替代原始字节。
- `capturedLength`：实际保存长度。
- `completedLength`：串口操作完成长度。
- `truncated` 或截断标志：说明原事件大于捕获上限。

硬件协议分析应以 Base64/HEX 原始字节和协议文档为准，不要只依赖文本预览。

## 示例脚本

- [PowerShell：读取最新会话](../examples/ai/read-latest-session.ps1)
- [Python：调用 JSON CLI](../examples/ai/read_events.py)
- [MCP 配置](../examples/ai/mcp-config.json)

完整工具参数、资源 URI、退出码和稳定错误码见 [AI 接口参考](AI_API_REFERENCE.md)。
