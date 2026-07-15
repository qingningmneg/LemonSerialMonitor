using System.ComponentModel;
using System.Text.Json;
using CommMonitor.Core.Ai;
using ModelContextProtocol.Server;

namespace Lemon.SerialMonitor.AI.Mcp;

[McpServerResourceType]
public sealed class LemonMcpResources
{
    private static readonly JsonSerializerOptions JsonOptions = AiJson.CreateOptions();

    [McpServerResource(
        UriTemplate = "lemon://docs/ai-interface",
        Name = "lemon_ai_interface",
        MimeType = "text/markdown")]
    [Description("Lemon串口监控 AI 接口的安全使用说明。")]
    public string InterfaceGuide() =>
        """
        # Lemon串口监控 AI 接口

        本接口只通过本机命名管道读取服务已经提交的数据，不会打开或占用串口。
        先调用 lemon_list_ports 获取设备标识，再调用 lemon_start_capture。
        使用 lemon_list_sessions、lemon_read_events 或 lemon_wait_events 读取数据。
        每页都应检查 integrity、warnings、nextCursor 和 resumeReceipt。
        接口不提供发送、注入、重放、清空、删除、覆盖或任意路径访问能力。
        """;

    [McpServerResource(
        UriTemplate = "lemon://schema/capture-event",
        Name = "lemon_capture_event_schema",
        MimeType = "application/json")]
    [Description("串口捕获事件主要字段与负载编码说明。")]
    public string CaptureEventSchema() => JsonSerializer.Serialize(
        new
        {
            schemaVersion = AiProtocol.Version,
            identifiers = new[] { "sequence", "wireSequence", "deviceId" },
            time = new[] { "timestampUtc", "qpcTicks" },
            process = new[] { "processId", "processName", "processNameStatus" },
            operation = new[]
            {
                "kind", "ioctlCodeHex", "ntStatusHex", "requestedLength",
                "completedLength", "capturedLength", "flags",
            },
            payload = new[] { "payloadBase64", "payloadHex", "textPreview", "truncated" },
        },
        JsonOptions);

    [McpServerResource(
        UriTemplate = "lemon://schema/errors",
        Name = "lemon_error_schema",
        MimeType = "application/json")]
    [Description("稳定错误信封和错误码。")]
    public string ErrorSchema() => JsonSerializer.Serialize(
        new
        {
            fields = new[] { "code", "message", "retryable", "correlationId", "details" },
            codes = typeof(AiErrorCodes)
                .GetFields(System.Reflection.BindingFlags.Public |
                           System.Reflection.BindingFlags.Static)
                .Where(static field => field.IsLiteral && field.FieldType == typeof(string))
                .Select(static field => (string)field.GetRawConstantValue()!)
                .Order(StringComparer.Ordinal),
        },
        JsonOptions);

    [McpServerResource(
        UriTemplate = "lemon://schema/integrity",
        Name = "lemon_integrity_schema",
        MimeType = "application/json")]
    [Description("会话完整性字段及安全解释规则。")]
    public string IntegritySchema() => JsonSerializer.Serialize(
        new
        {
            fields = new[]
            {
                "statsKnown", "driverDropped", "serviceDropped", "truncationSeen",
                "gapDetected", "continuityProven", "completeForReturnedRange",
                "statisticsSampledAtUtc", "generation",
            },
            rule = "Only treat a returned range as complete when completeForReturnedRange is true.",
        },
        JsonOptions);
}
