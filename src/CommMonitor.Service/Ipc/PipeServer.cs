using System.Collections.Concurrent;
using System.Collections.Immutable;
using System.IO.Pipes;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text.Json;
using System.Threading.Channels;
using CommMonitor.Core.Ipc;
using CommMonitor.Core.Models;
using CommMonitor.Service.Capture;
using CommMonitor.Service.Ports;

namespace CommMonitor.Service.Ipc;

public sealed class PipeServer : BackgroundService
{
    public const int MaximumServerInstances = 4;
    internal const int OutboundQueueCapacity = 64;

    private readonly CaptureCoordinator _coordinator;
    private readonly IWpfCaptureController _wpfCaptureController;
    private readonly IPortCatalog _portCatalog;
    private readonly ICaptureSourceStatusProvider _captureSourceStatus;
    private readonly ILogger<PipeServer> _logger;
    private readonly string _pipeName;
    private readonly string _sessionRoot;
    private readonly string _exportRoot;
    private readonly ServiceStorageBoundary _storageBoundary;
    private readonly ConcurrentDictionary<long, ClientSession> _sessions = new();
    private long _nextSessionId;

    internal PipeServer(
        CaptureCoordinator coordinator,
        IWpfCaptureController wpfCaptureController,
        IPortCatalog portCatalog,
        ICaptureSourceStatusProvider captureSourceStatus,
        ILogger<PipeServer> logger)
        : this(
            coordinator,
            wpfCaptureController,
            portCatalog,
            captureSourceStatus,
            logger,
            PipeProtocol.PipeName,
            DefaultStorageDirectory,
            DefaultSessionDirectory,
            DefaultExportDirectory)
    {
    }

    internal PipeServer(
        CaptureCoordinator coordinator,
        IWpfCaptureController wpfCaptureController,
        IPortCatalog portCatalog,
        ICaptureSourceStatusProvider captureSourceStatus,
        ILogger<PipeServer> logger,
        string pipeName,
        string sessionRoot)
        : this(
            coordinator,
            wpfCaptureController,
            portCatalog,
            captureSourceStatus,
            logger,
            pipeName,
            sessionRoot,
            sessionRoot,
            Path.Combine(sessionRoot, "Exports"))
    {
    }

    internal PipeServer(
        CaptureCoordinator coordinator,
        IWpfCaptureController wpfCaptureController,
        IPortCatalog portCatalog,
        ICaptureSourceStatusProvider captureSourceStatus,
        ILogger<PipeServer> logger,
        string pipeName,
        string sessionRoot,
        string exportRoot)
        : this(
            coordinator,
            wpfCaptureController,
            portCatalog,
            captureSourceStatus,
            logger,
            pipeName,
            FindCommonStorageRoot(sessionRoot, exportRoot),
            sessionRoot,
            exportRoot)
    {
    }

    private PipeServer(
        CaptureCoordinator coordinator,
        IWpfCaptureController wpfCaptureController,
        IPortCatalog portCatalog,
        ICaptureSourceStatusProvider captureSourceStatus,
        ILogger<PipeServer> logger,
        string pipeName,
        string managedRoot,
        string sessionRoot,
        string exportRoot)
    {
        _coordinator = coordinator ?? throw new ArgumentNullException(nameof(coordinator));
        _wpfCaptureController = wpfCaptureController ??
            throw new ArgumentNullException(nameof(wpfCaptureController));
        _portCatalog = portCatalog ?? throw new ArgumentNullException(nameof(portCatalog));
        _captureSourceStatus = captureSourceStatus ??
            throw new ArgumentNullException(nameof(captureSourceStatus));
        _logger = logger ?? throw new ArgumentNullException(nameof(logger));
        ArgumentException.ThrowIfNullOrWhiteSpace(pipeName);
        ArgumentException.ThrowIfNullOrWhiteSpace(sessionRoot);
        ArgumentException.ThrowIfNullOrWhiteSpace(exportRoot);
        _pipeName = pipeName;
        _sessionRoot = Path.GetFullPath(sessionRoot);
        _exportRoot = Path.GetFullPath(exportRoot);
        _storageBoundary = ServiceStorageBoundary.Open(
            managedRoot,
            _sessionRoot,
            _exportRoot);
    }

