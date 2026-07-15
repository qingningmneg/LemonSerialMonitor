using System.Collections.Immutable;
using CommMonitor.Core.Models;
using CommMonitor.Core.Sessions;
using CommMonitor.Service.Capture;

namespace CommMonitor.Service.Tests.Capture;

public sealed class CaptureCoordinatorTests
{
    private static readonly TimeSpan TestConditionWatchdog = TimeSpan.FromSeconds(10);

    [Fact]
    public void FakeCaptureSourceIsInternal()
    {
        Assert.False(typeof(FakeCaptureSource).IsPublic);
    }

    [Fact]
    public async Task StateTransitionsFromStoppedThroughRunningAndPausedBackToStopped()
    {
        await using var session = new TestSession();
        await using var coordinator = new CaptureCoordinator(
            new FakeCaptureSource(),
            Factory(session.Store));

        Assert.Equal(CaptureState.Stopped, coordinator.State);

        await coordinator.StartAsync(session.Selection);
        Assert.Equal(CaptureState.Running, coordinator.State);

        await coordinator.PauseAsync();
        Assert.Equal(CaptureState.Paused, coordinator.State);

        await coordinator.ResumeAsync();
        Assert.Equal(CaptureState.Running, coordinator.State);

        await coordinator.StopAsync();
        Assert.Equal(CaptureState.Stopped, coordinator.State);
    }

    [Fact]
    public async Task PauseWhileStoppedThrowsInvalidOperationException()
    {
        await using var session = new TestSession();
        await using var coordinator = new CaptureCoordinator(
            new FakeCaptureSource(),
            Factory(session.Store));

        await Assert.ThrowsAsync<InvalidOperationException>(() => coordinator.PauseAsync());
    }

    [Fact]
    public async Task StopDoesNotClearPersistedEvents()
    {
        await using var session = new TestSession();
        var source = new FakeCaptureSource();
        await using var coordinator = new CaptureCoordinator(source, Factory(session.Store));
        var published = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        coordinator.EventsPublished += (_, _) => published.TrySetResult();

        await coordinator.StartAsync(session.Selection);
        await source.EmitAsync(CreateEvent(1));
        await WaitForConditionAsync(published.Task, "the persisted event to be published");
        await coordinator.StopAsync();

        IReadOnlyList<CaptureEvent> stored = await session.Store.ReadAfterAsync(0, 10);
        CaptureEvent captureEvent = Assert.Single(stored);
        Assert.Equal(1, captureEvent.Sequence);
    }

    [Fact]
    public async Task ClearIsAcceptedOnlyWhileStopped()
    {
        await using var session = new TestSession();
        var source = new FakeCaptureSource();
        await using var coordinator = new CaptureCoordinator(source, Factory(session.Store));
        var published = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        coordinator.EventsPublished += (_, _) => published.TrySetResult();

        await coordinator.StartAsync(session.Selection);
        await source.EmitAsync(CreateEvent(1));
        await WaitForConditionAsync(published.Task, "the persisted event to be published");

        await Assert.ThrowsAsync<InvalidOperationException>(() => coordinator.ClearAsync());

        await coordinator.PauseAsync();
        await Assert.ThrowsAsync<InvalidOperationException>(() => coordinator.ClearAsync());

        await coordinator.StopAsync();
        await coordinator.ClearAsync();

        Assert.Empty(await session.Store.ReadAfterAsync(0, 10));
    }

    [Fact]
    public async Task PublishedBatchesPreserveEventSequence()
    {
        var store = new SynchronousInMemorySessionStore();
        var source = new FakeCaptureSource();
        await using var coordinator = new CaptureCoordinator(source, Factory(store));
        var batches = new List<ImmutableArray<CaptureEvent>>();
        var allPublished = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        coordinator.EventsPublished += (_, batch) =>
        {
            lock (batches)
            {
                batches.Add(batch);
                if (batches.Sum(item => item.Length) == 70)
                {
                    allPublished.TrySetResult();
                }
            }
        };

        await coordinator.StartAsync(
            new CaptureSelection(new HashSet<ulong> { 0x1234 }, "ordering.db"));
        for (long sequence = 1; sequence <= 70; sequence++)
        {
            await source.EmitAsync(CreateEvent(sequence));
        }

        await WaitForConditionAsync(allPublished.Task, "all 70 events to be published");
        await coordinator.StopAsync();

        ImmutableArray<CaptureEvent>[] publishedBatches;
        lock (batches)
        {
            publishedBatches = batches.ToArray();
        }

        Assert.All(publishedBatches, batch => Assert.InRange(batch.Length, 1, 64));
        Assert.Equal(Enumerable.Range(1, 70).Select(value => (long)value),
            publishedBatches.SelectMany(batch => batch).Select(captureEvent => captureEvent.Sequence));
    }

