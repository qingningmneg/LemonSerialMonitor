using System.Collections.Immutable;
using System.Buffers.Binary;
using System.IO.Pipes;
using System.Text;
using System.Text.Json;
using CommMonitor.App.Services;
using CommMonitor.Core.Ipc;
using CommMonitor.Core.Models;

namespace CommMonitor.App.Tests.Services;

public sealed class ServiceClientTests
{
    private static readonly TimeSpan TestTimeout = TimeSpan.FromSeconds(10);

    [Fact]
    public async Task GetStatusAsync_uses_protocol_v1_and_publishes_immutable_batches()
    {
        string pipeName = $"CommMonitor.App.Tests.{Guid.NewGuid():N}";
        using var cancellation = new CancellationTokenSource(TestTimeout);
        await using var commandServer = CreateServer(pipeName);
        await using var client = new ServiceClient(pipeName);
        var received = new TaskCompletionSource<ImmutableArray<CaptureEvent>>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var connectionLost = new TaskCompletionSource<Exception>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        client.EventsReceived += (_, events) => received.TrySetResult(events);
        client.ConnectionLost += (_, exception) => connectionLost.TrySetResult(exception);

        Task<ServiceStatus> statusTask = client.GetStatusAsync(cancellation.Token);
        await commandServer.WaitForConnectionAsync(cancellation.Token);
        PipeCommand listPorts = await PipeFrameCodec.ReadAsync<PipeCommand>(
            commandServer,
            cancellation.Token);
        Assert.Equal(PipeCommandName.ListPorts, listPorts.Command);
        Assert.Equal(PipeProtocol.Version, listPorts.Version);
        await PipeFrameCodec.WriteAsync(
            commandServer,
            new PipeReply(
                listPorts.RequestId,
                success: true,
                result: JsonSerializer.SerializeToElement(new
                {
                    ports = new[] { new { deviceId = 17UL, name = "COM7" } },
                    state = "Paused",
                    captureSource = "development fake capture source",
                })),
            cancellation.Token);

        await using var subscriptionServer = CreateServer(pipeName);
        await subscriptionServer.WaitForConnectionAsync(cancellation.Token);
        PipeCommand subscribe = await PipeFrameCodec.ReadAsync<PipeCommand>(
            subscriptionServer,
            cancellation.Token);
        Assert.Equal(PipeCommandName.Subscribe, subscribe.Command);
        await PipeFrameCodec.WriteAsync(
            subscriptionServer,
            new PipeReply(subscribe.RequestId, success: true),
            cancellation.Token);

        ServiceStatus status = await statusTask;
        Assert.Equal(CaptureState.Paused, status.State);
        ServicePort port = Assert.Single(status.Ports);
        Assert.Equal(17UL, port.DeviceId);
        Assert.Equal("COM7", port.Name);
        Assert.Equal("development fake capture source", status.DriverState);
        Assert.True(client.IsConnected);

        ImmutableArray<CaptureEvent> expected = ImmutableArray.Create(CreateEvent(7));
        await PipeFrameCodec.WriteAsync(
            subscriptionServer,
            new PipeEventBatch(expected),
            cancellation.Token);

        ImmutableArray<CaptureEvent> actual = await received.Task.WaitAsync(cancellation.Token);
        Assert.False(actual.IsDefault);
        CaptureEvent actualEvent = Assert.Single(actual);
        Assert.Equal(expected[0].Sequence, actualEvent.Sequence);
        Assert.Equal(expected[0].Payload.ToArray(), actualEvent.Payload.ToArray());

        await subscriptionServer.DisposeAsync();
        Assert.IsAssignableFrom<IOException>(
            await connectionLost.Task.WaitAsync(cancellation.Token));
    }

