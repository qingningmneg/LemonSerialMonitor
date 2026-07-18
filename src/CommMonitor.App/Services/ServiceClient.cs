using System.Collections.Immutable;
using System.IO;
using System.IO.Pipes;
using System.Runtime.ExceptionServices;
using System.Text.Json;
using CommMonitor.Core.Ipc;
using CommMonitor.Core.Models;

namespace CommMonitor.App.Services;

public sealed record ServicePort(ulong DeviceId, string Name);

public sealed record ServiceStatus(
    IReadOnlyList<ServicePort> Ports,
    CaptureState State,
    string DriverState);

public interface IServiceClient : IAsyncDisposable
{
    event EventHandler<ImmutableArray<CaptureEvent>>? EventsReceived;
    event EventHandler<Exception>? ConnectionLost;

    bool IsConnected { get; }

    Task<ServiceStatus> GetStatusAsync(CancellationToken cancellationToken = default);

    Task StartAsync(
        IReadOnlyCollection<ulong> deviceIds,
        string sessionPath,
        CancellationToken cancellationToken = default);

    Task PauseAsync(CancellationToken cancellationToken = default);

    Task ResumeAsync(CancellationToken cancellationToken = default);

    Task StopAsync(CancellationToken cancellationToken = default);

    Task ClearAsync(CancellationToken cancellationToken = default);

    Task ExportAsync(
        string exportPath,
        string exportFormat,
        CancellationToken cancellationToken = default);
}

public sealed class ServiceClient : IServiceClient
{
    private static readonly TimeSpan DefaultOperationTimeout = TimeSpan.FromSeconds(5);

    private readonly string _pipeName;
    private readonly TimeSpan _operationTimeout;
    private readonly SemaphoreSlim _commandGate = new(1, 1);
    private readonly SemaphoreSlim _subscriptionGate = new(1, 1);
    private readonly CancellationTokenSource _lifetimeCancellation = new();
    private NamedPipeClientStream? _commandPipe;
    private NamedPipeClientStream? _subscriptionPipe;
    private CancellationTokenSource? _subscriptionCancellation;
    private Task? _subscriptionReader;
    private int _disposed;

    public ServiceClient()
        : this(PipeProtocol.PipeName, DefaultOperationTimeout)
    {
    }

    internal ServiceClient(string pipeName)
        : this(pipeName, DefaultOperationTimeout)
    {
    }

    internal ServiceClient(string pipeName, TimeSpan operationTimeout)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(pipeName);
        if (operationTimeout <= TimeSpan.Zero || operationTimeout == Timeout.InfiniteTimeSpan)
        {
            throw new ArgumentOutOfRangeException(nameof(operationTimeout));
        }