    [Fact]
    public async Task FailedPersistenceIsNotRetriedOrPublished()
    {
        var source = new FakeCaptureSource();
        var store = new FailingSessionStore();
        await using var coordinator = new CaptureCoordinator(source, Factory(store));
        bool wasPublished = false;
        coordinator.EventsPublished += (_, _) => wasPublished = true;

        await coordinator.StartAsync(new CaptureSelection(new HashSet<ulong> { 0x1234 }, "failure.db"));
        await source.EmitAsync(CreateEvent(1));
        await WaitForConditionAsync(store.AppendAttempted, "the append attempt");

        await Assert.ThrowsAsync<InvalidOperationException>(() => coordinator.StopAsync());

        Assert.Equal(1, store.AppendCalls);
        Assert.False(wasPublished);
    }

    [Fact]
    public async Task ConcurrentDisposeAsyncDisposesSourceOnceAndRejectsLaterTransitions()
    {
        var source = new LifecycleCaptureSource();
        var store = new FailingSessionStore(shouldFailAppend: false);
        var coordinator = new CaptureCoordinator(source, Factory(store));
        var selection = new CaptureSelection(new HashSet<ulong> { 0x1234 }, "lifecycle.db");
        await coordinator.StartAsync(selection);

        Task firstDispose = coordinator.DisposeAsync().AsTask();
        await WaitForConditionAsync(
            source.StopConfigurationEntered,
            "the first dispose operation to enter stop configuration");
        Task secondDispose = coordinator.DisposeAsync().AsTask();

        source.ReleaseStopConfiguration();
        await Task.WhenAll(firstDispose, secondDispose);
        await coordinator.DisposeAsync();

        Assert.Equal(1, source.DisposeCalls);
        await Assert.ThrowsAsync<ObjectDisposedException>(() => coordinator.StartAsync(selection));
    }

    [Fact]
    public async Task StopAsyncRacingDisposeAsyncCompletesWithoutLifecycleFailure()
    {
        var source = new LifecycleCaptureSource();
        var store = new FailingSessionStore(shouldFailAppend: false);
        var coordinator = new CaptureCoordinator(source, Factory(store));
        await coordinator.StartAsync(
            new CaptureSelection(new HashSet<ulong> { 0x1234 }, "stop-dispose-race.db"));

        Task disposing = coordinator.DisposeAsync().AsTask();
        await WaitForConditionAsync(
            source.StopConfigurationEntered,
            "dispose to enter stop configuration");
        Task stopping = coordinator.StopAsync();

        source.ReleaseStopConfiguration();
        await Task.WhenAll(disposing, stopping);

        Assert.Equal(CaptureState.Stopped, coordinator.State);
        Assert.Equal(1, source.DisposeCalls);
    }

    private static CaptureEvent CreateEvent(long sequence) =>
        new(
            sequence,
            sequence * 10,
            0x1234,
            42,
            CaptureKind.Read,
            0,
            0,
            1,
            1,
            CaptureFlags.None,
            ImmutableArray.Create((byte)sequence))
        {
            PortName = "COM1",
            ProcessName = "test.exe",
            Timestamp = DateTimeOffset.UnixEpoch.AddTicks(sequence),
        };

    private static ISessionStoreFactory Factory(ISessionStore store) =>
        new SingleSessionStoreFactory(store);

