using System.IO.Pipes;
using System.Security.Principal;
using System.Text.Json;
using CommMonitor.Core.Ai;
using CommMonitor.Core.Ipc;

namespace Lemon.SerialMonitor.AI.Transport;

public sealed class AiServiceClient : IAiServiceClient
{
    private static readonly TimeSpan DefaultCommandTimeout = TimeSpan.FromSeconds(5);
    private static readonly TimeSpan WaitTransportMargin = TimeSpan.FromSeconds(5);
    private static readonly JsonFrameOptions FrameOptions =
        new(AiProtocol.MaximumResponseBytes, MaximumDepth: 64);
    private static readonly JsonSerializerOptions JsonOptions = AiJson.CreateOptions();

    private readonly string _pipeName;
    private readonly TimeSpan _commandTimeout;
    private readonly SemaphoreSlim _commandGate = new(1, 1);
    private readonly CancellationTokenSource _lifetime = new();
    private NamedPipeClientStream? _commandPipe;
    private int _disposed;

    public AiServiceClient()
        : this(AiProtocol.PipeName, DefaultCommandTimeout)
    {
    }

    internal AiServiceClient(string pipeName, TimeSpan commandTimeout)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(pipeName);
        if (commandTimeout <= TimeSpan.Zero || commandTimeout == Timeout.InfiniteTimeSpan)
        {
            throw new ArgumentOutOfRangeException(nameof(commandTimeout));
        }

