using System.Collections.Immutable;
using System.Threading.Channels;
using CommMonitor.Core.Models;
using CommMonitor.Core.Sessions;
using CommMonitor.Service.Capture;

namespace CommMonitor.Service.Tests.Capture;

public sealed class CaptureIntegrityTests
{
    private static readonly TimeSpan TestTimeout = TimeSpan.FromSeconds(2);

    [Fact]
    public async Task Start_and_stop_persist_snapshots_and_each_successful_start_advances_generation()
    {
        await using var session = new TestSession();
        var source = new StatisticsCaptureSource([
            Stats(CaptureState.Stopped, dropped: 10, sequence: 100, seconds: 0),
            Stats(CaptureState.Running, dropped: 12, sequence: 101, seconds: 1),
            Stats(CaptureState.Stopped, dropped: 12, sequence: 101, seconds: 2),
            Stats(CaptureState.Stopped, dropped: 12, sequence: 101, seconds: 3),
            Stats(CaptureState.Stopped, dropped: 12, sequence: 101, seconds: 4),
        ]);
        await using var coordinator = new CaptureCoordinator(source, Factory(session.Store));
        Channel<ImmutableArray<CaptureEvent>> committed = ObserveCommitted(coordinator);

        await coordinator.StartAsync(session.Selection("run-1", "session-1"));

        Assert.Equal(1, coordinator.Generation);
        Assert.Equal("run-1", coordinator.Snapshot.RunId);
        Assert.Equal("session-1", coordinator.Snapshot.SessionId);
        Assert.Equal(["stats", "configure:Running"], source.Operations.Take(2));

        await source.EmitAsync(CreateEvent(1));
        await committed.Reader.ReadAsync().AsTask().WaitAsync(TestTimeout);
        await coordinator.StopAsync();

        CaptureRunRecord first = Assert.Single(await session.Store.ReadRunsAsync());
        Assert.Equal(1, first.Generation);
        Assert.Equal("run-1", first.RunId);
        Assert.Equal("session-1", first.SessionId);
        Assert.Equal("AI", first.OwnerType);
        Assert.Equal("S-1-5-21-1", first.OwnerSid);
        Assert.Equal(10UL, first.StartStats.Dropped);
        Assert.Equal(12UL, first.EndStats?.Dropped);
        Assert.True(first.StatsKnown);
        Assert.True(first.CleanShutdown);
        Assert.Equal("STOPPED", first.EndReason);
        IntegrityMarker driverDrop = Assert.Single(await session.Store.ReadMarkersAsync("run-1"));
        Assert.Equal("DRIVER_DROPPED", driverDrop.MarkerType);
        Assert.Equal(2, driverDrop.CountDelta);
        Assert.Equal("DATA_GAP", driverDrop.Code);

        await coordinator.StartAsync(session.Selection("run-2", "session-1"));
        Assert.Equal(2, coordinator.Generation);
        await coordinator.StopAsync();

        IReadOnlyList<CaptureRunRecord> runs = await session.Store.ReadRunsAsync();
        Assert.Equal([1L, 2L], runs.Select(run => run.Generation));
    }

    [Fact]
    public async Task Counter_rollback_persists_SOURCE_RESTART_and_marks_the_run_incomplete()
    {
        await using var session = new TestSession();
        var source = new StatisticsCaptureSource([
            Stats(CaptureState.Stopped, dropped: 5, sequence: 100, seconds: 0),
            Stats(CaptureState.Running, dropped: 4, sequence: 1, seconds: 1),
            Stats(CaptureState.Stopped, dropped: 4, sequence: 1, seconds: 2),
        ]);
        await using var coordinator = new CaptureCoordinator(source, Factory(session.Store));
        Channel<ImmutableArray<CaptureEvent>> committed = ObserveCommitted(coordinator);

        await coordinator.StartAsync(session.Selection("restart-run", "restart-session"));
        await source.EmitAsync(CreateEvent(1));
        await committed.Reader.ReadAsync().AsTask().WaitAsync(TestTimeout);
        await coordinator.StopAsync();

        CaptureRunRecord run = Assert.Single(await session.Store.ReadRunsAsync());
        Assert.False(run.StatsKnown);
        Assert.False(run.CleanShutdown);
        Assert.Equal("SOURCE_RESTART", run.EndReason);
        IntegrityMarker marker = Assert.Single(await session.Store.ReadMarkersAsync(run.RunId));
        Assert.Equal("SOURCE_RESTART", marker.MarkerType);
        Assert.Equal("INTEGRITY_UNKNOWN", marker.Code);
    }

