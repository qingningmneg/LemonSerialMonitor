using System.Reflection;
using Lemon.SerialMonitor.AI.Mcp;
using ModelContextProtocol.Client;
using ModelContextProtocol.Server;

namespace Lemon.SerialMonitor.AI.Tests.Mcp;

public sealed class McpApplicationTests
{
    [Fact]
    public async Task Stdio_server_negotiates_and_lists_the_real_tool_and_resource_surfaces()
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        using var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(20));
        Dictionary<string, string?> environment =
            StdioClientTransportOptions.GetDefaultEnvironmentVariables();
        var transport = new StdioClientTransport(new StdioClientTransportOptions
        {
            Name = "lemon-mcp-integration-test",
            Command = "dotnet",
            Arguments = [typeof(McpApplication).Assembly.Location, "mcp"],
            WorkingDirectory = AppContext.BaseDirectory,
            InheritEnvironmentVariables = false,
            EnvironmentVariables = environment,
            ShutdownTimeout = TimeSpan.FromSeconds(5),
        });
        await using McpClient client = await McpClient.CreateAsync(
            transport,
            cancellationToken: cancellation.Token);

        await client.PingAsync(cancellationToken: cancellation.Token);
        var tools = await client.ListToolsAsync(cancellationToken: cancellation.Token);
        var resources = await client.ListResourcesAsync(cancellationToken: cancellation.Token);

        Assert.Equal(11, tools.Count);
        Assert.Equal(4, resources.Count);
        Assert.Contains(tools, tool => tool.Name == "lemon_get_status");
        Assert.Contains(
            resources,
            resource => resource.Uri == "lemon://docs/ai-interface");
    }

    [Fact]
    public void Tool_surface_is_exact_and_contains_no_dangerous_operations()
    {
        string[] names = typeof(LemonMcpTools)
            .GetMethods(BindingFlags.Public | BindingFlags.Instance | BindingFlags.DeclaredOnly)
            .Select(method => method.GetCustomAttribute<McpServerToolAttribute>())
            .Where(static attribute => attribute is not null)
            .Select(static attribute => attribute!.Name!)
            .Order(StringComparer.Ordinal)
            .ToArray();

        Assert.Equal(
            [
                "lemon_export_session",
                "lemon_get_schema",
                "lemon_get_status",
                "lemon_list_ports",
                "lemon_list_sessions",
                "lemon_pause_capture",
                "lemon_read_events",
                "lemon_resume_capture",
                "lemon_start_capture",
                "lemon_stop_capture",
                "lemon_wait_events",
            ],
            names);
        Assert.DoesNotContain(
            names,
            name => name.Contains("send", StringComparison.OrdinalIgnoreCase) ||
                    name.Contains("inject", StringComparison.OrdinalIgnoreCase) ||
                    name.Contains("replay", StringComparison.OrdinalIgnoreCase) ||
                    name.Contains("delete", StringComparison.OrdinalIgnoreCase) ||
                    name.Contains("clear", StringComparison.OrdinalIgnoreCase));

        string[] parameters = typeof(LemonMcpTools)
            .GetMethods(BindingFlags.Public | BindingFlags.Instance | BindingFlags.DeclaredOnly)
            .Where(method => method.GetCustomAttribute<McpServerToolAttribute>() is not null)
            .SelectMany(static method => method.GetParameters())
            .Select(static parameter => parameter.Name!)
            .ToArray();
        Assert.DoesNotContain(parameters, name =>
            name.Contains("path", StringComparison.OrdinalIgnoreCase) ||
            name.Contains("overwrite", StringComparison.OrdinalIgnoreCase) ||
            name.Contains("secret", StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    public void Resource_surface_is_exact_and_offline_content_is_valid()
    {
        MethodInfo[] methods = typeof(LemonMcpResources)
            .GetMethods(BindingFlags.Public | BindingFlags.Instance | BindingFlags.DeclaredOnly)
            .Where(method => method.GetCustomAttribute<McpServerResourceAttribute>() is not null)
            .ToArray();
        string[] uris = methods
            .Select(method => method.GetCustomAttribute<McpServerResourceAttribute>()!.UriTemplate!)
            .Order(StringComparer.Ordinal)
            .ToArray();

        Assert.Equal(
            [
                "lemon://docs/ai-interface",
                "lemon://schema/capture-event",
                "lemon://schema/errors",
                "lemon://schema/integrity",
            ],
            uris);

        var resources = new LemonMcpResources();
        Assert.Contains("不会打开或占用串口", resources.InterfaceGuide());
        using System.Text.Json.JsonDocument eventSchema =
            System.Text.Json.JsonDocument.Parse(resources.CaptureEventSchema());
        using System.Text.Json.JsonDocument errorSchema =
            System.Text.Json.JsonDocument.Parse(resources.ErrorSchema());
        using System.Text.Json.JsonDocument integritySchema =
            System.Text.Json.JsonDocument.Parse(resources.IntegritySchema());
    }
}