    private static async Task WaitForConditionAsync(Task condition, string description)
    {
        try
        {
            await condition.WaitAsync(TestConditionWatchdog);
        }
        catch (TimeoutException exception)
        {
            throw new TimeoutException(
                $"The test watchdog expired while waiting for {description}.",
                exception);
        }
    }

    private sealed class TestSession : IAsyncDisposable
    {
        private readonly string _path = Path.Combine(
            Path.GetTempPath(),
            $"commmonitor-service-{Guid.NewGuid():N}.db");

        public SessionStore Store { get; }

        public CaptureSelection Selection => new(new HashSet<ulong> { 0x1234 }, _path);

        public TestSession()
        {
            Store = new SessionStore(_path);
        }

        public ValueTask DisposeAsync()
        {
            DeleteIfExists(_path);
            DeleteIfExists(_path + "-shm");
            DeleteIfExists(_path + "-wal");
            return ValueTask.CompletedTask;
        }

        private static void DeleteIfExists(string path)
        {
            if (File.Exists(path))
            {
                File.Delete(path);
            }
        }
    }

    private sealed class FailingSessionStore(bool shouldFailAppend = true) : ISessionStore
    {
        private readonly TaskCompletionSource _appendAttempted =
            new(TaskCreationOptions.RunContinuationsAsynchronously);
        private readonly List<CaptureRunRecord> _runs = [];

        public int AppendCalls { get; private set; }

        public Task AppendAttempted => _appendAttempted.Task;

        public Task InitializeAsync(CancellationToken cancellationToken = default) =>
            Task.CompletedTask;

        public Task<int> GetSchemaVersionAsync(CancellationToken cancellationToken = default) =>
            Task.FromResult(3);

        public Task<long> GetLastSequenceAsync(CancellationToken cancellationToken = default) =>
            Task.FromResult(0L);

        public Task<long> CountRunsAsync(CancellationToken cancellationToken = default) =>
            Task.FromResult((long)_runs.Count);

        public Task UpsertRunAsync(
            CaptureRunRecord run,
            CancellationToken cancellationToken = default)
        {
            int index = _runs.FindIndex(existing => existing.RunId == run.RunId);
            if (index < 0)
            {
                _runs.Add(run);
            }
            else
            {
                _runs[index] = run;
            }

            return Task.CompletedTask;
        }

        public Task<IReadOnlyList<CaptureRunRecord>> ReadRunsAsync(
            CancellationToken cancellationToken = default) =>
            Task.FromResult<IReadOnlyList<CaptureRunRecord>>(_runs.ToArray());

        public Task<IReadOnlyList<IntegrityMarker>> ReadMarkersAsync(
            string runId,
            CancellationToken cancellationToken = default) =>
            Task.FromResult<IReadOnlyList<IntegrityMarker>>([]);

        public Task<IReadOnlyList<CaptureEvent>> AppendBatchAsync(
            PersistBatch batch,
            CancellationToken cancellationToken = default)
        {
            if (batch.Events.Count == 0)
            {
                return Task.FromResult(batch.Events);
            }

            return AppendAsync(batch.Events, cancellationToken);
        }

        public Task<IReadOnlyList<CaptureEvent>> AppendAsync(
            IReadOnlyList<CaptureEvent> events,
            CancellationToken cancellationToken = default)
        {
            AppendCalls++;
            _appendAttempted.TrySetResult();
            return shouldFailAppend
                ? Task.FromException<IReadOnlyList<CaptureEvent>>(
                    new InvalidOperationException("Persistence failed."))
                : Task.FromResult(events);
        }

        public Task<IReadOnlyList<CaptureEvent>> ReadAfterAsync(
            long sequence,
            int limit,
            CancellationToken cancellationToken = default) =>
            throw new NotSupportedException();

        public Task ClearAsync(CancellationToken cancellationToken = default) =>
            throw new NotSupportedException();
    }

    private sealed class SynchronousInMemorySessionStore : ISessionStore
    {
        private readonly List<CaptureEvent> _events = [];
        private readonly List<IntegrityMarker> _markers = [];
        private readonly List<CaptureRunRecord> _runs = [];

        public Task InitializeAsync(CancellationToken cancellationToken = default) =>
            Task.CompletedTask;