    internal static string DefaultStorageDirectory => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
        "CommMonitor");

    internal static string DefaultSessionDirectory => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
        "CommMonitor",
        "Sessions");

    internal static string DefaultExportDirectory => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
        "CommMonitor",
        "Exports");

    public override void Dispose()
    {
        base.Dispose();
        _storageBoundary.Dispose();
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        _coordinator.EventsPublished += CoordinatorOnEventsPublished;
        _logger.LogInformation(
            "Named-pipe server {PipeName} is listening with {InstanceCount} instances.",
            _pipeName,
            MaximumServerInstances);

        try
        {
            Task[] listeners = Enumerable
                .Range(0, MaximumServerInstances)
                .Select(_ => ListenAsync(stoppingToken))
                .ToArray();
            await Task.WhenAll(listeners).ConfigureAwait(false);
        }
        finally
        {
            _coordinator.EventsPublished -= CoordinatorOnEventsPublished;
            foreach (ClientSession session in _sessions.Values)
            {
                session.Disconnect();
            }
        }
    }

    internal static PipeSecurity CreatePipeSecurity()
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException("Named-pipe ACLs require Windows.");
        }

        var security = new PipeSecurity();
        security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        AddDenyRule(
            security,
            WellKnownSidType.NetworkSid,
            PipeAccessRights.ReadWrite | PipeAccessRights.CreateNewInstance);
        AddAllowRule(security, WellKnownSidType.LocalSystemSid, PipeAccessRights.FullControl);
        AddAllowRule(
            security,
            WellKnownSidType.BuiltinAdministratorsSid,
            PipeAccessRights.FullControl);
        AddAllowRule(security, WellKnownSidType.BuiltinUsersSid, PipeAccessRights.ReadWrite);
        AddServerIdentityRule(security);
        return security;
    }

    internal static NamedPipeServerStream CreateServerStream(string pipeName)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(pipeName);
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException(
                "The Lemon serial monitor named-pipe server requires Windows.");
        }

        return NamedPipeServerStreamAcl.Create(
            pipeName,
            PipeDirection.InOut,
            MaximumServerInstances,
            PipeTransmissionMode.Byte,
            PipeOptions.Asynchronous,
            inBufferSize: 0,
            outBufferSize: 0,
            CreatePipeSecurity());
    }

    internal static string ResolveSessionPath(string sessionName, string sessionRoot)
        => ResolveContainedFilePath(
            sessionName,
            sessionRoot,
            "SessionPath",
            nameof(sessionName));

    internal static string ResolveExportPath(string exportName, string exportRoot)
        => ResolveContainedFilePath(
            exportName,
            exportRoot,
            "ExportPath",
            nameof(exportName));

    private static string ResolveContainedFilePath(
        string fileName,
        string root,
        string fieldName,
        string parameterName)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(fileName);
        ArgumentException.ThrowIfNullOrWhiteSpace(root);

        if (Path.IsPathRooted(fileName) ||
            !string.Equals(fileName, Path.GetFileName(fileName), StringComparison.Ordinal) ||
            fileName.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0 ||
            fileName is "." or ".." ||
            fileName.EndsWith(' ') ||
            fileName.EndsWith('.') ||
            IsReservedWindowsDeviceName(fileName))
        {
            throw new ArgumentException(
                $"{fieldName} must be a safe file name without directories or traversal.",
                parameterName);
        }

        string canonicalRoot = Path.GetFullPath(root);
        string rootPrefix = Path.EndsInDirectorySeparator(canonicalRoot)
            ? canonicalRoot
            : canonicalRoot + Path.DirectorySeparatorChar;
        string canonicalPath = Path.GetFullPath(Path.Combine(canonicalRoot, fileName));
        if (!canonicalPath.StartsWith(rootPrefix, StringComparison.OrdinalIgnoreCase))
        {
            throw new ArgumentException(
                $"{fieldName} must remain inside its service-managed directory.",
                parameterName);
        }

        return canonicalPath;
    }

    private static bool IsReservedWindowsDeviceName(string sessionName)
    {
        int extensionSeparator = sessionName.IndexOf('.');
        string baseName = (extensionSeparator >= 0
            ? sessionName[..extensionSeparator]
            : sessionName).TrimEnd(' ', '.');
        if (baseName.Equals("CON", StringComparison.OrdinalIgnoreCase) ||
            baseName.Equals("PRN", StringComparison.OrdinalIgnoreCase) ||
            baseName.Equals("AUX", StringComparison.OrdinalIgnoreCase) ||
            baseName.Equals("NUL", StringComparison.OrdinalIgnoreCase) ||
            baseName.Equals("CLOCK$", StringComparison.OrdinalIgnoreCase))
        {
            return true;
        }

        return baseName.Length == 4 &&
            (baseName.StartsWith("COM", StringComparison.OrdinalIgnoreCase) ||
             baseName.StartsWith("LPT", StringComparison.OrdinalIgnoreCase)) &&
            (baseName[3] is >= '1' and <= '9' or '¹' or '²' or '³');
    }

    private static string FindCommonStorageRoot(string firstPath, string secondPath)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(firstPath);
        ArgumentException.ThrowIfNullOrWhiteSpace(secondPath);
        string first = Path.TrimEndingDirectorySeparator(Path.GetFullPath(firstPath));
        string second = Path.TrimEndingDirectorySeparator(Path.GetFullPath(secondPath));
        string? common = first;

        while (common is not null)
        {
            string commonPrefix = common + Path.DirectorySeparatorChar;
            if (string.Equals(second, common, StringComparison.OrdinalIgnoreCase) ||
                second.StartsWith(commonPrefix, StringComparison.OrdinalIgnoreCase))
            {
                string filesystemRoot = Path.GetPathRoot(common) ?? string.Empty;
                if (!string.Equals(common, filesystemRoot, StringComparison.OrdinalIgnoreCase))
                {
                    return common;
                }

                break;
            }

            common = Directory.GetParent(common)?.FullName;
        }

        throw new ArgumentException(
            "Session and export directories must share a non-root managed storage directory.");
    }

    private async Task ListenAsync(CancellationToken stoppingToken)
    {
        while (!stoppingToken.IsCancellationRequested)
        {
            await using NamedPipeServerStream pipe = CreateServerStream(_pipeName);
            try
            {
                await pipe.WaitForConnectionAsync(stoppingToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                break;
            }

            await HandleClientAsync(pipe, stoppingToken).ConfigureAwait(false);
        }
    }

    private async Task HandleClientAsync(
        NamedPipeServerStream pipe,
        CancellationToken stoppingToken)
    {
        long sessionId = Interlocked.Increment(ref _nextSessionId);
        var session = new ClientSession(sessionId, pipe, stoppingToken);
        if (!_sessions.TryAdd(sessionId, session))
        {
            throw new InvalidOperationException("The client session identifier was already in use.");
        }

        Task reader = ReadClientAsync(session, stoppingToken);
        Task writer = WriteClientAsync(session);

        try
        {
            await Task.WhenAny(reader, writer).ConfigureAwait(false);
            session.Disconnect();
            await ObserveClientCompletionAsync(reader, sessionId, stoppingToken).ConfigureAwait(false);
            await ObserveClientCompletionAsync(writer, sessionId, stoppingToken).ConfigureAwait(false);
        }
        finally
        {
            _sessions.TryRemove(sessionId, out _);
            session.Disconnect();
            session.Dispose();
        }
    }

    private async Task ReadClientAsync(ClientSession session, CancellationToken stoppingToken)
    {
        CancellationToken transportToken = session.TransportToken;
        while (!transportToken.IsCancellationRequested)
        {
            PipeCommand command = await PipeFrameCodec
                .ReadAsync<PipeCommand>(session.Pipe, transportToken)
                .ConfigureAwait(false);
            PipeReply reply = await ExecuteCommandAsync(command, stoppingToken)
                .ConfigureAwait(false);

            if (reply.Success && command.Command == PipeCommandName.Subscribe)
            {
                await session.EnqueueSubscriptionReplyAsync(reply, transportToken)
                    .ConfigureAwait(false);
            }
            else
            {
                await session.EnqueueAsync(reply, transportToken).ConfigureAwait(false);
            }
        }
    }

    private static async Task WriteClientAsync(ClientSession session)
    {
        CancellationToken transportToken = session.TransportToken;
        await foreach (object message in session.ReadAllAsync(transportToken).ConfigureAwait(false))
        {
            switch (message)
            {
                case PipeReply reply:
                    await PipeFrameCodec.WriteAsync(session.Pipe, reply, transportToken)
                        .ConfigureAwait(false);
                    break;
                case PipeEventBatch eventBatch:
                    await PipeFrameCodec.WriteAsync(session.Pipe, eventBatch, transportToken)
                        .ConfigureAwait(false);
                    break;
                default:
                    throw new InvalidOperationException(
                        $"Unsupported outbound pipe message type {message.GetType().FullName}.");
            }
        }
    }

    private async Task<PipeReply> ExecuteCommandAsync(
        PipeCommand command,
        CancellationToken cancellationToken)
    {
        if (command.Version != PipeProtocol.Version)
        {
            return Failure(
                command,
                $"Unsupported protocol version {command.Version}; expected {PipeProtocol.Version}.");
        }

        try
        {
            switch (command.Command)
            {
                case PipeCommandName.ListPorts:
                    IReadOnlyList<PortInfo> availablePorts;
                    string? portCatalogError = null;
                    try
                    {
                        availablePorts = await _portCatalog
                            .GetPortsAsync(cancellationToken)
                            .ConfigureAwait(false);
                    }
                    catch (OperationCanceledException) when (
                        cancellationToken.IsCancellationRequested)
                    {
                        throw;
                    }
                    catch (Exception exception)
                    {
                        availablePorts = [];
                        portCatalogError = exception.Message;
                        _logger.LogWarning(
                            exception,
                            "Serial-port discovery failed while serving ListPorts.");
                    }

                    CaptureSourceStatus captureSourceStatus = await _captureSourceStatus
                        .GetStatusAsync(cancellationToken)
                        .ConfigureAwait(false);
                    return Success(
                        command,
                        JsonSerializer.SerializeToElement(new
                        {
                            ports = availablePorts.Select(port => new
                            {
                                deviceId = port.DeviceIdHash,
                                name = port.Name,
                                friendlyName = port.FriendlyName,
                            }),
                            state = _coordinator.State.ToString(),
                            captureSource = captureSourceStatus.Message,
                            captureSourceKind = captureSourceStatus.Kind.ToString(),
                            portCatalogError,
                        }));

                case PipeCommandName.Start:
                    if (command.DeviceIds.Count == 0)
                    {
                        throw new ArgumentException(
                            "Start requires at least one device ID.",
                            nameof(command));
                    }

                    string sessionPath = ResolveSessionPath(command.SessionPath!, _sessionRoot);
                    _storageBoundary.VerifySessionPath(sessionPath);
                    await _wpfCaptureController.StartWpfAsync(
                        new CaptureSelection(command.DeviceIds.ToHashSet(), sessionPath),
                        cancellationToken).ConfigureAwait(false);
                    return Success(command, StateResult());

                case PipeCommandName.Pause:
                    await _wpfCaptureController.PauseWpfAsync(cancellationToken)
                        .ConfigureAwait(false);
                    return Success(command, StateResult());

                case PipeCommandName.Resume:
                    await _wpfCaptureController.ResumeWpfAsync(cancellationToken)
                        .ConfigureAwait(false);
                    return Success(command, StateResult());

                case PipeCommandName.Stop:
                    await _wpfCaptureController.StopWpfAsync(cancellationToken)
                        .ConfigureAwait(false);
                    return Success(command, StateResult());

                case PipeCommandName.Clear:
                    await _coordinator.ClearAsync(cancellationToken).ConfigureAwait(false);
                    return Success(command, StateResult());

                case PipeCommandName.Subscribe:
                    return Success(command, StateResult());

                case PipeCommandName.Export:
                    string normalizedFormat = command.ExportFormat?.Trim().ToLowerInvariant() ??
                        throw new ArgumentException("ExportFormat is required.", nameof(command));
                    string expectedExtension = normalizedFormat switch
                    {
                        "csv" => ".csv",
                        "txt" => ".txt",
                        "raw" => ".raw",
                        _ => throw new ArgumentException(
                            "ExportFormat must be csv, txt, or raw.",
                            nameof(command)),
                    };
                    string exportPath = ResolveExportPath(command.ExportPath!, _exportRoot);
                    if (!string.Equals(
                            Path.GetExtension(exportPath),
                            expectedExtension,
                            StringComparison.OrdinalIgnoreCase))
                    {
                        throw new ArgumentException(
                            $"The {normalizedFormat} export file must use " +
                            $"the {expectedExtension} extension.",
                            nameof(command));
                    }

                    _storageBoundary.VerifyExportPath(exportPath);
                    string temporaryPath = Path.Combine(
                        _exportRoot,
                        $".{Path.GetFileName(exportPath)}.{Guid.NewGuid():N}.tmp");
                    try
                    {
                        await using (var destination = new FileStream(
                            temporaryPath,
                            new FileStreamOptions
                            {
                                Mode = FileMode.CreateNew,
                                Access = FileAccess.Write,
                                Share = FileShare.None,
                                Options = FileOptions.Asynchronous,
                            }))
                        {
                            await _coordinator.ExportAsync(
                                destination,
                                normalizedFormat,
                                cancellationToken).ConfigureAwait(false);
                            await destination.FlushAsync(cancellationToken).ConfigureAwait(false);
                        }

                        _storageBoundary.VerifyExportPath(exportPath);
                        File.Move(temporaryPath, exportPath, overwrite: true);
                        _storageBoundary.VerifyExportPath(exportPath);
                    }
                    finally
                    {
                        if (File.Exists(temporaryPath))
                        {
                            File.Delete(temporaryPath);
                        }
                    }

                    return Success(
                        command,
                        JsonSerializer.SerializeToElement(new
                        {
                            path = exportPath,
                            format = normalizedFormat,
                        }));

                default:
                    return Failure(command, $"Unsupported command {command.Command}.");
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception exception) when (
            exception is ArgumentException or InvalidOperationException or IOException)
        {
            return Failure(command, exception.Message);
        }
        catch (Exception exception)
        {
            _logger.LogWarning(
                exception,
                "Command {CommandName} failed for request {RequestId}.",
                command.Command,
                command.RequestId);
            return Failure(command, exception.Message);
        }
    }

    private JsonElement StateResult() =>
        JsonSerializer.SerializeToElement(new { state = _coordinator.State.ToString() });

    private static PipeReply Success(PipeCommand command, JsonElement? result = null) =>
        new(command.RequestId, success: true, result: result);

    private static PipeReply Failure(PipeCommand command, string error) =>
        new(command.RequestId, success: false, error: error);

    private void CoordinatorOnEventsPublished(
        object? sender,
        ImmutableArray<CaptureEvent> events)
    {
        var eventBatch = new PipeEventBatch(events);
        foreach (ClientSession session in _sessions.Values)
        {
            if (session.TryEnqueueEvent(eventBatch) == PipeEventEnqueueResult.Overflowed &&
                session.Disconnect(new IOException("The client outbound event queue overflowed.")))
            {
                _logger.LogWarning(
                    "Disconnecting named-pipe client {SessionId} because its outbound event " +
                    "queue overflowed at {Capacity} messages.",
                    session.Id,
                    OutboundQueueCapacity);
            }
        }
    }

    private async Task ObserveClientCompletionAsync(
        Task task,
        long sessionId,
        CancellationToken stoppingToken)
    {
        try
        {
            await task.ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
        {
        }
        catch (OperationCanceledException)
        {
        }
        catch (EndOfStreamException)
        {
            _logger.LogDebug("Named-pipe client {SessionId} disconnected.", sessionId);
        }
        catch (IOException exception)
        {
            _logger.LogDebug(
                exception,
                "Named-pipe client {SessionId} disconnected during I/O.",
                sessionId);
        }
        catch (InvalidDataException exception)
        {
            _logger.LogWarning(
                exception,
                "Named-pipe client {SessionId} sent an invalid frame.",
                sessionId);
        }
        catch (ChannelClosedException)
        {
        }
        catch (Exception exception)
        {
            _logger.LogError(
                exception,
                "Named-pipe client {SessionId} failed unexpectedly.",
                sessionId);
        }
    }

    private static void AddAllowRule(
        PipeSecurity security,
        WellKnownSidType sidType,
        PipeAccessRights rights)
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException("Named-pipe ACLs require Windows.");
        }

        var sid = new SecurityIdentifier(sidType, domainSid: null);
        security.AddAccessRule(new PipeAccessRule(sid, rights, AccessControlType.Allow));
    }

    private static void AddDenyRule(
        PipeSecurity security,
        WellKnownSidType sidType,
        PipeAccessRights rights)
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException("Named-pipe ACLs require Windows.");
        }

        var sid = new SecurityIdentifier(sidType, domainSid: null);
        security.AddAccessRule(new PipeAccessRule(sid, rights, AccessControlType.Deny));
    }

    private static void AddServerIdentityRule(PipeSecurity security)
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException("Named-pipe ACLs require Windows.");
        }

        using WindowsIdentity identity = WindowsIdentity.GetCurrent();
        SecurityIdentifier? sid = identity.User;
        var localSystemSid = new SecurityIdentifier(WellKnownSidType.LocalSystemSid, domainSid: null);
        if (sid is not null && !sid.Equals(localSystemSid))
        {
            security.AddAccessRule(new PipeAccessRule(
                sid,
                PipeAccessRights.CreateNewInstance,
                AccessControlType.Allow));
        }
    }

    private sealed class ClientSession : IDisposable
    {
        private readonly PipeClientOutputQueue _outbound =
            new(OutboundQueueCapacity);
        private readonly CancellationTokenSource _transportCancellation;
        private int _disconnecting;

        public ClientSession(
            long id,
            NamedPipeServerStream pipe,
            CancellationToken stoppingToken)
        {
            Id = id;
            Pipe = pipe;
            _transportCancellation =
                CancellationTokenSource.CreateLinkedTokenSource(stoppingToken);
        }

        public long Id { get; }
        public NamedPipeServerStream Pipe { get; }
        public CancellationToken TransportToken => _transportCancellation.Token;

        public ValueTask EnqueueAsync(object message, CancellationToken cancellationToken) =>
            _outbound.EnqueueAsync(message, cancellationToken);

        public ValueTask EnqueueSubscriptionReplyAsync(
            object message,
            CancellationToken cancellationToken) =>
            _outbound.EnqueueSubscriptionReplyAsync(message, cancellationToken);

        public PipeEventEnqueueResult TryEnqueueEvent(object message) =>
            _outbound.TryEnqueueEvent(message);

        public IAsyncEnumerable<object> ReadAllAsync(CancellationToken cancellationToken) =>
            _outbound.ReadAllAsync(cancellationToken);

        public bool Disconnect(Exception? exception = null)
        {
            if (Interlocked.CompareExchange(ref _disconnecting, 1, 0) != 0)
            {
                return false;
            }

            _outbound.Complete(exception);
            _transportCancellation.Cancel();
            return true;
        }

        public void Dispose() => _transportCancellation.Dispose();
    }
}