    [Fact]
    public async Task Truncated_events_are_counted_and_marked_in_the_same_committed_batch()
    {
        await using var session = new TestSession();
        var source = new StatisticsCaptureSource([
            Stats(CaptureState.Stopped, dropped: 0, sequence: 0, seconds: 0),
            Stats(CaptureState.Running, dropped: 0, sequence: 1, seconds: 1),
            Stats(CaptureState.Stopped, dropped: 0, sequence: 1, seconds: 2),
        ]);
        await using var coordinator = new CaptureCoordinator(source, Factory(session.Store));
        Channel<ImmutableArray<CaptureEvent>> committed = ObserveCommitted(coordinator);

        await coordinator.StartAsync(session.Selection("truncated-run", "truncated-session"));
        await source.EmitAsync(CreateEvent(1, CaptureFlags.Truncated));
        await committed.Reader.ReadAsync().AsTask().WaitAsync(TestTimeout);
        await coordinator.StopAsync();

        CaptureRunRecord run = Assert.Single(await session.Store.ReadRunsAsync());
        Assert.Equal(1, run.TruncationCount);
        IntegrityMarker marker = Assert.Single(await session.Store.ReadMarkersAsync(run.RunId));
        Assert.Equal("TRUNCATED", marker.MarkerType);
        Assert.Equal(1, marker.CountDelta);
        Assert.Equal("DATA_GAP", marker.Code);
    }

    [Fact]
    public async Task Start_reconciles_an_unfinished_run_as_interrupted_before_creating_a_new_run()
    {
        await using var session = new TestSession();
        await session.Store.InitializeAsync();
        DriverStatsSnapshot baseline = ToSnapshot(
            Stats(CaptureState.Running, dropped: 0, sequence: 8, seconds: 0));
        await session.Store.UpsertRunAsync(new CaptureRunRecord(
            "orphan-run",
            "session-1",
            41,
            "dead-service",
            "AI",
            "S-1-5-21-1",
            ["0000000000001234"],
            0,
            null,
            DateTimeOffset.UnixEpoch,
            null,
            baseline,
            null,
            0,
            0,
            true,
            false,
            null));
        var source = new StatisticsCaptureSource([
            Stats(CaptureState.Stopped, dropped: 0, sequence: 8, seconds: 1),
            Stats(CaptureState.Stopped, dropped: 0, sequence: 8, seconds: 2),
        ]);
        await using var coordinator = new CaptureCoordinator(source, Factory(session.Store));

        await coordinator.StartAsync(session.Selection("new-run", "session-1"));
        await coordinator.StopAsync();

        CaptureRunRecord interrupted = Assert.Single(
            (await session.Store.ReadRunsAsync()).Where(run => run.RunId == "orphan-run"));
        Assert.False(interrupted.CleanShutdown);
        Assert.False(interrupted.StatsKnown);
        Assert.NotNull(interrupted.StoppedUtc);
        Assert.Equal("INTERRUPTED", interrupted.EndReason);
        IntegrityMarker marker = Assert.Single(
            await session.Store.ReadMarkersAsync(interrupted.RunId));
        Assert.Equal("INTERRUPTED", marker.MarkerType);
        Assert.Equal("INTEGRITY_UNKNOWN", marker.Code);
    }

    [Fact]
    public async Task A_failed_event_batch_is_not_published_and_a_recovery_marker_is_persisted()
    {
        await using var session = new TestSession();
        var store = new FailFirstEventBatchStore(session.Store);
        var source = new FakeCaptureSource();
        await using var coordinator = new CaptureCoordinator(source, Factory(store));
        bool notified = false;
        coordinator.EventsCommitted += (_, _) => notified = true;

        await coordinator.StartAsync(session.Selection("failure-run", "failure-session"));
        await source.EmitAsync(CreateEvent(1, CaptureFlags.Truncated));
        await store.FailureObserved.WaitAsync(TestTimeout);

        await Assert.ThrowsAsync<InvalidOperationException>(() => coordinator.StopAsync());

        Assert.False(notified);
        Assert.Empty(await session.Store.ReadAfterAsync(0, 10));
        IReadOnlyList<IntegrityMarker> markers =
            await session.Store.ReadMarkersAsync("failure-run");
        Assert.Contains(markers, item => item.MarkerType == "STATS_UNAVAILABLE");
        IntegrityMarker marker = Assert.Single(
            markers.Where(item => item.MarkerType == "PERSISTENCE_FAILURE"));
        Assert.Equal("PERSISTENCE_FAILURE", marker.MarkerType);
        Assert.Equal(1, marker.CountDelta);
        Assert.Equal("DATA_GAP", marker.Code);
        CaptureRunRecord run = Assert.Single(await session.Store.ReadRunsAsync());
        Assert.Equal(1, run.ServiceDropped);
        Assert.False(run.CleanShutdown);
        Assert.Equal("PERSISTENCE_FAILURE", run.EndReason);
        Assert.All(markers, item => Assert.InRange(item.AfterSequence, 0, run.EndSequence ?? 0));
    }