        public Task<int> GetSchemaVersionAsync(CancellationToken cancellationToken = default) =>
            Task.FromResult(3);

        public Task<long> GetLastSequenceAsync(CancellationToken cancellationToken = default) =>
            Task.FromResult(_events.Count == 0 ? 0L : _events[^1].Sequence);

        public Task<long> CountRunsAsync(CancellationToken cancellationToken = default) =>
            Task.FromResult((long)_runs.Count);

        public Task UpsertRunAsync(
            CaptureRunRecord run,
            CancellationToken cancellationToken = default)
        {
            int index = _runs.FindIndex(existing => existing.RunId == run.RunId);
            if (index < 0)
            {
                _runs.Add(run);
            }
            else
            {
                _runs[index] = run;
            }

            return Task.CompletedTask;
        }

        public Task<IReadOnlyList<CaptureRunRecord>> ReadRunsAsync(
            CancellationToken cancellationToken = default) =>
            Task.FromResult<IReadOnlyList<CaptureRunRecord>>(_runs.ToArray());

        public Task<IReadOnlyList<IntegrityMarker>> ReadMarkersAsync(
            string runId,
            CancellationToken cancellationToken = default) =>
            Task.FromResult<IReadOnlyList<IntegrityMarker>>(
                _markers.Where(marker => marker.RunId == runId).ToArray());

        public Task<IReadOnlyList<CaptureEvent>> AppendBatchAsync(
            PersistBatch batch,
            CancellationToken cancellationToken = default)
        {
            _events.AddRange(batch.Events);
            _markers.AddRange(batch.Markers);
            return Task.FromResult(batch.Events);
        }

        public Task<IReadOnlyList<CaptureEvent>> AppendAsync(
            IReadOnlyList<CaptureEvent> events,
            CancellationToken cancellationToken = default) =>
            AppendBatchAsync(new PersistBatch(events, []), cancellationToken);

        public Task<IReadOnlyList<CaptureEvent>> ReadAfterAsync(
            long sequence,
            int limit,
            CancellationToken cancellationToken = default) =>
            Task.FromResult<IReadOnlyList<CaptureEvent>>(
                _events.Where(captureEvent => captureEvent.Sequence > sequence)
                    .Take(limit)
                    .ToArray());

        public Task ClearAsync(CancellationToken cancellationToken = default)
        {
            _events.Clear();
            _markers.Clear();
            _runs.Clear();
            return Task.CompletedTask;
        }
    }

    private sealed class SingleSessionStoreFactory(ISessionStore store) : ISessionStoreFactory
    {
        public ISessionStore Create(string path) => store;
    }

    private sealed class LifecycleCaptureSource : ICaptureSource
    {
        private readonly FakeCaptureSource _inner = new();
        private readonly TaskCompletionSource _stopConfigurationEntered =
            new(TaskCreationOptions.RunContinuationsAsynchronously);
        private readonly TaskCompletionSource _releaseStopConfiguration =
            new(TaskCreationOptions.RunContinuationsAsynchronously);
        private int _disposeCalls;

        public int DisposeCalls => Volatile.Read(ref _disposeCalls);

        public Task StopConfigurationEntered => _stopConfigurationEntered.Task;

        public async ValueTask ConfigureAsync(
            CaptureState state,
            IReadOnlySet<ulong> deviceIds,
            CancellationToken cancellationToken)
        {
            if (state == CaptureState.Stopped)
            {
                _stopConfigurationEntered.TrySetResult();
                await _releaseStopConfiguration.Task.WaitAsync(cancellationToken);
            }

            await _inner.ConfigureAsync(state, deviceIds, cancellationToken);
        }

        public IAsyncEnumerable<CaptureEvent> ReadAllAsync(CancellationToken cancellationToken) =>
            _inner.ReadAllAsync(cancellationToken);

        public async ValueTask DisposeAsync()
        {
            Interlocked.Increment(ref _disposeCalls);
            await _inner.DisposeAsync();
        }

        public void ReleaseStopConfiguration() => _releaseStopConfiguration.TrySetResult();
    }
}
