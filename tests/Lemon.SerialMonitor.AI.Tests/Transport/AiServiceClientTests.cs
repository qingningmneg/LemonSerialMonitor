using System.IO.Pipes;
using System.Text.Json;
using CommMonitor.Core.Ai;
using CommMonitor.Core.Ipc;
using Lemon.SerialMonitor.AI.Transport;

namespace Lemon.SerialMonitor.AI.Tests.Transport;

public sealed class AiServiceClientTests
{
    private static readonly JsonFrameOptions FrameOptions =
        new(AiProtocol.MaximumResponseBytes, 64);

    [Fact]
    public async Task Status_request_uses_v1_and_accepts_only_the_correlated_response()
    {
        string pipeName = $"Lemon.AiClientTests.{Guid.NewGuid():N}";
        AiStatusDto expected = CreateStatus();
        Task server = RunSingleReplyServerAsync(pipeName, request =>
        {
            Assert.Equal(AiProtocol.Version, request.Version);
            Assert.Equal(AiCommandNames.Status, request.Command);
            Assert.Equal(JsonValueKind.Object, request.Arguments.ValueKind);
            return Success(request, expected);
        });
        await using var client = new AiServiceClient(pipeName, TimeSpan.FromSeconds(5));

        AiStatusDto actual = await client.GetStatusAsync();

        Assert.Equal(expected.ServiceState, actual.ServiceState);
        Assert.Equal(expected.DriverState, actual.DriverState);
        Assert.Equal(expected.CaptureState, actual.CaptureState);
        Assert.Equal(expected.Generation, actual.Generation);
        Assert.Equal(expected.Integrity, actual.Integrity);
        Assert.Equal(expected.Warnings, actual.Warnings);
        await server;
    }

    [Fact]
    public async Task Correlation_mismatch_is_a_structured_protocol_failure()
    {
        string pipeName = $"Lemon.AiClientTests.{Guid.NewGuid():N}";
        Task server = RunSingleReplyServerAsync(
            pipeName,
            request => Success(request, CreateStatus()) with { RequestId = "wrong" });
        await using var client = new AiServiceClient(pipeName, TimeSpan.FromSeconds(5));

        LemonAiException failure = await Assert.ThrowsAsync<LemonAiException>(
            () => client.GetStatusAsync());

        Assert.Equal(AiErrorCodes.ProtocolMismatch, failure.Code);
        await server;
    }

    [Fact]
    public async Task Service_error_preserves_code_retryability_correlation_and_details()
    {
        string pipeName = $"Lemon.AiClientTests.{Guid.NewGuid():N}";
        var expected = new AiError(
            AiErrorCodes.CaptureConflict,
            "Capture is busy.",
            true,
            "correlation-7",
            new Dictionary<string, string> { ["owner"] = "wpf" });
        Task server = RunSingleReplyServerAsync(
            pipeName,
            request => new AiResponseEnvelope(1, request.RequestId, false, null, expected));
        await using var client = new AiServiceClient(pipeName, TimeSpan.FromSeconds(5));

        LemonAiException failure = await Assert.ThrowsAsync<LemonAiException>(
            () => client.GetStatusAsync());

        Assert.Equal(expected.Code, failure.Code);
        Assert.Equal(expected.Message, failure.Message);
        Assert.Equal(expected.Retryable, failure.Retryable);
        Assert.Equal(expected.CorrelationId, failure.CorrelationId);
        Assert.Equal(expected.Details, failure.Error.Details);
        await server;
    }

    [Fact]
    public async Task Command_timeout_does_not_poison_the_next_connection()
    {
        string pipeName = $"Lemon.AiClientTests.{Guid.NewGuid():N}";
        Task stalled = RunStalledServerAsync(pipeName, TimeSpan.FromSeconds(1));
        await using var client = new AiServiceClient(pipeName, TimeSpan.FromMilliseconds(100));

        await Assert.ThrowsAsync<TimeoutException>(() => client.GetStatusAsync());
        await stalled;

        Task healthy = RunSingleReplyServerAsync(
            pipeName,
            request => Success(request, CreateStatus()));
        AiStatusDto status = await client.GetStatusAsync();

        Assert.Equal("available", status.ServiceState);
        await healthy;
    }

    [Fact]
    public async Task Wait_uses_a_dedicated_connection_and_honors_caller_cancellation()
    {
        string pipeName = $"Lemon.AiClientTests.{Guid.NewGuid():N}";
        Task server = RunStalledServerAsync(pipeName, TimeSpan.FromSeconds(1));
        await using var client = new AiServiceClient(pipeName, TimeSpan.FromSeconds(5));
        using var cancellation = new CancellationTokenSource(TimeSpan.FromMilliseconds(100));
        var request = new WaitEventsRequest(
            "session",
            null,
            null,
            "0",
            true,
            10,
            null,
            30);

        await Assert.ThrowsAnyAsync<OperationCanceledException>(
            () => client.WaitEventsAsync(request, cancellation.Token));
        await server;
    }

    private static async Task RunSingleReplyServerAsync(
        string pipeName,
        Func<AiRequestEnvelope, AiResponseEnvelope> reply)
    {
        await using var server = new NamedPipeServerStream(
            pipeName,
            PipeDirection.InOut,
            1,
            PipeTransmissionMode.Byte,
            PipeOptions.Asynchronous);
        await server.WaitForConnectionAsync().WaitAsync(TimeSpan.FromSeconds(5));
        AiRequestEnvelope request = await LengthPrefixedJsonCodec.ReadAsync<AiRequestEnvelope>(
            server,
            FrameOptions);
        await LengthPrefixedJsonCodec.WriteAsync(server, reply(request), FrameOptions);
    }

    private static async Task RunStalledServerAsync(string pipeName, TimeSpan lifetime)
    {
        await using var server = new NamedPipeServerStream(
            pipeName,
            PipeDirection.InOut,
            1,
            PipeTransmissionMode.Byte,
            PipeOptions.Asynchronous);
        await server.WaitForConnectionAsync().WaitAsync(TimeSpan.FromSeconds(5));
        await Task.Delay(lifetime);
    }

    private static AiResponseEnvelope Success<T>(AiRequestEnvelope request, T result) =>
        new(
            AiProtocol.Version,
            request.RequestId,
            true,
            JsonSerializer.SerializeToElement(result, AiJson.CreateOptions()),
            null);

    private static AiStatusDto CreateStatus() =>
        new(
            "available",
            "available",
            "stopped",
            "none",
            null,
            "0",
            new AiIntegrityDto(1, true, "0", "0", false, false, true, true, null, "0"),
            []);
}
