using System.Collections.Immutable;
using System.IO.Pipes;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text.Json;
using System.Threading.Channels;
using CommMonitor.Core.Ipc;
using CommMonitor.Core.Models;
using CommMonitor.Core.Sessions;
using CommMonitor.Service.Capture;
using CommMonitor.Service.Ipc;
using CommMonitor.Service.Ports;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;

namespace CommMonitor.Service.Tests.Ipc;

public sealed class PipeServerTests
{
    private static readonly TimeSpan TestTimeout = TimeSpan.FromSeconds(5);

    [Fact]
    public void CreatePipeSecurity_grants_required_principals_and_server_instance_creation()
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        PipeSecurity security = PipeServer.CreatePipeSecurity();
        PipeAccessRule[] rules = security
            .GetAccessRules(includeExplicit: true, includeInherited: false, typeof(SecurityIdentifier))
            .Cast<PipeAccessRule>()
            .ToArray();

        Assert.True(security.AreAccessRulesProtected);
        AssertAllowRule(rules, WellKnownSidType.LocalSystemSid, PipeAccessRights.FullControl);
        AssertAllowRule(rules, WellKnownSidType.BuiltinAdministratorsSid, PipeAccessRights.FullControl);
        AssertAllowRule(rules, WellKnownSidType.BuiltinUsersSid, PipeAccessRights.ReadWrite);
        using WindowsIdentity identity = WindowsIdentity.GetCurrent();
        AssertAllowRule(rules, identity.User!, PipeAccessRights.CreateNewInstance);
    }

    [Fact]
    public void CreatePipeSecurity_denies_network_pipe_access()
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        PipeAccessRule[] rules = PipeServer.CreatePipeSecurity()
            .GetAccessRules(includeExplicit: true, includeInherited: false, typeof(SecurityIdentifier))
            .Cast<PipeAccessRule>()
            .ToArray();

        AssertAccessRule(
            rules,
            new SecurityIdentifier(WellKnownSidType.NetworkSid, domainSid: null),
            PipeAccessRights.ReadWrite | PipeAccessRights.CreateNewInstance,
            AccessControlType.Deny);
    }

    [Fact]
    public async Task Four_clients_can_connect_concurrently()
    {
        await using var host = new TestPipeHost();
        await host.StartAsync();
        var clients = new List<NamedPipeClientStream>();

        try
        {
            Task<NamedPipeClientStream>[] connections = Enumerable
                .Range(0, PipeServer.MaximumServerInstances)
                .Select(_ => host.ConnectAsync())
                .ToArray();
            clients.AddRange(await Task.WhenAll(connections));

            Assert.Equal(4, clients.Count);
            Assert.All(clients, client => Assert.True(client.IsConnected));
        }
        finally
        {
            foreach (NamedPipeClientStream client in clients)
            {
                await client.DisposeAsync();
            }
        }
    }

    [Fact]
    public async Task Disconnected_client_does_not_cancel_the_server_or_a_later_client()
    {
        await using var host = new TestPipeHost();
        await host.StartAsync();

        await using (NamedPipeClientStream disconnected = await host.ConnectAsync())
        {
        }

        await using NamedPipeClientStream client = await host.ConnectAsync();
        await PipeFrameCodec.WriteAsync(
            client,
            new PipeCommand("start-after-disconnect", PipeCommandName.Start, [17, 99], host.SessionPath));

        PipeReply reply = await ReadWithTimeoutAsync<PipeReply>(client);

        Assert.True(reply.Success, reply.Error);
        Assert.Equal("start-after-disconnect", reply.RequestId);
        Assert.Equal(CaptureState.Running, host.Coordinator.State);
    }

    [Fact]
    public async Task Mutating_commands_are_routed_through_the_wpf_capture_controller()
    {
        await using var host = new TestPipeHost();
        await host.StartAsync();
        await using NamedPipeClientStream client = await host.ConnectAsync();

        PipeCommand[] commands =
        [
            new PipeCommand("route-start", PipeCommandName.Start, [17], host.SessionPath),
            new PipeCommand("route-pause", PipeCommandName.Pause),
            new PipeCommand("route-resume", PipeCommandName.Resume),
            new PipeCommand("route-stop", PipeCommandName.Stop),
        ];
        foreach (PipeCommand command in commands)
        {
            await PipeFrameCodec.WriteAsync(client, command);
            PipeReply reply = await ReadWithTimeoutAsync<PipeReply>(client);
            Assert.True(reply.Success, reply.Error);
        }

        Assert.Equal(
            new[] { "Start", "Pause", "Resume", "Stop" },
            host.WpfController.Calls);
    }

    [Fact]
    public async Task Subscriber_receives_immutable_batches_published_by_the_coordinator()
    {
        await using var host = new TestPipeHost();
        await host.StartAsync();
        await using NamedPipeClientStream client = await host.ConnectAsync();

        await PipeFrameCodec.WriteAsync(
            client,
            new PipeCommand("subscribe-1", PipeCommandName.Subscribe));
        PipeReply subscribeReply = await ReadWithTimeoutAsync<PipeReply>(client);
        Assert.True(subscribeReply.Success, subscribeReply.Error);
        Assert.Equal("subscribe-1", subscribeReply.RequestId);

        await PipeFrameCodec.WriteAsync(
            client,
            new PipeCommand("start-1", PipeCommandName.Start, [17, 99], host.SessionPath));
        PipeReply startReply = await ReadWithTimeoutAsync<PipeReply>(client);
        Assert.True(startReply.Success, startReply.Error);
        Assert.Equal("start-1", startReply.RequestId);

        await host.Source.EmitAsync(CreateEvent(7));
        PipeEventBatch batch = await ReadWithTimeoutAsync<PipeEventBatch>(client);

        CaptureEvent captureEvent = Assert.Single(batch.Events);
        Assert.Equal(1, captureEvent.Sequence);
        Assert.Equal(7, captureEvent.WireSequence);
        Assert.Equal(new byte[] { 0x07 }, captureEvent.Payload);
        Assert.Equal(PipeProtocol.Version, batch.Version);
    }

    [Fact]
    public async Task Subscription_activation_queues_the_reply_before_accepting_events()
    {
        var output = new PipeClientOutputQueue(capacity: 2);
        var reply = new PipeReply("subscribe-atomic", success: true);
        var eventBatch = new PipeEventBatch(ImmutableArray.Create(CreateEvent(1)));

        Assert.Equal(
            PipeEventEnqueueResult.NotSubscribed,
            output.TryEnqueueEvent(eventBatch));

        await output.EnqueueSubscriptionReplyAsync(reply, CancellationToken.None);
        Assert.Equal(PipeEventEnqueueResult.Enqueued, output.TryEnqueueEvent(eventBatch));

        using var cancellation = new CancellationTokenSource(TestTimeout);
        await using IAsyncEnumerator<object> reader = output
            .ReadAllAsync(cancellation.Token)
            .GetAsyncEnumerator(cancellation.Token);
        Assert.True(await reader.MoveNextAsync());
        Assert.Same(reply, reader.Current);
        Assert.True(await reader.MoveNextAsync());
        Assert.Same(eventBatch, reader.Current);
        output.Complete();
    }

    [Fact]
    public async Task ListPorts_reports_that_capture_uses_the_development_fake_source()
    {
        await using var host = new TestPipeHost();
        await host.StartAsync();
        await using NamedPipeClientStream client = await host.ConnectAsync();

        await PipeFrameCodec.WriteAsync(
            client,
            new PipeCommand("status-1", PipeCommandName.ListPorts));
        PipeReply reply = await ReadWithTimeoutAsync<PipeReply>(client);

        Assert.True(reply.Success, reply.Error);
        Assert.Equal("status-1", reply.RequestId);
        string captureSource = reply.Result!.Value
            .GetProperty("captureSource")
            .GetString()!;
        Assert.Contains("fake", captureSource, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("development", captureSource, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task ListPorts_returns_real_port_hashes_and_capture_source_status()
    {
        var catalog = new StaticPortCatalog([
            new PortInfo("COM7", "USB serial (COM7)", "USB\\TEST", 0x1234),
        ]);
        var statusProvider = new StaticStatusProvider(new CaptureSourceStatus(
            CaptureSourceStatusKind.Ready,
            "CommMonitor driver protocol 1 is ready."));
        await using var host = new TestPipeHost(catalog, statusProvider);
        await host.StartAsync();
        await using NamedPipeClientStream client = await host.ConnectAsync();

        await PipeFrameCodec.WriteAsync(
            client,
            new PipeCommand("status-real", PipeCommandName.ListPorts));
        PipeReply reply = await ReadWithTimeoutAsync<PipeReply>(client);

        Assert.True(reply.Success, reply.Error);
        JsonElement result = reply.Result!.Value;
        JsonElement port = Assert.Single(result.GetProperty("ports").EnumerateArray());
        Assert.Equal("COM7", port.GetProperty("name").GetString());
        Assert.Equal(0x1234UL, port.GetProperty("deviceId").GetUInt64());
        Assert.Equal("Ready", result.GetProperty("captureSourceKind").GetString());
        Assert.Contains("ready", result.GetProperty("captureSource").GetString()!,
            StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task ListPorts_keeps_driver_status_visible_when_port_discovery_fails()
    {
        var statusProvider = new StaticStatusProvider(new CaptureSourceStatus(
            CaptureSourceStatusKind.DriverUnavailable,
            "Driver missing"));
        await using var host = new TestPipeHost(
            new ThrowingPortCatalog(new IOException("WMI unavailable")),
            statusProvider);
        await host.StartAsync();
        await using NamedPipeClientStream client = await host.ConnectAsync();

        await PipeFrameCodec.WriteAsync(
            client,
            new PipeCommand("status-no-wmi", PipeCommandName.ListPorts));
        PipeReply reply = await ReadWithTimeoutAsync<PipeReply>(client);

        Assert.True(reply.Success, reply.Error);
        JsonElement result = reply.Result!.Value;
        Assert.Empty(result.GetProperty("ports").EnumerateArray());
        Assert.Equal("DriverUnavailable",
            result.GetProperty("captureSourceKind").GetString());
        Assert.Equal("WMI unavailable",
            result.GetProperty("portCatalogError").GetString());
    }

    [Fact]
    public async Task Export_writes_the_stopped_session_inside_the_service_export_directory()
    {
        await using var host = new TestPipeHost();
        await host.StartAsync();
        await using NamedPipeClientStream client = await host.ConnectAsync();
        var published = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        host.Coordinator.EventsPublished += (_, _) => published.TrySetResult();

        await PipeFrameCodec.WriteAsync(
            client,
            new PipeCommand("export-start", PipeCommandName.Start, [17], host.SessionPath));
        Assert.True((await ReadWithTimeoutAsync<PipeReply>(client)).Success);
        await host.Source.EmitAsync(CreateEvent(1));
        await published.Task.WaitAsync(TestTimeout);
        await PipeFrameCodec.WriteAsync(
            client,
            new PipeCommand("export-stop", PipeCommandName.Stop));
        Assert.True((await ReadWithTimeoutAsync<PipeReply>(client)).Success);

        await PipeFrameCodec.WriteAsync(
            client,
            new PipeCommand(
                "export-raw",
                PipeCommandName.Export,
                exportPath: "capture.raw",
                exportFormat: "raw"));
        PipeReply reply = await ReadWithTimeoutAsync<PipeReply>(client);

        Assert.True(reply.Success, reply.Error);
        string path = reply.Result!.Value.GetProperty("path").GetString()!;
        Assert.Equal(Path.Combine(host.ExportRoot, "capture.raw"), path);
        Assert.Equal(new byte[] { 1 }, await File.ReadAllBytesAsync(path));
    }

    [Theory]
    [InlineData("..\\escape.raw")]
    [InlineData("folder/escape.raw")]
    [InlineData("C:\\escape.raw")]
    public async Task Export_rejects_paths_outside_the_service_export_directory(
        string exportPath)
    {
        await using var host = new TestPipeHost();
        await host.StartAsync();
        await using NamedPipeClientStream client = await host.ConnectAsync();

        await PipeFrameCodec.WriteAsync(
            client,
            new PipeCommand(
                "unsafe-export",
                PipeCommandName.Export,
                exportPath: exportPath,
                exportFormat: "raw"));
        PipeReply reply = await ReadWithTimeoutAsync<PipeReply>(client);

        Assert.False(reply.Success);
        Assert.False(File.Exists(Path.GetFullPath(
            Path.Combine(host.ExportRoot, exportPath))));
    }

    [Theory]
    [InlineData("..\\escape.db")]
    [InlineData("../escape.db")]
    [InlineData("folder/capture.db")]
    [InlineData("C:\\escape.db")]
    [InlineData("C:escape.db")]
    [InlineData("CON.db")]
    [InlineData("CON .db")]
    [InlineData("COM1.capture.db")]
    [InlineData("COM¹")]
    [InlineData("COM¹.db")]
    [InlineData("COM²")]
    [InlineData("COM².capture.db")]
    [InlineData("COM³")]
    [InlineData("COM³.db")]
    [InlineData("LPT¹")]
    [InlineData("LPT¹.db")]
    [InlineData("LPT²")]
    [InlineData("LPT².capture.db")]
    [InlineData("LPT³")]
    [InlineData("LPT³.db")]
    public async Task Start_rejects_unsafe_session_paths(string sessionPath)
    {
        await using var host = new TestPipeHost();
        await host.StartAsync();
        await using NamedPipeClientStream client = await host.ConnectAsync();

        await PipeFrameCodec.WriteAsync(
            client,
            new PipeCommand("unsafe-session", PipeCommandName.Start, [17], sessionPath));
        PipeReply reply = await ReadWithTimeoutAsync<PipeReply>(client);

        Assert.False(reply.Success);
        Assert.Equal("unsafe-session", reply.RequestId);
        Assert.Equal(CaptureState.Stopped, host.Coordinator.State);
    }

    [Fact]
    public async Task Slow_subscriber_overflow_disconnects_only_that_client_and_not_inflight_pause()
    {
        string sessionRoot = Path.Combine(
            Path.GetTempPath(),
            $"commmonitor-overflow-{Guid.NewGuid():N}");
        Directory.CreateDirectory(sessionRoot);
        string pipeName = $"CommMonitor.Service.Tests.{Guid.NewGuid():N}";
        var source = new BlockingCaptureSource();
        var logger = new OverflowLogger();
        await using var coordinator = new CaptureCoordinator(
            source,
            new SingleSessionStoreFactory(new NonPersistingSessionStore()));
        var wpfController = new RecordingWpfCaptureController(coordinator);
        var server = new PipeServer(
            coordinator,
            wpfController,
            new StaticPortCatalog([]),
            new StaticStatusProvider(new CaptureSourceStatus(
                CaptureSourceStatusKind.DevelopmentFake,
                "Test capture source")),
            logger,
            pipeName,
            sessionRoot);
        await server.StartAsync(CancellationToken.None);
        NamedPipeClientStream? slowClient = null;

        try
        {
            slowClient = await ConnectAsync(pipeName);
            await PipeFrameCodec.WriteAsync(
                slowClient,
                new PipeCommand("subscribe-slow", PipeCommandName.Subscribe));
            Assert.True((await ReadWithTimeoutAsync<PipeReply>(slowClient)).Success);

            await PipeFrameCodec.WriteAsync(
                slowClient,
                new PipeCommand("start-slow", PipeCommandName.Start, [17], "overflow.db"));
            Assert.True((await ReadWithTimeoutAsync<PipeReply>(slowClient)).Success);

            await PipeFrameCodec.WriteAsync(
                slowClient,
                new PipeCommand("pause-slow", PipeCommandName.Pause));
            await source.PauseEntered.WaitAsync(TestTimeout);

            int eventCount = 64 * (PipeServer.OutboundQueueCapacity + 8);
            for (int sequence = 1; sequence <= eventCount; sequence++)
            {
                await source.EmitAsync(CreateEvent(sequence, payloadLength: 1024));
            }

            await logger.OverflowDetected.WaitAsync(TestTimeout);
            Assert.False(source.PauseWasCanceled);

            source.ReleasePause();
            await source.PauseCompleted.WaitAsync(TestTimeout);
            await WaitForStateAsync(coordinator, CaptureState.Paused);
            Assert.Equal(CaptureState.Paused, coordinator.State);

            await using NamedPipeClientStream healthyClient = await ConnectAsync(pipeName);
            await PipeFrameCodec.WriteAsync(
                healthyClient,
                new PipeCommand("healthy-status", PipeCommandName.ListPorts));
            PipeReply healthyReply = await ReadWithTimeoutAsync<PipeReply>(healthyClient);
            Assert.True(healthyReply.Success, healthyReply.Error);
            Assert.Equal("healthy-status", healthyReply.RequestId);
        }
        finally
        {
            source.ReleasePause();
            if (slowClient is not null)
            {
                await slowClient.DisposeAsync();
            }

            using var cancellation = new CancellationTokenSource(TestTimeout);
            await server.StopAsync(cancellation.Token);
            Directory.Delete(sessionRoot, recursive: true);
        }
    }

    private static async Task<T> ReadWithTimeoutAsync<T>(Stream stream)
    {
        using var cancellation = new CancellationTokenSource(TestTimeout);
        return await PipeFrameCodec.ReadAsync<T>(stream, cancellation.Token);
    }

    private static async Task WaitForStateAsync(
        CaptureCoordinator coordinator,
        CaptureState expectedState)
    {
        using var cancellation = new CancellationTokenSource(TestTimeout);
        while (coordinator.State != expectedState)
        {
            await Task.Delay(TimeSpan.FromMilliseconds(10), cancellation.Token);
        }
    }

    private static void AssertAllowRule(
        IEnumerable<PipeAccessRule> rules,
        WellKnownSidType sidType,
        PipeAccessRights rights)
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException("Named-pipe ACL assertions require Windows.");
        }

        var expectedSid = new SecurityIdentifier(sidType, domainSid: null);
        AssertAllowRule(rules, expectedSid, rights);
    }

    private static void AssertAllowRule(
        IEnumerable<PipeAccessRule> rules,
        SecurityIdentifier expectedSid,
        PipeAccessRights rights)
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException("Named-pipe ACL assertions require Windows.");
        }

        AssertAccessRule(rules, expectedSid, rights, AccessControlType.Allow);
    }

    private static void AssertAccessRule(
        IEnumerable<PipeAccessRule> rules,
        SecurityIdentifier expectedSid,
        PipeAccessRights rights,
        AccessControlType accessControlType)
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException("Named-pipe ACL assertions require Windows.");
        }

        PipeAccessRule? matchingRule = null;
        foreach (PipeAccessRule candidate in rules)
        {
            if (candidate.AccessControlType == accessControlType &&
                expectedSid.Equals(candidate.IdentityReference))
            {
                Assert.Null(matchingRule);
                matchingRule = candidate;
            }
        }

        PipeAccessRule rule = Assert.IsType<PipeAccessRule>(matchingRule);
        Assert.Equal(rights, rule.PipeAccessRights & rights);
    }

    private static async Task<NamedPipeClientStream> ConnectAsync(string pipeName)
    {
        var client = new NamedPipeClientStream(
            ".",
            pipeName,
            PipeDirection.InOut,
            PipeOptions.Asynchronous);
        try
        {
            using var cancellation = new CancellationTokenSource(TestTimeout);
            await client.ConnectAsync(cancellation.Token);
            return client;
        }
        catch
        {
            await client.DisposeAsync();
            throw;
        }
    }

    private static CaptureEvent CreateEvent(long sequence, int payloadLength = 1) =>
        new(
            sequence,
            sequence * 10,
            17,
            42,
            CaptureKind.Read,
            0,
            0,
            payloadLength,
            payloadLength,
            CaptureFlags.None,
            ImmutableArray.CreateRange(Enumerable.Repeat((byte)sequence, payloadLength)))
        {
            PortName = "COM7",
            ProcessName = "test.exe",
            Timestamp = DateTimeOffset.UnixEpoch.AddTicks(sequence),
        };

    private sealed class TestPipeHost : IAsyncDisposable
    {
        private readonly string _sessionRoot = Path.Combine(
            Path.GetTempPath(),
            $"commmonitor-pipe-{Guid.NewGuid():N}");
        private readonly string _storePath;

        public TestPipeHost(
            IPortCatalog? portCatalog = null,
            ICaptureSourceStatusProvider? statusProvider = null)
        {
            Directory.CreateDirectory(_sessionRoot);
            _storePath = Path.Combine(_sessionRoot, SessionPath);
            PipeName = $"CommMonitor.Service.Tests.{Guid.NewGuid():N}";
            Source = new FakeCaptureSource();
            Coordinator = new CaptureCoordinator(Source, new SessionStoreFactory());
            WpfController = new RecordingWpfCaptureController(Coordinator);
            Server = new PipeServer(
                Coordinator,
                WpfController,
                portCatalog ?? new StaticPortCatalog([]),
                statusProvider ?? Source,
                NullLogger<PipeServer>.Instance,
                PipeName,
                _sessionRoot);
        }

        public string PipeName { get; }
        public string SessionPath => "capture.db";
        public string ExportRoot => Path.Combine(_sessionRoot, "Exports");
        public FakeCaptureSource Source { get; }
        public CaptureCoordinator Coordinator { get; }
        public RecordingWpfCaptureController WpfController { get; }
        public PipeServer Server { get; }

        public Task StartAsync() => Server.StartAsync(CancellationToken.None);

        public async Task<NamedPipeClientStream> ConnectAsync()
        {
            return await PipeServerTests.ConnectAsync(PipeName);
        }

        public async ValueTask DisposeAsync()
        {
            using var cancellation = new CancellationTokenSource(TestTimeout);
            await Server.StopAsync(cancellation.Token);
            await Coordinator.DisposeAsync();
            DeleteIfExists(_storePath);
            DeleteIfExists(_storePath + "-shm");
            DeleteIfExists(_storePath + "-wal");
            Directory.Delete(_sessionRoot, recursive: true);
        }

        private static void DeleteIfExists(string path)
        {
            if (File.Exists(path))
            {
                File.Delete(path);
            }
        }
    }

    private sealed class RecordingWpfCaptureController(CaptureCoordinator coordinator)
        : IWpfCaptureController
    {
        public List<string> Calls { get; } = [];

        public async Task StartWpfAsync(
            CaptureSelection selection,
            CancellationToken cancellationToken = default)
        {
            Calls.Add("Start");
            await coordinator.StartAsync(selection, cancellationToken);
        }

        public async Task PauseWpfAsync(CancellationToken cancellationToken = default)
        {
            Calls.Add("Pause");
            await coordinator.PauseAsync(cancellationToken);
        }

        public async Task ResumeWpfAsync(CancellationToken cancellationToken = default)
        {
            Calls.Add("Resume");
            await coordinator.ResumeAsync(cancellationToken);
        }

        public async Task StopWpfAsync(CancellationToken cancellationToken = default)
        {
            Calls.Add("Stop");
            await coordinator.StopAsync(cancellationToken);
        }
    }

    private sealed class StaticPortCatalog(IReadOnlyList<PortInfo> ports) : IPortCatalog
    {
        public ValueTask<IReadOnlyList<PortInfo>> GetPortsAsync(
            CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            return ValueTask.FromResult(ports);
        }
    }

    private sealed class ThrowingPortCatalog(Exception exception) : IPortCatalog
    {
        public ValueTask<IReadOnlyList<PortInfo>> GetPortsAsync(
            CancellationToken cancellationToken) =>
            ValueTask.FromException<IReadOnlyList<PortInfo>>(exception);
    }

    private sealed class StaticStatusProvider(CaptureSourceStatus status)
        : ICaptureSourceStatusProvider
    {
        public ValueTask<CaptureSourceStatus> GetStatusAsync(
            CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            return ValueTask.FromResult(status);
        }
    }

    private sealed class NonPersistingSessionStore : ISessionStore
    {
        public Task InitializeAsync(CancellationToken cancellationToken = default) =>
            Task.CompletedTask;

        public Task<int> GetSchemaVersionAsync(CancellationToken cancellationToken = default) =>
            Task.FromResult(3);

        public Task<long> GetLastSequenceAsync(CancellationToken cancellationToken = default) =>
            Task.FromResult(0L);

        public Task<long> CountRunsAsync(CancellationToken cancellationToken = default) =>
            Task.FromResult(0L);

        public Task UpsertRunAsync(
            CaptureRunRecord run,
            CancellationToken cancellationToken = default) =>
            Task.CompletedTask;

        public Task<IReadOnlyList<CaptureRunRecord>> ReadRunsAsync(
            CancellationToken cancellationToken = default) =>
            Task.FromResult<IReadOnlyList<CaptureRunRecord>>([]);

        public Task<IReadOnlyList<IntegrityMarker>> ReadMarkersAsync(
            string runId,
            CancellationToken cancellationToken = default) =>
            Task.FromResult<IReadOnlyList<IntegrityMarker>>([]);

        public Task<IReadOnlyList<CaptureEvent>> AppendBatchAsync(
            PersistBatch batch,
            CancellationToken cancellationToken = default) =>
            Task.FromResult(batch.Events);

        public Task<IReadOnlyList<CaptureEvent>> AppendAsync(
            IReadOnlyList<CaptureEvent> events,
            CancellationToken cancellationToken = default) =>
            Task.FromResult(events);

        public Task<IReadOnlyList<CaptureEvent>> ReadAfterAsync(
            long sequence,
            int limit,
            CancellationToken cancellationToken = default) =>
            Task.FromResult<IReadOnlyList<CaptureEvent>>([]);

        public Task ClearAsync(CancellationToken cancellationToken = default) =>
            Task.CompletedTask;
    }

    private sealed class SingleSessionStoreFactory(ISessionStore store) : ISessionStoreFactory
    {
        public ISessionStore Create(string path) => store;
    }

    private sealed class BlockingCaptureSource : ICaptureSource
    {
        private readonly Channel<CaptureEvent> _events = Channel.CreateUnbounded<CaptureEvent>();
        private readonly TaskCompletionSource _pauseEntered =
            new(TaskCreationOptions.RunContinuationsAsynchronously);
        private readonly TaskCompletionSource _releasePause =
            new(TaskCreationOptions.RunContinuationsAsynchronously);
        private readonly TaskCompletionSource _pauseCompleted =
            new(TaskCreationOptions.RunContinuationsAsynchronously);
        private int _pauseWasCanceled;

        public Task PauseEntered => _pauseEntered.Task;
        public Task PauseCompleted => _pauseCompleted.Task;
        public bool PauseWasCanceled => Volatile.Read(ref _pauseWasCanceled) != 0;

        public async ValueTask ConfigureAsync(
            CaptureState state,
            IReadOnlySet<ulong> deviceIds,
            CancellationToken cancellationToken)
        {
            if (state != CaptureState.Paused)
            {
                return;
            }

            _pauseEntered.TrySetResult();
            try
            {
                await _releasePause.Task.WaitAsync(cancellationToken);
                _pauseCompleted.TrySetResult();
            }
            catch (OperationCanceledException)
            {
                Interlocked.Exchange(ref _pauseWasCanceled, 1);
                throw;
            }
        }

        public IAsyncEnumerable<CaptureEvent> ReadAllAsync(CancellationToken cancellationToken) =>
            _events.Reader.ReadAllAsync(cancellationToken);

        public ValueTask EmitAsync(CaptureEvent captureEvent) =>
            _events.Writer.WriteAsync(captureEvent);

        public void ReleasePause() => _releasePause.TrySetResult();

        public ValueTask DisposeAsync()
        {
            _releasePause.TrySetResult();
            _events.Writer.TryComplete();
            return ValueTask.CompletedTask;
        }
    }

    private sealed class OverflowLogger : ILogger<PipeServer>
    {
        private readonly TaskCompletionSource _overflowDetected =
            new(TaskCreationOptions.RunContinuationsAsynchronously);

        public Task OverflowDetected => _overflowDetected.Task;

        public IDisposable? BeginScope<TState>(TState state) where TState : notnull => null;

        public bool IsEnabled(LogLevel logLevel) => true;

        public void Log<TState>(
            LogLevel logLevel,
            EventId eventId,
            TState state,
            Exception? exception,
            Func<TState, Exception?, string> formatter)
        {
            if (formatter(state, exception).Contains("overflow", StringComparison.OrdinalIgnoreCase))
            {
                _overflowDetected.TrySetResult();
            }
        }
    }
}