internal enum PipeEventEnqueueResult
{
    NotSubscribed,
    Enqueued,
    Overflowed,
    Closed,
}

internal sealed class PipeClientOutputQueue
{
    private readonly object _subscriptionGate = new();
    private readonly Channel<object> _outbound;
    private bool _completed;
    private bool _subscribed;

    public PipeClientOutputQueue(int capacity)
    {
        if (capacity <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(capacity));
        }

        _outbound = Channel.CreateBounded<object>(new BoundedChannelOptions(capacity)
        {
            AllowSynchronousContinuations = false,
            FullMode = BoundedChannelFullMode.Wait,
            SingleReader = true,
            SingleWriter = false,
        });
    }

    public ValueTask EnqueueAsync(object message, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(message);
        return _outbound.Writer.WriteAsync(message, cancellationToken);
    }

    public async ValueTask EnqueueSubscriptionReplyAsync(
        object message,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(message);

        while (true)
        {
            cancellationToken.ThrowIfCancellationRequested();
            lock (_subscriptionGate)
            {
                if (_completed)
                {
                    throw new ChannelClosedException();
                }

                if (_outbound.Writer.TryWrite(message))
                {
                    _subscribed = true;
                    return;
                }
            }

            if (!await _outbound.Writer
                    .WaitToWriteAsync(cancellationToken)
                    .ConfigureAwait(false))
            {
                throw new ChannelClosedException();
            }
        }
    }

    public PipeEventEnqueueResult TryEnqueueEvent(object message)
    {
        ArgumentNullException.ThrowIfNull(message);

        lock (_subscriptionGate)
        {
            if (_completed)
            {
                return PipeEventEnqueueResult.Closed;
            }

            if (!_subscribed)
            {
                return PipeEventEnqueueResult.NotSubscribed;
            }

            return _outbound.Writer.TryWrite(message)
                ? PipeEventEnqueueResult.Enqueued
                : PipeEventEnqueueResult.Overflowed;
        }
    }

    public IAsyncEnumerable<object> ReadAllAsync(CancellationToken cancellationToken) =>
        _outbound.Reader.ReadAllAsync(cancellationToken);

    public bool Complete(Exception? exception = null)
    {
        lock (_subscriptionGate)
        {
            if (_completed)
            {
                return false;
            }

            _completed = true;
            return _outbound.Writer.TryComplete(exception);
        }
    }
}