        _pipeName = pipeName;
        _operationTimeout = operationTimeout;
    }

    public event EventHandler<ImmutableArray<CaptureEvent>>? EventsReceived;
    public event EventHandler<Exception>? ConnectionLost;

    public bool IsConnected =>
        _commandPipe?.IsConnected == true && _subscriptionPipe?.IsConnected == true;

    public Task<ServiceStatus> GetStatusAsync(CancellationToken cancellationToken = default) =>
        ExecuteWithTimeoutAsync(GetStatusCoreAsync, cancellationToken);

    public Task StartAsync(
        IReadOnlyCollection<ulong> deviceIds,
        string sessionPath,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(deviceIds);
        if (deviceIds.Count == 0)
        {
            throw new ArgumentException("At least one device ID is required.", nameof(deviceIds));
        }

        ArgumentException.ThrowIfNullOrWhiteSpace(sessionPath);
        ulong[] selectedDeviceIds = deviceIds.ToArray();
        return ExecuteWithTimeoutAsync(
            token => StartCoreAsync(selectedDeviceIds, sessionPath, token),
            cancellationToken);
    }

    public Task PauseAsync(CancellationToken cancellationToken = default) =>
        ExecuteWithTimeoutAsync(
            token => SendCommandAsync(PipeCommandName.Pause, cancellationToken: token),
            cancellationToken);

    public Task ResumeAsync(CancellationToken cancellationToken = default) =>
        ExecuteWithTimeoutAsync(
            token => SendCommandAsync(PipeCommandName.Resume, cancellationToken: token),
            cancellationToken);

    public Task StopAsync(CancellationToken cancellationToken = default) =>
        ExecuteWithTimeoutAsync(
            token => SendCommandAsync(PipeCommandName.Stop, cancellationToken: token),
            cancellationToken);

    public Task ClearAsync(CancellationToken cancellationToken = default) =>
        ExecuteWithTimeoutAsync(ClearCoreAsync, cancellationToken);

    public Task ExportAsync(
        string exportPath,
        string exportFormat,
        CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(exportPath);
        ArgumentException.ThrowIfNullOrWhiteSpace(exportFormat);
        return ExecuteWithTimeoutAsync(
            token => SendCommandAsync(
                PipeCommandName.Export,
                exportPath: exportPath,
                exportFormat: exportFormat,
                cancellationToken: token),
            cancellationToken);
    }

    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref _disposed, 1) != 0)
        {
            return;
        }

        await _lifetimeCancellation.CancelAsync();

        await _commandGate.WaitAsync();
        try
        {
            ResetCommandConnection();
        }
        finally
        {
            _commandGate.Release();
        }
        await _subscriptionGate.WaitAsync();
        try
        {
            await StopSubscriptionUnderGateAsync();
        }
        finally
        {
            _subscriptionGate.Release();
        }

    }

    private async Task<ServiceStatus> GetStatusCoreAsync(CancellationToken cancellationToken)
    {
        PipeReply reply = await SendCommandAsync(
            PipeCommandName.ListPorts,
            cancellationToken: cancellationToken);
        ServiceStatus status = ParseStatus(reply);
        await EnsureSubscriptionAsync(cancellationToken);
        return status;
    }

    private async Task StartCoreAsync(
        IReadOnlyList<ulong> deviceIds,
        string sessionPath,
        CancellationToken cancellationToken)
    {
        await EnsureSubscriptionAsync(cancellationToken);
        await SendCommandAsync(
            PipeCommandName.Start,
            deviceIds,
            sessionPath: sessionPath,
            cancellationToken: cancellationToken);
    }

    private async Task ClearCoreAsync(CancellationToken cancellationToken)
    {
        await _subscriptionGate.WaitAsync(cancellationToken);
        try
        {
            await StopSubscriptionUnderGateAsync();

            ExceptionDispatchInfo? clearFailure = null;
            try
            {
                await SendCommandAsync(
                    PipeCommandName.Clear,
                    cancellationToken: cancellationToken);
            }
            catch (Exception exception)
            {
                clearFailure = ExceptionDispatchInfo.Capture(exception);
            }

            ExceptionDispatchInfo? recoveryFailure = null;
            if (Volatile.Read(ref _disposed) == 0 &&
                !_lifetimeCancellation.IsCancellationRequested)
            {
                using CancellationTokenSource recoveryCancellation =
                    CancellationTokenSource.CreateLinkedTokenSource(
                        _lifetimeCancellation.Token);
                recoveryCancellation.CancelAfter(_operationTimeout);
                try
                {
                    await EnsureSubscriptionUnderGateAsync(recoveryCancellation.Token);
                }
                catch (Exception exception)
                {
                    recoveryFailure = ExceptionDispatchInfo.Capture(exception);
                }
            }

            if (clearFailure is not null && recoveryFailure is not null)
            {
                Exception recoveryException = recoveryFailure.SourceException;
                RaiseSafely(ConnectionLost, recoveryException);
                throw new AggregateException(
                    "The Clear command and subscription recovery both failed.",
                    clearFailure.SourceException,
                    recoveryException);
            }

            clearFailure?.Throw();
            recoveryFailure?.Throw();
        }
        finally
        {
            _subscriptionGate.Release();
        }
    }

    private async Task<T> ExecuteWithTimeoutAsync<T>(
        Func<CancellationToken, Task<T>> operation,
        CancellationToken cancellationToken)
    {
        ThrowIfDisposed();
        using CancellationTokenSource operationCancellation =
            CancellationTokenSource.CreateLinkedTokenSource(
                cancellationToken,
                _lifetimeCancellation.Token);
        operationCancellation.CancelAfter(_operationTimeout);
        try
        {
            return await operation(operationCancellation.Token);
        }
        catch (OperationCanceledException exception) when (
            !cancellationToken.IsCancellationRequested &&
            !_lifetimeCancellation.IsCancellationRequested)
        {
            throw new TimeoutException(
                $"The service operation timed out after {_operationTimeout.TotalSeconds:g} seconds.",
                exception);
        }
    }

    private async Task ExecuteWithTimeoutAsync(
        Func<CancellationToken, Task> operation,
        CancellationToken cancellationToken)
    {
        ThrowIfDisposed();
        using CancellationTokenSource operationCancellation =
            CancellationTokenSource.CreateLinkedTokenSource(
                cancellationToken,
                _lifetimeCancellation.Token);
        operationCancellation.CancelAfter(_operationTimeout);
        try
        {
            await operation(operationCancellation.Token);
        }
        catch (OperationCanceledException exception) when (
            !cancellationToken.IsCancellationRequested &&
            !_lifetimeCancellation.IsCancellationRequested)
        {
            throw new TimeoutException(
                $"The service operation timed out after {_operationTimeout.TotalSeconds:g} seconds.",
                exception);
        }
    }

    private async Task<PipeReply> SendCommandAsync(
        PipeCommandName commandName,
        IReadOnlyList<ulong>? deviceIds = null,
        string? sessionPath = null,
        string? exportPath = null,
        string? exportFormat = null,
        CancellationToken cancellationToken = default)
    {
        ThrowIfDisposed();
        await _commandGate.WaitAsync(cancellationToken);
        try
        {
            NamedPipeClientStream pipe = await EnsureCommandConnectionAsync(cancellationToken);
            string requestId = Guid.NewGuid().ToString("N");
            var command = new PipeCommand(
                requestId,
                commandName,
                deviceIds,
                sessionPath,
                exportPath,
                exportFormat);
            PipeReply reply;
            try
            {
                await PipeFrameCodec.WriteAsync(pipe, command, cancellationToken);
                reply = await PipeFrameCodec.ReadAsync<PipeReply>(pipe, cancellationToken);
            }
            catch
            {
                ResetCommandConnection();
                throw;
            }

            ValidateReply(reply, requestId);
            return reply;
        }
        finally
        {
            _commandGate.Release();
        }
    }

    private async Task<NamedPipeClientStream> EnsureCommandConnectionAsync(
        CancellationToken cancellationToken)
    {
        if (_commandPipe?.IsConnected == true)
        {
            return _commandPipe;
        }

        ResetCommandConnection();
        NamedPipeClientStream pipe = CreatePipe();
        try
        {
            using CancellationTokenSource linkedCancellation =
                CancellationTokenSource.CreateLinkedTokenSource(
                    cancellationToken,
                    _lifetimeCancellation.Token);
            await pipe.ConnectAsync(linkedCancellation.Token);
            ThrowIfDisposed();
            _commandPipe = pipe;
            return pipe;
        }
        catch
        {
            await pipe.DisposeAsync();
            throw;
        }
    }

    private async Task EnsureSubscriptionAsync(CancellationToken cancellationToken)
    {
        ThrowIfDisposed();
        await _subscriptionGate.WaitAsync(cancellationToken);
        try
        {
            await EnsureSubscriptionUnderGateAsync(cancellationToken);
        }
        finally
        {
            _subscriptionGate.Release();
        }
    }

    private async Task EnsureSubscriptionUnderGateAsync(CancellationToken cancellationToken)
    {
        if (_subscriptionPipe?.IsConnected == true &&
            _subscriptionReader is { IsCompleted: false })
        {
            return;
        }

        await StopSubscriptionUnderGateAsync();
        ThrowIfDisposed();
        NamedPipeClientStream pipe = CreatePipe();
        try
        {
            using CancellationTokenSource linkedCancellation =
                CancellationTokenSource.CreateLinkedTokenSource(
                    cancellationToken,
                    _lifetimeCancellation.Token);
            await pipe.ConnectAsync(linkedCancellation.Token);
            string requestId = Guid.NewGuid().ToString("N");
            await PipeFrameCodec.WriteAsync(
                pipe,
                new PipeCommand(requestId, PipeCommandName.Subscribe),
                linkedCancellation.Token);
            PipeReply reply = await PipeFrameCodec.ReadAsync<PipeReply>(
                pipe,
                linkedCancellation.Token);
            ValidateReply(reply, requestId);
            ThrowIfDisposed();

            var subscriptionCancellation = CancellationTokenSource.CreateLinkedTokenSource(
                _lifetimeCancellation.Token);
            _subscriptionPipe = pipe;
            _subscriptionCancellation = subscriptionCancellation;
            _subscriptionReader = ReadSubscriptionAsync(
                pipe,
                subscriptionCancellation.Token);
        }
        catch
        {
            await pipe.DisposeAsync();
            throw;
        }
    }

    private async Task StopSubscriptionUnderGateAsync()
    {
        NamedPipeClientStream? pipe = _subscriptionPipe;
        CancellationTokenSource? subscriptionCancellation = _subscriptionCancellation;
        Task? reader = _subscriptionReader;
        _subscriptionPipe = null;
        _subscriptionCancellation = null;
        _subscriptionReader = null;

        if (subscriptionCancellation is not null)
        {
            await subscriptionCancellation.CancelAsync();
        }

        pipe?.Dispose();
        if (reader is not null)
        {
            try
            {
                await reader;
            }
            catch (Exception)
            {
                // Reader failures were already surfaced once through ConnectionLost.
            }
        }

        subscriptionCancellation?.Dispose();
    }

    private async Task ReadSubscriptionAsync(
        NamedPipeClientStream pipe,
        CancellationToken cancellationToken)
    {
        Exception? failure = null;
        try
        {
            while (!cancellationToken.IsCancellationRequested)
            {
                PipeEventBatch batch = await PipeFrameCodec.ReadAsync<PipeEventBatch>(
                    pipe,
                    cancellationToken);
                if (batch.Version != PipeProtocol.Version)
                {
                    throw new InvalidDataException(
                        $"Unsupported event protocol version {batch.Version}.");
                }

                RaiseSafely(EventsReceived, batch.Events);
            }
        }
        catch (Exception) when (cancellationToken.IsCancellationRequested)
        {
        }
        catch (Exception exception)
        {
            failure = exception;
        }
        finally
        {
            if (ReferenceEquals(_subscriptionPipe, pipe))
            {
                _subscriptionPipe = null;
            }

            try
            {
                await pipe.DisposeAsync();
            }
            catch (Exception exception) when (!cancellationToken.IsCancellationRequested)
            {
                failure ??= exception;
            }
            catch (Exception) when (cancellationToken.IsCancellationRequested)
            {
            }
        }

        if (failure is not null)
        {
            RaiseSafely(ConnectionLost, failure);
        }
    }

    private void RaiseSafely<T>(EventHandler<T>? observers, T argument)
    {
        if (observers is null)
        {
            return;
        }

        foreach (Delegate observer in observers.GetInvocationList())
        {
            try
            {
                ((EventHandler<T>)observer)(this, argument);
            }
            catch (Exception)
            {
                // A UI observer cannot terminate the transport reader or starve peers.
            }
        }
    }

    private NamedPipeClientStream CreatePipe() =>
        new(
            ".",
            _pipeName,
            PipeDirection.InOut,
            PipeOptions.Asynchronous);

    private void ResetCommandConnection()
    {
        NamedPipeClientStream? pipe = _commandPipe;
        _commandPipe = null;
        pipe?.Dispose();
    }

    private static void ValidateReply(PipeReply reply, string expectedRequestId)
    {
        if (reply.Version != PipeProtocol.Version)
        {
            throw new InvalidDataException(
                $"Unsupported reply protocol version {reply.Version}.");
        }

        if (!string.Equals(reply.RequestId, expectedRequestId, StringComparison.Ordinal))
        {
            throw new InvalidDataException("The service reply request ID did not match the command.");
        }

        if (!reply.Success)
        {
            throw new InvalidOperationException(reply.Error ?? "The service rejected the command.");
        }
    }

    private static ServiceStatus ParseStatus(PipeReply reply)
    {
        if (reply.Result is not { ValueKind: JsonValueKind.Object } result)
        {
            throw new InvalidDataException("The service status reply did not contain a result.");
        }

        if (!result.TryGetProperty("state", out JsonElement stateElement) ||
            stateElement.ValueKind != JsonValueKind.String ||
            !Enum.TryParse(
                stateElement.GetString(),
                ignoreCase: true,
                out CaptureState state))
        {
            throw new InvalidDataException("The service status reply contained an invalid state.");
        }

        string driverState = result.TryGetProperty("captureSource", out JsonElement sourceElement) &&
            sourceElement.ValueKind == JsonValueKind.String
                ? sourceElement.GetString() ?? string.Empty
                : string.Empty;

        var ports = new List<ServicePort>();
        if (result.TryGetProperty("ports", out JsonElement portsElement) &&
            portsElement.ValueKind == JsonValueKind.Array)
        {
            foreach (JsonElement portElement in portsElement.EnumerateArray())
            {
                ServicePort? port = ParsePort(portElement);
                if (port is not null)
                {
                    ports.Add(port);
                }
            }
        }

        return new ServiceStatus(ports, state, driverState);
    }

    private static ServicePort? ParsePort(JsonElement portElement)
    {
        if (portElement.ValueKind == JsonValueKind.String)
        {
            string? name = portElement.GetString();
            return string.IsNullOrWhiteSpace(name) ? null : new ServicePort(0, name);
        }

        if (portElement.ValueKind != JsonValueKind.Object ||
            !portElement.TryGetProperty("name", out JsonElement nameElement) ||
            nameElement.ValueKind != JsonValueKind.String ||
            string.IsNullOrWhiteSpace(nameElement.GetString()))
        {
            return null;
        }

        ulong deviceId = portElement.TryGetProperty("deviceId", out JsonElement idElement) &&
            idElement.TryGetUInt64(out ulong parsedDeviceId)
                ? parsedDeviceId
                : 0;
        return new ServicePort(deviceId, nameElement.GetString()!);
    }

    private void ThrowIfDisposed() =>
        ObjectDisposedException.ThrowIf(Volatile.Read(ref _disposed) != 0, this);
}
