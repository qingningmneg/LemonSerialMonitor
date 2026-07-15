using Lemon.SerialMonitor.AI.Application;
using Lemon.SerialMonitor.AI.Security;
using Lemon.SerialMonitor.AI.Transport;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

namespace Lemon.SerialMonitor.AI.Mcp;

public static class McpApplication
{
    public static async Task<int> RunAsync(
        CancellationToken cancellationToken = default)
    {
        HostApplicationBuilder builder = Host.CreateApplicationBuilder([]);
        builder.Logging.ClearProviders();
        builder.Logging.AddConsole(options =>
            options.LogToStandardErrorThreshold = LogLevel.Trace);
        builder.Services.AddSingleton<IAiServiceClient, AiServiceClient>();
        builder.Services.AddSingleton<DpapiLeaseVault>();
        builder.Services.AddSingleton<ILeaseVault>(
            services => services.GetRequiredService<DpapiLeaseVault>());
        builder.Services.AddSingleton<LemonAiCommands>();
        builder.Services
            .AddMcpServer()
            .WithStdioServerTransport()
            .WithTools<LemonMcpTools>()
            .WithResources<LemonMcpResources>();

        await builder.Build().RunAsync(cancellationToken).ConfigureAwait(false);
        return 0;
    }
}