    [Fact]
    public async Task Buffered_events_are_flushed_even_when_async_enumerator_cleanup_fails()
    {
        await using var session = new TestSession();
        var source = new CleanupFailingCaptureSource(CreateEvent(1));
        await using var coordinator = new CaptureCoordinator(source, Factory(session.Store));

        await coordinator.StartAsync(session.Selection("cleanup-run", "cleanup-session"));
        await source.EnumeratorDisposed.WaitAsync(TestTimeout);

        InvalidOperationException exception = await Assert.ThrowsAsync<InvalidOperationException>(
            () => coordinator.StopAsync());

        Assert.Contains("enumerator cleanup", exception.Message, StringComparison.OrdinalIgnoreCase);
        CaptureEvent stored = Assert.Single(await session.Store.ReadAfterAsync(0, 10));
        Assert.Equal(1, stored.WireSequence);
    }

    [Fact]
    public async Task A_pending_read_that_completes_during_stop_is_included_in_the_final_batch()
    {
        await using var session = new TestSession();
        var source = new CancellationCompletingCaptureSource(CreateEvent(1), CreateEvent(2));
        await using var coordinator = new CaptureCoordinator(source, Factory(session.Store));

        await coordinator.StartAsync(session.Selection("pending-run", "pending-session"));
        await source.PendingReadStarted.WaitAsync(TestTimeout);
        await coordinator.StopAsync();

        IReadOnlyList<CaptureEvent> stored = await session.Store.ReadAfterAsync(0, 10);
        Assert.Equal([1L, 2L], stored.Select(captureEvent => captureEvent.WireSequence));
    }

    [Fact]
    public async Task Interrupted_reconciliation_retries_when_the_marker_commit_fails()
    {
        await using var session = new TestSession();
        await session.Store.InitializeAsync();
        await session.Store.UpsertRunAsync(OpenRun("orphan-retry", "retry-session", 9));
        var store = new FailFirstMarkerBatchStore(session.Store);

        await using (var first = new CaptureCoordinator(
            new FakeCaptureSource(),
            Factory(store)))
        {
            await Assert.ThrowsAsync<InvalidOperationException>(() =>
                first.StartAsync(session.Selection("not-started", "retry-session")));
        }

        CaptureRunRecord stillOpen = Assert.Single(await session.Store.ReadRunsAsync());
        Assert.Null(stillOpen.StoppedUtc);

        await using (var retry = new CaptureCoordinator(
            new FakeCaptureSource(),
            Factory(store)))
        {
            await retry.StartAsync(session.Selection("retry-run", "retry-session"));
            await retry.StopAsync();
        }

        CaptureRunRecord reconciled = Assert.Single(
            (await session.Store.ReadRunsAsync()).Where(run => run.RunId == "orphan-retry"));
        Assert.Equal("INTERRUPTED", reconciled.EndReason);
        Assert.Single(
            (await session.Store.ReadMarkersAsync("orphan-retry"))
                .Where(marker => marker.MarkerType == "INTERRUPTED"));
    }

    [Fact]
    public async Task Failed_start_best_effort_disables_a_partially_applied_running_configuration()
    {
        await using var session = new TestSession();
        var source = new PartialStartFailureSource();
        await using var coordinator = new CaptureCoordinator(source, Factory(session.Store));

        await Assert.ThrowsAsync<InvalidOperationException>(() =>
            coordinator.StartAsync(session.Selection("failed-start", "failed-session")));

        Assert.True(source.RunningWasApplied);
        Assert.True(source.StopWasAttempted);
        Assert.Equal(CaptureState.Stopped, coordinator.State);
    }