    [Fact]
    public async Task GetStatusAsync_times_out_when_the_service_is_absent()
    {
        string pipeName = $"CommMonitor.App.Tests.{Guid.NewGuid():N}";
        await using var client = new ServiceClient(
            pipeName,
            TimeSpan.FromMilliseconds(100));

        TimeoutException exception = await Assert.ThrowsAsync<TimeoutException>(
            () => client.GetStatusAsync());

        Assert.Contains("timed out", exception.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task DisposeAsync_cancels_an_inflight_command_before_returning()
    {
        string pipeName = $"CommMonitor.App.Tests.{Guid.NewGuid():N}";
        using var cancellation = new CancellationTokenSource(TestTimeout);
        await using var commandServer = CreateServer(pipeName);
        var client = new ServiceClient(pipeName, TimeSpan.FromSeconds(30));

        Task<ServiceStatus> statusTask = client.GetStatusAsync();
        await commandServer.WaitForConnectionAsync(cancellation.Token);
        Assert.Equal(
            PipeCommandName.ListPorts,
            (await PipeFrameCodec.ReadAsync<PipeCommand>(commandServer, cancellation.Token)).Command);

        await client.DisposeAsync().AsTask().WaitAsync(cancellation.Token);

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => statusTask);
    }

    [Fact]
    public async Task Commands_remain_correlated_while_subscription_events_are_in_flight()
    {
        string pipeName = $"CommMonitor.App.Tests.{Guid.NewGuid():N}";
        using var cancellation = new CancellationTokenSource(TestTimeout);
        await using var commandServer = CreateServer(pipeName);
        await using var client = new ServiceClient(pipeName);
        var received = new TaskCompletionSource<ImmutableArray<CaptureEvent>>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        client.EventsReceived += (_, events) => received.TrySetResult(events);

        Task<ServiceStatus> statusTask = client.GetStatusAsync(cancellation.Token);
        await commandServer.WaitForConnectionAsync(cancellation.Token);
        PipeCommand listPorts = await PipeFrameCodec.ReadAsync<PipeCommand>(
            commandServer,
            cancellation.Token);
        await PipeFrameCodec.WriteAsync(
            commandServer,
            new PipeReply(
                listPorts.RequestId,
                success: true,
                result: JsonSerializer.SerializeToElement(new
                {
                    ports = Array.Empty<string>(),
                    state = "Stopped",
                    captureSource = "development fake capture source",
                })),
            cancellation.Token);

        await using var subscriptionServer = CreateServer(pipeName);
        await subscriptionServer.WaitForConnectionAsync(cancellation.Token);
        PipeCommand subscribe = await PipeFrameCodec.ReadAsync<PipeCommand>(
            subscriptionServer,
            cancellation.Token);
        await PipeFrameCodec.WriteAsync(
            subscriptionServer,
            new PipeReply(subscribe.RequestId, success: true),
            cancellation.Token);
        await statusTask;

        Task startTask = client.StartAsync([17, 99], "capture.db", cancellation.Token);
        PipeCommand start = await PipeFrameCodec.ReadAsync<PipeCommand>(
            commandServer,
            cancellation.Token);
        Assert.Equal(PipeCommandName.Start, start.Command);
        Assert.Equal(new ulong[] { 17, 99 }, start.DeviceIds);
        Assert.Equal("capture.db", start.SessionPath);

        ImmutableArray<CaptureEvent> expected = ImmutableArray.Create(CreateEvent(8));
        await PipeFrameCodec.WriteAsync(
            subscriptionServer,
            new PipeEventBatch(expected),
            cancellation.Token);
        ImmutableArray<CaptureEvent> actual = await received.Task.WaitAsync(cancellation.Token);
        Assert.False(actual.IsDefault);
        CaptureEvent actualEvent = Assert.Single(actual);
        Assert.Equal(expected[0].Sequence, actualEvent.Sequence);
        Assert.Equal(expected[0].Payload.ToArray(), actualEvent.Payload.ToArray());

        await PipeFrameCodec.WriteAsync(
            commandServer,
            new PipeReply(start.RequestId, success: true),
            cancellation.Token);
        await startTask;

        Task stopTask = client.StopAsync(cancellation.Token);
        PipeCommand stop = await PipeFrameCodec.ReadAsync<PipeCommand>(
            commandServer,
            cancellation.Token);
        Assert.Equal(PipeCommandName.Stop, stop.Command);
        await PipeFrameCodec.WriteAsync(
            commandServer,
            new PipeReply(stop.RequestId, success: true),
            cancellation.Token);
        await stopTask;

        Task exportTask = client.ExportAsync("capture.csv", "csv", cancellation.Token);
        PipeCommand export = await PipeFrameCodec.ReadAsync<PipeCommand>(
            commandServer,
            cancellation.Token);
        Assert.Equal(PipeCommandName.Export, export.Command);
        Assert.Equal("capture.csv", export.ExportPath);
        Assert.Equal("csv", export.ExportFormat);
        await PipeFrameCodec.WriteAsync(
            commandServer,
            new PipeReply(export.RequestId, success: false, error: "not available"),
            cancellation.Token);

        InvalidOperationException exception = await Assert.ThrowsAsync<InvalidOperationException>(
            () => exportTask);
        Assert.Contains("not available", exception.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task Clear_quiesces_the_old_subscription_before_command_and_then_resubscribes()
    {
        string pipeName = $"CommMonitor.App.Tests.{Guid.NewGuid():N}";
        using var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(2));
        await using var commandServer = CreateServer(pipeName);
        await using var client = new ServiceClient(pipeName);
        var received = new TaskCompletionSource<CaptureEvent>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        client.EventsReceived += (_, events) =>
        {
            if (!events.IsEmpty)
            {
                received.TrySetResult(events[0]);
            }
        };
        NamedPipeServerStream oldSubscription = await ConnectAsync(
            client,
            commandServer,
            pipeName,
            cancellation.Token);

        Task clearTask = client.ClearAsync(cancellation.Token);
        var disconnectBuffer = new byte[1];
        Task<int> oldSubscriptionClosed = oldSubscription
            .ReadAsync(disconnectBuffer, cancellation.Token)
            .AsTask();
        Task<PipeCommand> clearCommandReceived = PipeFrameCodec
            .ReadAsync<PipeCommand>(commandServer, cancellation.Token)
            .AsTask();

        Task firstBoundary = await Task.WhenAny(
            oldSubscriptionClosed,
            clearCommandReceived);
        Assert.Same(oldSubscriptionClosed, firstBoundary);
        Assert.Equal(0, await oldSubscriptionClosed);
        CaptureEvent lateOldEvent = CreateEvent(19_999);
        await Assert.ThrowsAnyAsync<IOException>(
            () => PipeFrameCodec.WriteAsync(
                oldSubscription,
                new PipeEventBatch(ImmutableArray.Create(lateOldEvent)),
                cancellation.Token).AsTask());
        await oldSubscription.DisposeAsync();

        await using var newSubscription = CreateServer(pipeName);
        PipeCommand clear = await clearCommandReceived;
        Assert.Equal(PipeCommandName.Clear, clear.Command);
        await PipeFrameCodec.WriteAsync(
            commandServer,
            new PipeReply(clear.RequestId, success: true),
            cancellation.Token);
        await newSubscription.WaitForConnectionAsync(cancellation.Token);
        PipeCommand subscribe = await PipeFrameCodec.ReadAsync<PipeCommand>(
            newSubscription,
            cancellation.Token);
        Assert.Equal(PipeCommandName.Subscribe, subscribe.Command);
        await PipeFrameCodec.WriteAsync(
            newSubscription,
            new PipeReply(subscribe.RequestId, success: true),
            cancellation.Token);

        await clearTask;
        Assert.True(client.IsConnected);
        CaptureEvent postClearEvent = CreateEvent(20_000);
        await PipeFrameCodec.WriteAsync(
            newSubscription,
            new PipeEventBatch(ImmutableArray.Create(postClearEvent)),
            cancellation.Token);
        Assert.Equal(
            postClearEvent.Sequence,
            (await received.Task.WaitAsync(cancellation.Token)).Sequence);
    }

    [Fact]
    public async Task Clear_failure_recovers_the_subscription_before_returning_the_error()
    {
        string pipeName = $"CommMonitor.App.Tests.{Guid.NewGuid():N}";
        using var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(2));
        await using var commandServer = CreateServer(pipeName);
        await using var client = new ServiceClient(pipeName);
        var received = new TaskCompletionSource<CaptureEvent>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        client.EventsReceived += (_, events) =>
        {
            if (!events.IsEmpty)
            {
                received.TrySetResult(events[0]);
            }
        };
        NamedPipeServerStream oldSubscription = await ConnectAsync(
            client,
            commandServer,
            pipeName,
            cancellation.Token);

        Task clearTask = client.ClearAsync(cancellation.Token);
        var disconnectBuffer = new byte[1];
        Assert.Equal(
            0,
            await oldSubscription.ReadAsync(disconnectBuffer, cancellation.Token));
        await oldSubscription.DisposeAsync();
        await using var recoveredSubscription = CreateServer(pipeName);
        PipeCommand clear = await PipeFrameCodec.ReadAsync<PipeCommand>(
            commandServer,
            cancellation.Token);
        await PipeFrameCodec.WriteAsync(
            commandServer,
            new PipeReply(clear.RequestId, success: false, error: "clear rejected"),
            cancellation.Token);
        await recoveredSubscription.WaitForConnectionAsync(cancellation.Token);
        PipeCommand subscribe = await PipeFrameCodec.ReadAsync<PipeCommand>(
            recoveredSubscription,
            cancellation.Token);
        await PipeFrameCodec.WriteAsync(
            recoveredSubscription,
            new PipeReply(subscribe.RequestId, success: true),
            cancellation.Token);

        InvalidOperationException exception = await Assert.ThrowsAsync<InvalidOperationException>(
            () => clearTask);
        Assert.Contains("clear rejected", exception.Message, StringComparison.Ordinal);
        Assert.True(client.IsConnected);
        CaptureEvent recoveredEvent = CreateEvent(20_001);
        await PipeFrameCodec.WriteAsync(
            recoveredSubscription,
            new PipeEventBatch(ImmutableArray.Create(recoveredEvent)),
            cancellation.Token);
        Assert.Equal(
            recoveredEvent.Sequence,
            (await received.Task.WaitAsync(cancellation.Token)).Sequence);
    }

    [Fact]
    public async Task Clear_and_replacement_subscription_failures_preserve_both_causes()
    {
        string pipeName = $"CommMonitor.App.Tests.{Guid.NewGuid():N}";
        using var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(2));
        await using var commandServer = CreateServer(pipeName);
        await using var client = new ServiceClient(pipeName);
        int connectionLostCount = 0;
        var connectionLost = new TaskCompletionSource<Exception>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        client.ConnectionLost += (_, exception) =>
        {
            Interlocked.Increment(ref connectionLostCount);
            connectionLost.TrySetResult(exception);
        };
        NamedPipeServerStream oldSubscription = await ConnectAsync(
            client,
            commandServer,
            pipeName,
            cancellation.Token);

        Task clearTask = client.ClearAsync(cancellation.Token);
        var disconnectBuffer = new byte[1];
        Assert.Equal(
            0,
            await oldSubscription.ReadAsync(disconnectBuffer, cancellation.Token));
        await oldSubscription.DisposeAsync();
        await using var failedReplacement = CreateServer(pipeName);
        PipeCommand clear = await PipeFrameCodec.ReadAsync<PipeCommand>(
            commandServer,
            cancellation.Token);
        await PipeFrameCodec.WriteAsync(
            commandServer,
            new PipeReply(clear.RequestId, success: false, error: "clear rejected"),
            cancellation.Token);
        await failedReplacement.WaitForConnectionAsync(cancellation.Token);
        PipeCommand subscribe = await PipeFrameCodec.ReadAsync<PipeCommand>(
            failedReplacement,
            cancellation.Token);
        await PipeFrameCodec.WriteAsync(
            failedReplacement,
            new PipeReply(subscribe.RequestId, success: false, error: "subscribe rejected"),
            cancellation.Token);

        AggregateException aggregate = await Assert.ThrowsAsync<AggregateException>(
            () => clearTask);
        Assert.Collection(
            aggregate.InnerExceptions,
            exception => Assert.Contains(
                "clear rejected",
                exception.Message,
                StringComparison.Ordinal),
            exception => Assert.Contains(
                "subscribe rejected",
                exception.Message,
                StringComparison.Ordinal));
        Exception reported = await connectionLost.Task.WaitAsync(cancellation.Token);
        Assert.Contains("subscribe rejected", reported.Message, StringComparison.Ordinal);
        Assert.False(client.IsConnected);
        await client.DisposeAsync().AsTask().WaitAsync(cancellation.Token);
        Assert.Equal(1, Volatile.Read(ref connectionLostCount));
    }

