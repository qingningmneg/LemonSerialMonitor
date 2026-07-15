using System.Collections.Immutable;
using System.Text.Json;
using System.Text.Json.Serialization;
using CommMonitor.Core.Control;
using CommMonitor.Core.Models;

namespace CommMonitor.Core.Ipc;

public static class PipeProtocol
{
    public const int Version = ControlProtocol.Version;
    public const int MaximumFrameLength = 16 * 1024 * 1024;
    public const string PipeName = ControlProtocol.PipeName;
}

public enum PipeCommandName
{
    ListPorts = 1,
    Start,
    Pause,
    Resume,
    Stop,
    Clear,
    Subscribe,
    Export,
}

public sealed record PipeCommand
{
    [JsonConstructor]
    public PipeCommand(
        string requestId,
        PipeCommandName command,
        IReadOnlyList<ulong>? deviceIds = null,
        string? sessionPath = null,
        string? exportPath = null,
        string? exportFormat = null,
        int version = PipeProtocol.Version)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(requestId);
        if (!Enum.IsDefined(command))
        {
            throw new ArgumentException("A pipe command name is required.", nameof(command));
        }

        Version = version;
        RequestId = requestId;
        Command = command;
        DeviceIds = deviceIds?.ToArray() ?? [];
        SessionPath = sessionPath;
        ExportPath = exportPath;
        ExportFormat = exportFormat;
    }

    public int Version { get; }
    public string RequestId { get; }
    public PipeCommandName Command { get; }
    public IReadOnlyList<ulong> DeviceIds { get; }
    public string? SessionPath { get; }
    public string? ExportPath { get; }
    public string? ExportFormat { get; }
}

public sealed record PipeReply
{
    [JsonConstructor]
    public PipeReply(
        string requestId,
        bool success,
        string? error = null,
        JsonElement? result = null,
        int version = PipeProtocol.Version)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(requestId);

        Version = version;
        RequestId = requestId;
        Success = success;
        Error = error;
        Result = result;
    }

    public int Version { get; }
    public string RequestId { get; }
    public bool Success { get; }
    public string? Error { get; }
    public JsonElement? Result { get; }
}

public sealed record PipeEventBatch
{
    [JsonConstructor]
    public PipeEventBatch(
        ImmutableArray<CaptureEvent> events,
        int version = PipeProtocol.Version)
    {
        if (events.IsDefault)
        {
            throw new ArgumentException("The event batch must be initialized.", nameof(events));
        }

        Version = version;
        Events = events;
    }

    public int Version { get; }
    public ImmutableArray<CaptureEvent> Events { get; }
}