        _pipeName = pipeName;
        _commandTimeout = commandTimeout;
    }

    public Task<AiStatusDto> GetStatusAsync(CancellationToken cancellationToken = default) =>
        SendCommandAsync<AiStatusDto>(
            AiCommandNames.Status,
            EmptyArguments.Instance,
            cancellationToken);

    public Task<IReadOnlyList<AiPortDto>> ListPortsAsync(
        CancellationToken cancellationToken = default) =>
        SendCommandAsync<IReadOnlyList<AiPortDto>>(
            AiCommandNames.Ports,
            EmptyArguments.Instance,
            cancellationToken);

    public Task<PreparedCaptureDto> PrepareStartAsync(
        PrepareCaptureRequest request,
        CancellationToken cancellationToken = default) =>
        SendCommandAsync<PreparedCaptureDto>(
            AiCommandNames.PrepareStart,
            request,
            cancellationToken);

    public Task<ActiveCaptureDto> CommitStartAsync(
        CommitCaptureRequest request,
        CancellationToken cancellationToken = default) =>
        SendCommandAsync<ActiveCaptureDto>(
            AiCommandNames.CommitStart,
            request,
            cancellationToken);

    public Task<ActiveCaptureDto> RecoverLeaseAsync(
        RecoverLeaseRequest request,
        CancellationToken cancellationToken = default) =>
        SendCommandAsync<ActiveCaptureDto>(
            AiCommandNames.RecoverLease,
            request,
            cancellationToken);

    public Task<AiStatusDto> PauseAsync(
        LeaseProof request,
        CancellationToken cancellationToken = default) =>
        SendCommandAsync<AiStatusDto>(AiCommandNames.Pause, request, cancellationToken);

    public Task<AiStatusDto> ResumeAsync(
        LeaseProof request,
        CancellationToken cancellationToken = default) =>
        SendCommandAsync<AiStatusDto>(AiCommandNames.Resume, request, cancellationToken);

    public Task<AiStatusDto> StopAsync(
        LeaseProof request,
        CancellationToken cancellationToken = default) =>
        SendCommandAsync<AiStatusDto>(AiCommandNames.Stop, request, cancellationToken);

    public Task<AiSessionPage> ListSessionsAsync(
        ListSessionsRequest request,
        CancellationToken cancellationToken = default) =>
        SendCommandAsync<AiSessionPage>(AiCommandNames.Sessions, request, cancellationToken);

    public Task<AiEventPage> ReadEventsAsync(
        ReadEventsRequest request,
        CancellationToken cancellationToken = default) =>
        SendCommandAsync<AiEventPage>(AiCommandNames.Read, request, cancellationToken);

    public Task<AiEventPage> WaitEventsAsync(
        WaitEventsRequest request,
        CancellationToken cancellationToken = default)
    {
        TimeSpan timeout = TimeSpan.FromSeconds(Math.Clamp(
            request.TimeoutSeconds,
            0,
            (int)AiProtocol.MaximumWait.TotalSeconds)) + WaitTransportMargin;
        return SendOnDedicatedConnectionAsync<AiEventPage>(
            AiCommandNames.Wait,
            request,
            timeout,
            cancellationToken);
    }

    public Task<AiExportDto> ExportAsync(
        ExportSessionRequest request,
        CancellationToken cancellationToken = default) =>
        SendCommandAsync<AiExportDto>(AiCommandNames.Export, request, cancellationToken);

    public Task<AiSchemaDto> GetSchemaAsync(CancellationToken cancellationToken = default) =>
        SendCommandAsync<AiSchemaDto>(
            AiCommandNames.Schema,
            EmptyArguments.Instance,
            cancellationToken);

    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref _disposed, 1) != 0)
        {
            return;
        }

        await _lifetime.CancelAsync().ConfigureAwait(false);
        _commandPipe?.Dispose();
        await _commandGate.WaitAsync().ConfigureAwait(false);
        _commandGate.Release();
        _commandGate.Dispose();
        _lifetime.Dispose();
    }

    private async Task<TResult> SendCommandAsync<TResult>(
        string command,
        object arguments,
        CancellationToken cancellationToken)
    {
        ThrowIfDisposed();
        await _commandGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            using CancellationTokenSource operation = CreateTimeout(
                _commandTimeout,
                cancellationToken);
            NamedPipeClientStream pipe = await EnsureCommandPipeAsync(operation.Token)
                .ConfigureAwait(false);
            try
            {
                return await ExchangeAsync<TResult>(
                    pipe,
                    command,
                    arguments,
                    operation.Token).ConfigureAwait(false);
            }
            catch
            {
                ResetCommandPipe();
                throw;
            }
        }
        catch (OperationCanceledException exception) when (
            !cancellationToken.IsCancellationRequested &&
            !_lifetime.IsCancellationRequested)
        {
            throw new TimeoutException(
                $"The AI service command timed out after {_commandTimeout.TotalSeconds:g} seconds.",
                exception);
        }
        finally
        {
            _commandGate.Release();
        }
    }

    private async Task<TResult> SendOnDedicatedConnectionAsync<TResult>(
        string command,
        object arguments,
        TimeSpan timeout,
        CancellationToken cancellationToken)
    {
        ThrowIfDisposed();
        using CancellationTokenSource operation = CreateTimeout(timeout, cancellationToken);
        await using NamedPipeClientStream pipe = CreatePipe();
        try
        {
            await pipe.ConnectAsync(operation.Token).ConfigureAwait(false);
            return await ExchangeAsync<TResult>(
                pipe,
                command,
                arguments,
                operation.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException exception) when (
            !cancellationToken.IsCancellationRequested &&
            !_lifetime.IsCancellationRequested)
        {
            throw new TimeoutException(
                $"The AI wait transport timed out after {timeout.TotalSeconds:g} seconds.",
                exception);
        }
    }

    private async Task<TResult> ExchangeAsync<TResult>(
        NamedPipeClientStream pipe,
        string command,
        object arguments,
        CancellationToken cancellationToken)
    {
        string requestId = Guid.NewGuid().ToString("N");
        JsonElement argumentElement = JsonSerializer.SerializeToElement(
            arguments,
            arguments.GetType(),
            JsonOptions);
        var request = new AiRequestEnvelope(
            AiProtocol.Version,
            requestId,
            command,
            argumentElement);
        await LengthPrefixedJsonCodec.WriteAsync(
            pipe,
            request,
            FrameOptions,
            cancellationToken).ConfigureAwait(false);
        AiResponseEnvelope response = await LengthPrefixedJsonCodec.ReadAsync<AiResponseEnvelope>(
            pipe,
            FrameOptions,
            cancellationToken).ConfigureAwait(false);

        if (response.Version != AiProtocol.Version)
        {
            throw ProtocolFailure("The AI service returned an incompatible protocol version.");
        }

        if (!string.Equals(response.RequestId, requestId, StringComparison.Ordinal))
        {
            throw ProtocolFailure("The AI service response did not match the request.");
        }

        if (!response.Success)
        {
            throw new LemonAiException(response.Error ?? new AiError(
                AiErrorCodes.ServiceUnavailable,
                "The AI service returned an error without details.",
                true,
                Guid.NewGuid().ToString("N")));
        }

        if (response.Result is null)
        {
            throw ProtocolFailure("The successful AI service response did not contain a result.");
        }

        try
        {
            return response.Result.Value.Deserialize<TResult>(JsonOptions) ??
                throw ProtocolFailure("The AI service returned a null result.");
        }
        catch (JsonException exception)
        {
            throw new LemonAiException(new AiError(
                AiErrorCodes.ProtocolMismatch,
                "The AI service result did not match the expected contract.",
                false,
                Guid.NewGuid().ToString("N"),
                new Dictionary<string, string> { ["json"] = exception.Message }));
        }
    }

    private async Task<NamedPipeClientStream> EnsureCommandPipeAsync(
        CancellationToken cancellationToken)
    {
        if (_commandPipe?.IsConnected == true)
        {
            return _commandPipe;
        }

        ResetCommandPipe();
        NamedPipeClientStream pipe = CreatePipe();
        try
        {
            await pipe.ConnectAsync(cancellationToken).ConfigureAwait(false);
            ThrowIfDisposed();
            _commandPipe = pipe;
            return pipe;
        }
        catch
        {
            await pipe.DisposeAsync().ConfigureAwait(false);
            throw;
        }
    }

    private NamedPipeClientStream CreatePipe() =>
        new(
            ".",
            _pipeName,
            PipeDirection.InOut,
            PipeOptions.Asynchronous,
            TokenImpersonationLevel.Identification);

    private CancellationTokenSource CreateTimeout(
        TimeSpan timeout,
        CancellationToken cancellationToken)
    {
        var source = CancellationTokenSource.CreateLinkedTokenSource(
            cancellationToken,
            _lifetime.Token);
        source.CancelAfter(timeout);
        return source;
    }

    private void ResetCommandPipe()
    {
        NamedPipeClientStream? pipe = Interlocked.Exchange(ref _commandPipe, null);
        pipe?.Dispose();
    }

    private void ThrowIfDisposed() =>
        ObjectDisposedException.ThrowIf(Volatile.Read(ref _disposed) != 0, this);

    private static LemonAiException ProtocolFailure(string message) =>
        new(new AiError(
            AiErrorCodes.ProtocolMismatch,
            message,
            false,
            Guid.NewGuid().ToString("N")));

    private sealed class EmptyArguments
    {
        public static EmptyArguments Instance { get; } = new();

        private EmptyArguments()
        {
        }
    }
}