    [Fact]
    public async Task Stop_can_retry_when_integrity_marker_persistence_temporarily_fails()
    {
        await using var session = new TestSession();
        var store = new FailFirstMarkerBatchStore(session.Store);
        var source = new FakeCaptureSource();
        await using var coordinator = new CaptureCoordinator(source, Factory(store));
        await coordinator.StartAsync(session.Selection("stop-retry", "stop-retry-session"));

        await Assert.ThrowsAsync<InvalidOperationException>(() => coordinator.StopAsync());

        Assert.NotEqual(CaptureState.Stopped, coordinator.State);
        CaptureRunRecord unfinished = Assert.Single(await session.Store.ReadRunsAsync());
        Assert.Null(unfinished.StoppedUtc);

        await coordinator.StopAsync();

        Assert.Equal(CaptureState.Stopped, coordinator.State);
        CaptureRunRecord completed = Assert.Single(await session.Store.ReadRunsAsync());
        Assert.NotNull(completed.StoppedUtc);
        Assert.False(completed.CleanShutdown);
        Assert.Equal("PERSISTENCE_FAILURE", completed.EndReason);
        Assert.Contains(
            await session.Store.ReadMarkersAsync(completed.RunId),
            marker => marker.MarkerType == "PERSISTENCE_FAILURE");
    }

    [Fact]
    public async Task Stop_can_retry_when_disabling_the_capture_source_temporarily_fails()
    {
        await using var session = new TestSession();
        var source = new RetryingStopCaptureSource();
        await using var coordinator = new CaptureCoordinator(source, Factory(session.Store));
        await coordinator.StartAsync(session.Selection("driver-stop-retry", "driver-session"));

        await Assert.ThrowsAsync<InvalidOperationException>(() => coordinator.StopAsync());

        Assert.Equal(CaptureState.Running, coordinator.State);
        Assert.Equal(1, source.StopAttempts);
        Assert.Null(Assert.Single(await session.Store.ReadRunsAsync()).StoppedUtc);

        await coordinator.StopAsync();

        Assert.Equal(CaptureState.Stopped, coordinator.State);
        Assert.Equal(2, source.StopAttempts);
        CaptureRunRecord completed = Assert.Single(await session.Store.ReadRunsAsync());
        Assert.Equal("STOP_FAILURE", completed.EndReason);
        Assert.Contains(
            await session.Store.ReadMarkersAsync(completed.RunId),
            marker => marker.MarkerType == "STOP_FAILURE");
    }

    [Fact]
    public async Task EventsCommitted_is_raised_only_after_the_store_commits_the_batch()
    {
        await using var session = new TestSession();
        var store = new CommitObservingStore(session.Store);
        var source = new FakeCaptureSource();
        await using var coordinator = new CaptureCoordinator(source, Factory(store));
        var notification = new TaskCompletionSource<bool>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        coordinator.EventsCommitted += (_, batch) =>
            notification.TrySetResult(store.CommitCompleted && batch.Length == 1);

        await coordinator.StartAsync(session.Selection("commit-run", "commit-session"));
        await source.EmitAsync(CreateEvent(1));

        Assert.True(await notification.Task.WaitAsync(TestTimeout));
        await coordinator.StopAsync();
    }

    private static Channel<ImmutableArray<CaptureEvent>> ObserveCommitted(
        CaptureCoordinator coordinator)
    {
        Channel<ImmutableArray<CaptureEvent>> channel =
            Channel.CreateUnbounded<ImmutableArray<CaptureEvent>>();
        coordinator.EventsCommitted += (_, batch) => channel.Writer.TryWrite(batch);
        return channel;
    }

    private static CaptureSourceStatistics Stats(
        CaptureState state,
        ulong dropped,
        ulong sequence,
        int seconds) =>
        new(
            true,
            0,
            state,
            dropped,
            sequence,
            DateTimeOffset.UnixEpoch.AddSeconds(seconds),
            null);

    private static DriverStatsSnapshot ToSnapshot(CaptureSourceStatistics statistics) =>
        new(
            statistics.StatsKnown,
            statistics.Queued,
            statistics.State,
            statistics.Dropped,
            statistics.Sequence,
            statistics.SampledAtUtc,
            statistics.UnavailableReason);

