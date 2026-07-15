using System.Text.Json;
using System.Text.Json.Serialization;

namespace CommMonitor.Core.Ai;

public static class AiProtocol
{
    public const int Version = 1;
    public const string PipeName = "Lemon.SerialMonitor.AI.v1";
    public const int DefaultPageSize = 100;
    public const int MaximumPageSize = 1000;
    public const int MaximumResponseBytes = 4 * 1024 * 1024;
    public static readonly TimeSpan MaximumWait = TimeSpan.FromSeconds(30);
}

public static class AiCommandNames
{
    public const string Status = "status";
    public const string Ports = "ports";
    public const string PrepareStart = "prepare-start";
    public const string CommitStart = "commit-start";
    public const string RecoverLease = "recover-lease";
    public const string Pause = "pause";
    public const string Resume = "resume";
    public const string Stop = "stop";
    public const string Sessions = "sessions";
    public const string Read = "read";
    public const string Wait = "wait";
    public const string Export = "export";
    public const string Schema = "schema";
}

public static class AiJson
{
    public static JsonSerializerOptions CreateOptions()
    {
        var options = new JsonSerializerOptions(JsonSerializerDefaults.Web)
        {
            MaxDepth = 64,
            UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
        };
        options.Converters.Add(new JsonStringEnumConverter(allowIntegerValues: false));
        return options;
    }
}
