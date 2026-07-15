using Lemon.SerialMonitor.AI.Application;
using Lemon.SerialMonitor.AI.Cli;
using Lemon.SerialMonitor.AI.Mcp;
using Lemon.SerialMonitor.AI.Security;
using Lemon.SerialMonitor.AI.Transport;

if (!OperatingSystem.IsWindows())
{
    Console.Error.WriteLine("Lemon serial monitoring AI interface requires Windows.");
    return 4;
}

if (args.Length == 0 ||
    (args.Length == 1 && string.Equals(args[0], "mcp", StringComparison.Ordinal)))
{
    return await McpApplication.RunAsync();
}

await using var client = new AiServiceClient();
using var vault = new DpapiLeaseVault();
var commands = new LemonAiCommands(client, vault);
var cli = new CliApplication(commands);
return await cli.RunAsync(args);
