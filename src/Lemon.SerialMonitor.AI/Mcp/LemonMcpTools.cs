using System.ComponentModel;
using System.Text.Json;
using CommMonitor.Core.Ai;
using Lemon.SerialMonitor.AI.Application;
using Lemon.SerialMonitor.AI.Transport;
using ModelContextProtocol;
using ModelContextProtocol.Server;

namespace Lemon.SerialMonitor.AI.Mcp;

[McpServerToolType]
public sealed class LemonMcpTools(LemonAiCommands commands)
{
    private static readonly JsonSerializerOptions JsonOptions = AiJson.CreateOptions();

    [McpServerTool(Name = "lemon_get_status")]
    [Description("读取监控服务、驱动、捕获状态和数据完整性状态。")]
    public Task<string> GetStatusAsync(CancellationToken cancellationToken) =>
        InvokeAsync(() => commands.GetStatusAsync(cancellationToken));

    [McpServerTool(Name = "lemon_list_ports")]
    [Description("列出当前存在的串口及其稳定设备标识；不会打开或占用串口。")]
    public Task<string> ListPortsAsync(CancellationToken cancellationToken) =>
        InvokeAsync(() => commands.ListPortsAsync(cancellationToken));

    [McpServerTool(Name = "lemon_start_capture")]
    [Description("开始被动监控指定串口。返回租约标识但绝不返回租约密钥。")]
    public Task<string> StartCaptureAsync(
        [Description("一个或多个 16 位十六进制设备标识。")]
        string[] deviceIds,
        [Description("可选的会话标签，不是文件路径。")]
        string? label,
        CancellationToken cancellationToken) =>
        InvokeAsync(() => commands.StartCaptureAsync(deviceIds, label, cancellationToken));

    [McpServerTool(Name = "lemon_pause_capture")]
    [Description("暂停当前用户保险库中指定租约对应的捕获。")]
    public Task<string> PauseCaptureAsync(
        [Description("lemon_start_capture 返回的租约标识。")]
        string leaseId,
        CancellationToken cancellationToken) =>
        InvokeAsync(() => commands.PauseCaptureAsync(leaseId, cancellationToken));

    [McpServerTool(Name = "lemon_resume_capture")]
    [Description("恢复当前用户保险库中指定租约对应的捕获。")]
    public Task<string> ResumeCaptureAsync(
        [Description("lemon_start_capture 返回的租约标识。")]
        string leaseId,
        CancellationToken cancellationToken) =>
        InvokeAsync(() => commands.ResumeCaptureAsync(leaseId, cancellationToken));

    [McpServerTool(Name = "lemon_stop_capture")]
    [Description("停止指定租约的捕获，并在成功后清除本机受保护租约。")]
    public Task<string> StopCaptureAsync(
        [Description("lemon_start_capture 返回的租约标识。")]
        string leaseId,
        CancellationToken cancellationToken) =>
        InvokeAsync(() => commands.StopCaptureAsync(leaseId, cancellationToken));

    [McpServerTool(Name = "lemon_list_sessions")]
    [Description("分页列出由服务管理的持久化监控会话。")]
    public Task<string> ListSessionsAsync(
        [Description("上一页返回的可选游标。")]
        string? cursor = null,
        [Description("每页 1 到 1000 条，默认 100。")]
        int limit = AiProtocol.DefaultPageSize,
        CancellationToken cancellationToken = default) =>
        InvokeAsync(() => commands.ListSessionsAsync(
            new ListSessionsRequest(cursor, limit),
            cancellationToken));