    private static CaptureRunRecord OpenRun(
        string runId,
        string sessionId,
        long generation)
    {
        DriverStatsSnapshot baseline = ToSnapshot(
            Stats(CaptureState.Running, dropped: 0, sequence: 8, seconds: 0));
        return new CaptureRunRecord(
            runId,
            sessionId,
            generation,
            "dead-service",
            "AI",
            "S-1-5-21-1",
            ["0000000000001234"],
            0,
            null,
            DateTimeOffset.UnixEpoch,
            null,
            baseline,
            null,
            0,
            0,
            true,
            false,
            null);
    }

    private static CaptureEvent CreateEvent(
        long sequence,
        CaptureFlags flags = CaptureFlags.None) =>
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
            flags,
            ImmutableArray.Create((byte)sequence))
        {
            PortName = "COM1",
            ProcessName = "test.exe",
            Timestamp = DateTimeOffset.UnixEpoch.AddTicks(sequence),
        };

    private static ISessionStoreFactory Factory(ISessionStore store) =>
        new SingleSessionStoreFactory(store);

    private sealed class TestSession : IAsyncDisposable
    {
        private readonly string _path = Path.Combine(
            Path.GetTempPath(),
            $"commmonitor-integrity-{Guid.NewGuid():N}.cmsession");

        public SessionStore Store { get; }

        public TestSession()
        {
            Store = new SessionStore(_path);
        }

        public CaptureSelection Selection(string runId, string sessionId) =>
            new(
                new HashSet<ulong> { 0x1234 },
                _path,
                runId,
                sessionId,
                "AI",
                "S-1-5-21-1");

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

    private sealed class StatisticsCaptureSource(
        IEnumerable<CaptureSourceStatistics> statistics)
        : ICaptureSource, ICaptureSourceStatisticsProvider
    {
        private readonly Channel<CaptureEvent> _events = Channel.CreateUnbounded<CaptureEvent>();
        private readonly Queue<CaptureSourceStatistics> _statistics = new(statistics);
        private CaptureSourceStatistics? _lastStatistics;

        public List<string> Operations { get; } = [];

        public ValueTask ConfigureAsync(
            CaptureState state,
            IReadOnlySet<ulong> deviceIds,
            CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            Operations.Add($"configure:{state}");
            return ValueTask.CompletedTask;
        }

        public IAsyncEnumerable<CaptureEvent> ReadAllAsync(CancellationToken cancellationToken) =>
            _events.Reader.ReadAllAsync(cancellationToken);

        public ValueTask<CaptureSourceStatistics> GetStatisticsAsync(
            CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            Operations.Add("stats");
            lock (_statistics)
            {
                if (_statistics.Count > 0)
                {
                    _lastStatistics = _statistics.Dequeue();
                }

                return ValueTask.FromResult(_lastStatistics ?? throw new InvalidOperationException(
                    "No scripted statistics are available."));
            }
        }

        public ValueTask EmitAsync(CaptureEvent captureEvent) =>
            _events.Writer.WriteAsync(captureEvent);

        public ValueTask DisposeAsync()
        {
            _events.Writer.TryComplete();
            return ValueTask.CompletedTask;
        }
    }

    private sealed class CleanupFailingCaptureSource(CaptureEvent captureEvent) : ICaptureSource
    {
        private readonly TaskCompletionSource _enumeratorDisposed =
            new(TaskCreationOptions.RunContinuationsAsynchronously);

        public Task EnumeratorDisposed => _enumeratorDisposed.Task;

        public ValueTask ConfigureAsync(
            CaptureState state,
            IReadOnlySet<ulong> deviceIds,
            CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            return ValueTask.CompletedTask;
        }

        public IAsyncEnumerable<CaptureEvent> ReadAllAsync(CancellationToken cancellationToken) =>
            new CleanupFailingEnumerable(captureEvent, _enumeratorDisposed);

        public ValueTask DisposeAsync() => ValueTask.CompletedTask;

        private sealed class CleanupFailingEnumerable(
            CaptureEvent captureEvent,
            TaskCompletionSource enumeratorDisposed)
            : IAsyncEnumerable<CaptureEvent>, IAsyncEnumerator<CaptureEvent>
        {
            private int _moveNextCalls;

            public CaptureEvent Current => captureEvent;

            public IAsyncEnumerator<CaptureEvent> GetAsyncEnumerator(
                CancellationToken cancellationToken = default) =>
                this;

            public ValueTask<bool> MoveNextAsync() =>
                ValueTask.FromResult(Interlocked.Increment(ref _moveNextCalls) == 1);

            public ValueTask DisposeAsync()
            {
                enumeratorDisposed.TrySetResult();
                return ValueTask.FromException(
                    new InvalidOperationException("Enumerator cleanup failed."));
            }
        }
    }

    private sealed class PartialStartFailureSource : ICaptureSource
    {
        public bool RunningWasApplied { get; private set; }
        public bool StopWasAttempted { get; private set; }

        public ValueTask ConfigureAsync(
            CaptureState state,
            IReadOnlySet<ulong> deviceIds,
            CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (state == CaptureState.Running)
            {
                RunningWasApplied = true;
                return ValueTask.FromException(
                    new InvalidOperationException("Start failed after applying Running."));
            }

            if (state == CaptureState.Stopped)
            {
                StopWasAttempted = true;
            }

            return ValueTask.CompletedTask;
        }

        public async IAsyncEnumerable<CaptureEvent> ReadAllAsync(
            [System.Runtime.CompilerServices.EnumeratorCancellation]
            CancellationToken cancellationToken)
        {
            await Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken);
            yield break;
        }

        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }

    private sealed class CancellationCompletingCaptureSource(
        CaptureEvent first,
        CaptureEvent second) : ICaptureSource
    {
        private readonly TaskCompletionSource _pendingReadStarted =
            new(TaskCreationOptions.RunContinuationsAsynchronously);

        public Task PendingReadStarted => _pendingReadStarted.Task;

        public ValueTask ConfigureAsync(
            CaptureState state,
            IReadOnlySet<ulong> deviceIds,
            CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            return ValueTask.CompletedTask;
        }

        public IAsyncEnumerable<CaptureEvent> ReadAllAsync(CancellationToken cancellationToken) =>
            new CancellationCompletingEnumerable(first, second, _pendingReadStarted);

        public ValueTask DisposeAsync() => ValueTask.CompletedTask;

        private sealed class CancellationCompletingEnumerable
            : IAsyncEnumerable<CaptureEvent>, IAsyncEnumerator<CaptureEvent>
        {
            private readonly CaptureEvent _first;
            private readonly CaptureEvent _second;
            private readonly TaskCompletionSource _pendingReadStarted;
            private CancellationToken _cancellationToken;
            private CaptureEvent _current;
            private int _moveNextCalls;

            public CancellationCompletingEnumerable(
                CaptureEvent first,
                CaptureEvent second,
                TaskCompletionSource pendingReadStarted)
            {
                _first = first;
                _second = second;
                _pendingReadStarted = pendingReadStarted;
                _current = first;
            }

            public CaptureEvent Current => _current;

            public IAsyncEnumerator<CaptureEvent> GetAsyncEnumerator(
                CancellationToken cancellationToken = default)
            {
                _cancellationToken = cancellationToken;
                return this;
            }

            public ValueTask<bool> MoveNextAsync()
            {
                int call = Interlocked.Increment(ref _moveNextCalls);
                if (call == 1)
                {
                    _current = _first;
                    return ValueTask.FromResult(true);
                }

                if (call > 2)
                {
                    return ValueTask.FromResult(false);
                }

                var completion = new TaskCompletionSource<bool>(
                    TaskCreationOptions.RunContinuationsAsynchronously);
                _pendingReadStarted.TrySetResult();
                _cancellationToken.Register(() =>
                {
                    _current = _second;
                    completion.TrySetResult(true);
                });
                return new ValueTask<bool>(completion.Task);
            }

            public ValueTask DisposeAsync() => ValueTask.CompletedTask;
        }
    }

    private sealed class RetryingStopCaptureSource : ICaptureSource
    {
        private readonly Channel<CaptureEvent> _events = Channel.CreateUnbounded<CaptureEvent>();

        public int StopAttempts { get; private set; }

        public ValueTask ConfigureAsync(
            CaptureState state,
            IReadOnlySet<ulong> deviceIds,
            CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (state == CaptureState.Stopped && ++StopAttempts == 1)
            {
                return ValueTask.FromException(
                    new InvalidOperationException("The driver did not stop."));
            }

            return ValueTask.CompletedTask;
        }

        public IAsyncEnumerable<CaptureEvent> ReadAllAsync(CancellationToken cancellationToken) =>
            _events.Reader.ReadAllAsync(cancellationToken);

        public ValueTask DisposeAsync()
        {
            _events.Writer.TryComplete();
            return ValueTask.CompletedTask;
        }
    }

    private sealed class SingleSessionStoreFactory(ISessionStore store) : ISessionStoreFactory
    {
        public ISessionStore Create(string path) => store;
    }

    private abstract class DelegatingSessionStore(ISessionStore inner) : ISessionStore
    {
        protected ISessionStore Inner { get; } = inner;

        public Task InitializeAsync(CancellationToken cancellationToken = default) =>
            Inner.InitializeAsync(cancellationToken);

        public Task<int> GetSchemaVersionAsync(CancellationToken cancellationToken = default) =>
            Inner.GetSchemaVersionAsync(cancellationToken);

        public Task<long> GetLastSequenceAsync(CancellationToken cancellationToken = default) =>
            Inner.GetLastSequenceAsync(cancellationToken);

        public Task<long> CountRunsAsync(CancellationToken cancellationToken = default) =>
            Inner.CountRunsAsync(cancellationToken);

        public Task UpsertRunAsync(
            CaptureRunRecord run,
            CancellationToken cancellationToken = default) =>
            Inner.UpsertRunAsync(run, cancellationToken);

        public Task<IReadOnlyList<CaptureRunRecord>> ReadRunsAsync(
            CancellationToken cancellationToken = default) =>
            Inner.ReadRunsAsync(cancellationToken);

        public Task<IReadOnlyList<IntegrityMarker>> ReadMarkersAsync(
            string runId,
            CancellationToken cancellationToken = default) =>
            Inner.ReadMarkersAsync(runId, cancellationToken);

        public virtual Task<IReadOnlyList<CaptureEvent>> AppendBatchAsync(
            PersistBatch batch,
            CancellationToken cancellationToken = default) =>
            Inner.AppendBatchAsync(batch, cancellationToken);

        public Task<IReadOnlyList<CaptureEvent>> AppendAsync(
            IReadOnlyList<CaptureEvent> events,
            CancellationToken cancellationToken = default) =>
            Inner.AppendAsync(events, cancellationToken);

        public Task<IReadOnlyList<CaptureEvent>> ReadAfterAsync(
            long sequence,
            int limit,
            CancellationToken cancellationToken = default) =>
            Inner.ReadAfterAsync(sequence, limit, cancellationToken);

        public Task ClearAsync(CancellationToken cancellationToken = default) =>
            Inner.ClearAsync(cancellationToken);
    }

    private sealed class FailFirstEventBatchStore(ISessionStore inner)
        : DelegatingSessionStore(inner)
    {
        private readonly TaskCompletionSource _failureObserved =
            new(TaskCreationOptions.RunContinuationsAsynchronously);
        private int _failed;

        public Task FailureObserved => _failureObserved.Task;

        public override Task<IReadOnlyList<CaptureEvent>> AppendBatchAsync(
            PersistBatch batch,
            CancellationToken cancellationToken = default)
        {
            if (batch.Events.Count > 0 && Interlocked.Exchange(ref _failed, 1) == 0)
            {
                _failureObserved.TrySetResult();
                return Task.FromException<IReadOnlyList<CaptureEvent>>(
                    new InvalidOperationException("Persistence failed."));
            }

            return base.AppendBatchAsync(batch, cancellationToken);
        }
    }

    private sealed class FailFirstMarkerBatchStore(ISessionStore inner)
        : DelegatingSessionStore(inner)
    {
        private int _failed;

        public override Task<IReadOnlyList<CaptureEvent>> AppendBatchAsync(
            PersistBatch batch,
            CancellationToken cancellationToken = default)
        {
            if (batch.Events.Count == 0 &&
                batch.Markers.Count > 0 &&
                Interlocked.Exchange(ref _failed, 1) == 0)
            {
                return Task.FromException<IReadOnlyList<CaptureEvent>>(
                    new InvalidOperationException("Marker persistence failed."));
            }

            return base.AppendBatchAsync(batch, cancellationToken);
        }
    }

    private sealed class CommitObservingStore(ISessionStore inner) : DelegatingSessionStore(inner)
    {
        public bool CommitCompleted { get; private set; }

        public override async Task<IReadOnlyList<CaptureEvent>> AppendBatchAsync(
            PersistBatch batch,
            CancellationToken cancellationToken = default)
        {
            IReadOnlyList<CaptureEvent> events =
                await base.AppendBatchAsync(batch, cancellationToken);
            CommitCompleted = true;
            return events;
        }
    }
}