    [Fact]
    public async Task DisposeAsync_does_not_deadlock_with_an_inflight_clear()
    {
        string pipeName = $"CommMonitor.App.Tests.{Guid.NewGuid():N}";
        using var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(2));
        await using var commandServer = CreateServer(pipeName);
        var client = new ServiceClient(pipeName, TimeSpan.FromSeconds(30));
        await using NamedPipeServerStream oldSubscription = await ConnectAsync(
            client,
            commandServer,
            pipeName,
            cancellation.Token);

        Task clearTask = client.ClearAsync();
        var disconnectBuffer = new byte[1];
        Assert.Equal(
            0,
            await oldSubscription.ReadAsync(disconnectBuffer, cancellation.Token));
        Assert.Equal(
            PipeCommandName.Clear,
            (await PipeFrameCodec.ReadAsync<PipeCommand>(
                commandServer,
                cancellation.Token)).Command);

        await client.DisposeAsync().AsTask().WaitAsync(cancellation.Token);
        await Assert.ThrowsAnyAsync<Exception>(() => clearTask);
    }

    [Theory]
    [InlineData(SubscriptionFailure.InvalidVersion)]
    [InlineData(SubscriptionFailure.MalformedJson)]
    [InlineData(SubscriptionFailure.OversizedFrame)]
    public async Task Subscription_frame_failures_are_reported_exactly_once_and_observed_by_disposal(
        SubscriptionFailure failure)
    {
        string pipeName = $"CommMonitor.App.Tests.{Guid.NewGuid():N}";
        using var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(2));
        await using var commandServer = CreateServer(pipeName);
        var client = new ServiceClient(pipeName);
        int notificationCount = 0;
        var connectionLost = new TaskCompletionSource<Exception>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        client.ConnectionLost += (_, exception) =>
        {
            Interlocked.Increment(ref notificationCount);
            connectionLost.TrySetResult(exception);
        };

        await using NamedPipeServerStream subscriptionServer = await ConnectAsync(
            client,
            commandServer,
            pipeName,
            cancellation.Token);
        await WriteFailureAsync(subscriptionServer, failure, cancellation.Token);

        Exception exception = await connectionLost.Task.WaitAsync(cancellation.Token);
        Assert.IsType<InvalidDataException>(exception);
        await client.DisposeAsync().AsTask().WaitAsync(cancellation.Token);
        Assert.Equal(1, notificationCount);
    }

    [Fact]
    public async Task Throwing_connection_observer_does_not_starve_later_observers_or_escape_disposal()
    {
        string pipeName = $"CommMonitor.App.Tests.{Guid.NewGuid():N}";
        using var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(2));
        await using var commandServer = CreateServer(pipeName);
        var client = new ServiceClient(pipeName);
        int notificationCount = 0;
        var connectionLost = new TaskCompletionSource<Exception>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        client.ConnectionLost += (_, _) => throw new InvalidOperationException("observer failed");
        client.ConnectionLost += (_, exception) =>
        {
            Interlocked.Increment(ref notificationCount);
            connectionLost.TrySetResult(exception);
        };

        await using NamedPipeServerStream subscriptionServer = await ConnectAsync(
            client,
            commandServer,
            pipeName,
            cancellation.Token);
        await subscriptionServer.DisposeAsync();

        Assert.IsAssignableFrom<IOException>(
            await connectionLost.Task.WaitAsync(cancellation.Token));
        await client.DisposeAsync().AsTask().WaitAsync(cancellation.Token);
        Assert.Equal(1, notificationCount);
    }

    [Fact]
    public async Task Throwing_event_observer_does_not_stop_later_event_batches()
    {
        string pipeName = $"CommMonitor.App.Tests.{Guid.NewGuid():N}";
        using var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(2));
        await using var commandServer = CreateServer(pipeName);
        await using var client = new ServiceClient(pipeName);
        int receivedCount = 0;
        var twoBatchesReceived = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        client.EventsReceived += (_, _) => throw new InvalidOperationException("observer failed");
        client.EventsReceived += (_, _) =>
        {
            if (Interlocked.Increment(ref receivedCount) == 2)
            {
                twoBatchesReceived.TrySetResult();
            }
        };

        await using NamedPipeServerStream subscriptionServer = await ConnectAsync(
            client,
            commandServer,
            pipeName,
            cancellation.Token);
        await PipeFrameCodec.WriteAsync(
            subscriptionServer,
            new PipeEventBatch(ImmutableArray.Create(CreateEvent(1))),
            cancellation.Token);
        await PipeFrameCodec.WriteAsync(
            subscriptionServer,
            new PipeEventBatch(ImmutableArray.Create(CreateEvent(2))),
            cancellation.Token);

        await twoBatchesReceived.Task.WaitAsync(cancellation.Token);
        Assert.Equal(2, receivedCount);
    }

    private static async Task<NamedPipeServerStream> ConnectAsync(
        ServiceClient client,
        NamedPipeServerStream commandServer,
        string pipeName,
        CancellationToken cancellationToken)
    {
        Task<ServiceStatus> statusTask = client.GetStatusAsync(cancellationToken);
        await commandServer.WaitForConnectionAsync(cancellationToken);
        PipeCommand listPorts = await PipeFrameCodec.ReadAsync<PipeCommand>(
            commandServer,
            cancellationToken);
        await PipeFrameCodec.WriteAsync(
            commandServer,
            new PipeReply(
                listPorts.RequestId,
                success: true,
                result: JsonSerializer.SerializeToElement(new
                {
                    ports = Array.Empty<string>(),
                    state = "Stopped",
                    captureSource = "development fake capture source",
                })),
            cancellationToken);

        NamedPipeServerStream subscriptionServer = CreateServer(pipeName);
        try
        {
            await subscriptionServer.WaitForConnectionAsync(cancellationToken);
            PipeCommand subscribe = await PipeFrameCodec.ReadAsync<PipeCommand>(
                subscriptionServer,
                cancellationToken);
            await PipeFrameCodec.WriteAsync(
                subscriptionServer,
                new PipeReply(subscribe.RequestId, success: true),
                cancellationToken);
            await statusTask;
            return subscriptionServer;
        }
        catch
        {
            await subscriptionServer.DisposeAsync();
            throw;
        }
    }

    private static async Task WriteFailureAsync(
        Stream stream,
        SubscriptionFailure failure,
        CancellationToken cancellationToken)
    {
        if (failure == SubscriptionFailure.InvalidVersion)
        {
            await PipeFrameCodec.WriteAsync(
                stream,
                new PipeEventBatch([], PipeProtocol.Version + 1),
                cancellationToken);
            return;
        }

        byte[] lengthPrefix = new byte[sizeof(int)];
        if (failure == SubscriptionFailure.OversizedFrame)
        {
            BinaryPrimitives.WriteInt32LittleEndian(
                lengthPrefix,
                PipeProtocol.MaximumFrameLength + 1);
            await stream.WriteAsync(lengthPrefix, cancellationToken);
        }
        else
        {
            byte[] malformedJson = Encoding.UTF8.GetBytes("{");
            BinaryPrimitives.WriteInt32LittleEndian(lengthPrefix, malformedJson.Length);
            await stream.WriteAsync(lengthPrefix, cancellationToken);
            await stream.WriteAsync(malformedJson, cancellationToken);
        }

        await stream.FlushAsync(cancellationToken);
    }

    private static NamedPipeServerStream CreateServer(string pipeName) =>
        new(
            pipeName,
            PipeDirection.InOut,
            maxNumberOfServerInstances: 2,
            PipeTransmissionMode.Byte,
            PipeOptions.Asynchronous);

    private static CaptureEvent CreateEvent(long sequence) =>
        new(
            sequence,
            sequence * 10,
            17,
            42,
            CaptureKind.Read,
            0,
            0,
            1,
            1,
            CaptureFlags.None,
            ImmutableArray.Create((byte)sequence))
        {
            PortName = "COM7",
            ProcessName = "test.exe",
            Timestamp = DateTimeOffset.UnixEpoch.AddTicks(sequence),
        };

    public enum SubscriptionFailure
    {
        InvalidVersion,
        MalformedJson,
        OversizedFrame,
    }
}