    [McpServerTool(Name = "lemon_read_events")]
    [Description("从持久化会话读取一页已提交串口事件，并返回续读游标、回执和完整性证据。")]
    public Task<string> ReadEventsAsync(
        [Description("lemon_list_sessions 返回的会话标识。")]
        string sessionId,
        [Description("上一页返回的可选游标。")]
        string? cursor = null,
        [Description("上一页返回的可选续读回执。")]
        string? resumeReceipt = null,
        [Description("仅在明确允许未验证定位时使用的十进制序列。")]
        string? afterSequence = null,
        [Description("是否明确允许按 afterSequence 未验证定位。")]
        bool allowUnverifiedSeek = false,
        [Description("每页 1 到 1000 条，默认 100。")]
        int limit = AiProtocol.DefaultPageSize,
        [Description("可选设备标识过滤器。")]
        string[]? deviceIds = null,
        [Description("可选事件类型过滤器，如 Read 或 Write。")]
        string[]? kinds = null,
        [Description("是否包含十六进制负载视图。")]
        bool includeHex = false,
        [Description("是否包含有界文本预览。")]
        bool includeTextPreview = false,
        CancellationToken cancellationToken = default) =>
        InvokeAsync(() => commands.ReadEventsAsync(
            new ReadEventsRequest(
                sessionId,
                cursor,
                resumeReceipt,
                afterSequence,
                allowUnverifiedSeek,
                limit,
                new AiEventFilter(
                    deviceIds,
                    kinds,
                    null,
                    null,
                    includeHex,
                    includeTextPreview,
                    256)),
            cancellationToken));

    [McpServerTool(Name = "lemon_wait_events")]
    [Description("等待会话出现已提交事件，最长 30 秒，然后返回一页事件和完整性证据。")]
    public Task<string> WaitEventsAsync(
        [Description("lemon_list_sessions 返回的会话标识。")]
        string sessionId,
        [Description("上一页返回的可选游标。")]
        string? cursor = null,
        [Description("上一页返回的可选续读回执。")]
        string? resumeReceipt = null,
        [Description("仅在明确允许未验证定位时使用的十进制序列。")]
        string? afterSequence = null,
        [Description("是否明确允许按 afterSequence 未验证定位。")]
        bool allowUnverifiedSeek = false,
        [Description("每页 1 到 1000 条，默认 100。")]
        int limit = AiProtocol.DefaultPageSize,
        [Description("等待 1 到 30 秒，默认 30。")]
        int timeoutSeconds = 30,
        [Description("可选设备标识过滤器。")]
        string[]? deviceIds = null,
        [Description("可选事件类型过滤器。")]
        string[]? kinds = null,
        [Description("是否包含十六进制负载视图。")]
        bool includeHex = false,
        [Description("是否包含有界文本预览。")]
        bool includeTextPreview = false,
        CancellationToken cancellationToken = default) =>
        InvokeAsync(() => commands.WaitEventsAsync(
            new WaitEventsRequest(
                sessionId,
                cursor,
                resumeReceipt,
                afterSequence,
                allowUnverifiedSeek,
                limit,
                new AiEventFilter(
                    deviceIds,
                    kinds,
                    null,
                    null,
                    includeHex,
                    includeTextPreview,
                    256),
                timeoutSeconds),
            cancellationToken));

    [McpServerTool(Name = "lemon_export_session")]
    [Description("将会话导出到服务管理的唯一新文件；不接受目录，也不会覆盖文件。")]
    public Task<string> ExportSessionAsync(
        [Description("lemon_list_sessions 返回的会话标识。")]
        string sessionId,
        [Description("json、jsonl、csv、txt 或 raw。")]
        string format,
        [Description("可选安全标签，不是文件路径。")]
        string? label = null,
        CancellationToken cancellationToken = default) =>
        InvokeAsync(() => commands.ExportAsync(
            new ExportSessionRequest(sessionId, format, label),
            cancellationToken));

    [McpServerTool(Name = "lemon_get_schema")]
    [Description("读取 AI 协议版本、允许命令、事件字段和稳定错误码。")]
    public Task<string> GetSchemaAsync(CancellationToken cancellationToken) =>
        InvokeAsync(() => commands.GetSchemaAsync(cancellationToken));

    private static async Task<string> InvokeAsync<T>(Func<Task<T>> operation)
    {
        try
        {
            T result = await operation().ConfigureAwait(false);
            return JsonSerializer.Serialize(result, JsonOptions);
        }
        catch (LemonAiException exception)
        {
            throw new McpException(JsonSerializer.Serialize(
                new { success = false, error = exception.Error },
                JsonOptions));
        }
        catch (ArgumentException exception)
        {
            throw new McpException(JsonSerializer.Serialize(
                new
                {
                    success = false,
                    error = new AiError(
                        AiErrorCodes.ProtocolMismatch,
                        exception.Message,
                        false,
                        Guid.NewGuid().ToString("N")),
                },
                JsonOptions));
        }
    }
}
