using System.Collections.Immutable;
using System.Diagnostics;
using System.Globalization;
using System.Runtime.ExceptionServices;
using CommMonitor.Core.Export;
using CommMonitor.Core.Models;
using CommMonitor.Core.Sessions;

namespace CommMonitor.Service.Capture;

public sealed class CaptureCoordinator : IAsyncDisposable
{
    private const int MaximumBatchSize = 64;
    private static readonly TimeSpan MaximumBatchDelay = TimeSpan.FromMilliseconds(50);
    private static readonly TimeSpan StatisticsSampleInterval = TimeSpan.FromSeconds(1);

    private readonly ICaptureSource _source;
    private readonly ICaptureSourceStatisticsProvider? _statisticsProvider;
    private readonly ISessionStoreFactory _sessionStoreFactory;
    private readonly SemaphoreSlim _transitionGate = new(1, 1);
    private readonly string _serviceInstanceId = Guid.NewGuid().ToString("N");
    private readonly List<IntegrityMarker> _pendingRecoveryMarkers = [];

    private ISessionStore? _sessionStore;
    private CancellationTokenSource? _readerCancellation;
    private Task? _readerTask;
    private IReadOnlySet<ulong> _deviceIds = new HashSet<ulong>();
    private CaptureRunRecord? _activeRun;
    private CaptureSourceStatistics _lastStatistics;
    private CaptureSnapshot _snapshot;
    private long _generation;
    private long _lastCommittedSequence;
    private ulong _driverDropped;
    private long _serviceDropped;
    private long _truncationCount;
    private bool _runStatsKnown;
    private bool _sourceRestartSeen;
    private bool _stopFailureSeen;
    private bool _persistenceFailureSeen;
    private bool _disposed;

    public CaptureCoordinator(ICaptureSource source, ISessionStoreFactory sessionStoreFactory)
    {
        _source = source ?? throw new ArgumentNullException(nameof(source));
        _statisticsProvider = source as ICaptureSourceStatisticsProvider;
        _sessionStoreFactory = sessionStoreFactory ??
            throw new ArgumentNullException(nameof(sessionStoreFactory));
        _lastStatistics = CaptureSourceStatistics.Unknown(
            "Capture source statistics have not been sampled.",
            DateTimeOffset.UtcNow);
        _snapshot = CreateSnapshot(
            CaptureState.Stopped,
            generation: 0,
            run: null,
            lastCommittedSequence: 0,
            statistics: _lastStatistics,
            driverDropped: 0,
            serviceDropped: 0,
            truncationCount: 0,
            statsKnown: false,
            cleanShutdown: true,
            endReason: null);
    }

    public event EventHandler<ImmutableArray<CaptureEvent>>? EventsCommitted;

    public event EventHandler<ImmutableArray<CaptureEvent>>? EventsPublished;

    public CaptureState State { get; private set; } = CaptureState.Stopped;

    public long Generation => Interlocked.Read(ref _generation);

    public CaptureSnapshot Snapshot => Volatile.Read(ref _snapshot);

    public async Task StartAsync(
        CaptureSelection selection,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(selection);
        ArgumentNullException.ThrowIfNull(selection.DeviceIds);
        ArgumentException.ThrowIfNullOrWhiteSpace(selection.SessionPath);
        ArgumentException.ThrowIfNullOrWhiteSpace(selection.OwnerType);
        ArgumentException.ThrowIfNullOrWhiteSpace(selection.OwnerSid);

        await _transitionGate.WaitAsync(cancellationToken);
        try
        {
            ThrowIfDisposed();
            EnsureState(CaptureState.Stopped, "Capture can only be started while stopped.");

            ISessionStore sessionStore = _sessionStoreFactory.Create(selection.SessionPath);
            await sessionStore.InitializeAsync(cancellationToken);
            long startAfterSequence = await sessionStore.GetLastSequenceAsync(cancellationToken);
            await ReconcileInterruptedRunsAsync(
                sessionStore,
                startAfterSequence,
                cancellationToken);

            CaptureSourceStatistics baseline = await SampleSourceStatisticsAsync(
                cancellationToken);
            long generation = Interlocked.Increment(ref _generation);
            string runId = string.IsNullOrWhiteSpace(selection.RunId)
                ? Guid.NewGuid().ToString("N")
                : selection.RunId.Trim();
            string sessionId = string.IsNullOrWhiteSpace(selection.SessionId)
                ? Path.GetFileName(selection.SessionPath)
                : selection.SessionId.Trim();
            ArgumentException.ThrowIfNullOrWhiteSpace(sessionId);

            var run = new CaptureRunRecord(
                runId,
                sessionId,
                generation,
                _serviceInstanceId,
                selection.OwnerType.Trim(),
                selection.OwnerSid.Trim(),
                selection.DeviceIds
                    .Order()
                    .Select(deviceId => deviceId.ToString("X16", CultureInfo.InvariantCulture))
                    .ToArray(),
                startAfterSequence,
                null,
                baseline.SampledAtUtc,
                null,
                ToDriverStatsSnapshot(baseline),
                null,
                0,
                0,
                baseline.StatsKnown,
                false,
                null);

            await sessionStore.UpsertRunAsync(run, cancellationToken);

            _sessionStore = sessionStore;
            _deviceIds = selection.DeviceIds.ToHashSet();
            _activeRun = run;
            _lastCommittedSequence = startAfterSequence;
            _lastStatistics = baseline;
            _driverDropped = 0;
            _serviceDropped = 0;
            _truncationCount = 0;
            _runStatsKnown = baseline.StatsKnown;
            _sourceRestartSeen = false;
            _stopFailureSeen = false;
            _persistenceFailureSeen = false;
            _pendingRecoveryMarkers.Clear();
            if (!baseline.StatsKnown)
            {
                _pendingRecoveryMarkers.Add(CreateMarker(
                    run,
                    "STATS_UNAVAILABLE",
                    baseline.SampledAtUtc,
                    startAfterSequence,
                    0,
                    "INTEGRITY_UNKNOWN"));
            }

            UpdateSnapshot(cleanShutdown: false, endReason: null);

            try
            {
                await _source.ConfigureAsync(
                    CaptureState.Running,
                    selection.DeviceIds,
                    cancellationToken);
            }
            catch (Exception startException)
            {
                try
                {
                    await _source.ConfigureAsync(
                        CaptureState.Stopped,
                        selection.DeviceIds,
                        CancellationToken.None);
                }
                catch
                {
                    // Preserve the start failure while making a best-effort rollback.
                }

                await RecordFailedStartAsync(sessionStore);
                ExceptionDispatchInfo.Capture(startException).Throw();
                throw;
            }

            _readerCancellation = new CancellationTokenSource();
            State = CaptureState.Running;
            UpdateSnapshot(cleanShutdown: false, endReason: null);
            _readerTask = ReadLoopAsync(_readerCancellation, sessionStore);
        }
        finally
        {
            _transitionGate.Release();
        }
    }

    public async Task PauseAsync(CancellationToken cancellationToken = default)
    {
        await _transitionGate.WaitAsync(cancellationToken);
        try
        {
            ThrowIfDisposed();
            EnsureState(CaptureState.Running, "Capture can only be paused while running.");

            await _source.ConfigureAsync(CaptureState.Paused, _deviceIds, cancellationToken);
            State = CaptureState.Paused;
            UpdateSnapshot(cleanShutdown: false, endReason: null);
        }
        finally
        {
            _transitionGate.Release();
        }
    }

    public async Task ResumeAsync(CancellationToken cancellationToken = default)
    {
        await _transitionGate.WaitAsync(cancellationToken);
        try
        {
            ThrowIfDisposed();
            EnsureState(CaptureState.Paused, "Capture can only be resumed while paused.");

            await _source.ConfigureAsync(CaptureState.Running, _deviceIds, cancellationToken);
            State = CaptureState.Running;
            UpdateSnapshot(cleanShutdown: false, endReason: null);
        }
        finally
        {
            _transitionGate.Release();
        }
    }

    public async Task StopAsync(CancellationToken cancellationToken = default)
    {
        await _transitionGate.WaitAsync(cancellationToken);
        try
        {
            if (_disposed)
            {
                return;
            }

            await StopCoreAsync(cancellationToken);
        }
        finally
        {
            _transitionGate.Release();
        }
    }

    public async Task ClearAsync(CancellationToken cancellationToken = default)
    {
        await _transitionGate.WaitAsync(cancellationToken);
        try
        {
            ThrowIfDisposed();
            EnsureState(CaptureState.Stopped, "Capture can only be cleared while stopped.");

            if (_sessionStore is not null)
            {
                await _sessionStore.InitializeAsync(cancellationToken);
                await _sessionStore.ClearAsync(cancellationToken);
                _activeRun = null;
                _lastCommittedSequence = 0;
                _driverDropped = 0;
                _serviceDropped = 0;
                _truncationCount = 0;
                _runStatsKnown = false;
                _pendingRecoveryMarkers.Clear();
                UpdateSnapshot(cleanShutdown: true, endReason: null);
            }
        }
        finally
        {
            _transitionGate.Release();
        }
    }

    public async Task ExportAsync(
        Stream destination,
        string format,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(destination);
        ArgumentException.ThrowIfNullOrWhiteSpace(format);

        ICaptureExporter exporter = format.Trim().ToLowerInvariant() switch
        {
            "csv" => new CsvCaptureExporter(),
            "txt" or "text" => new TextCaptureExporter(),
            "raw" or "bin" => new RawCaptureExporter(),
            _ => throw new ArgumentException(
                "Export format must be csv, txt, or raw.",
                nameof(format)),
        };

        await _transitionGate.WaitAsync(cancellationToken);
        try
        {
            ThrowIfDisposed();
            EnsureState(CaptureState.Stopped, "Capture must be stopped before export.");
            ISessionStore sessionStore = _sessionStore ??
                throw new InvalidOperationException("No capture session has been started.");
            await sessionStore.InitializeAsync(cancellationToken);

            var events = new List<CaptureEvent>();
            long cursor = 0;
            while (true)
            {
                IReadOnlyList<CaptureEvent> page = await sessionStore.ReadAfterAsync(
                    cursor,
                    10_000,
                    cancellationToken);
                if (page.Count == 0)
                {
                    break;
                }

                long nextCursor = page[^1].Sequence;
                if (nextCursor <= cursor)
                {
                    throw new InvalidDataException(
                        "The session store returned a non-increasing sequence.");
                }

                events.AddRange(page);
                cursor = nextCursor;
            }

            await exporter.ExportAsync(destination, events, cancellationToken);
        }
        finally
        {
            _transitionGate.Release();
        }
    }

    public async ValueTask DisposeAsync()
    {
        await _transitionGate.WaitAsync();
        try
        {
            if (_disposed)
            {
                return;
            }

            _disposed = true;
            try
            {
                await StopCoreAsync(CancellationToken.None);
            }
            finally
            {
                await _source.DisposeAsync();
            }
        }
        finally
        {
            _transitionGate.Release();
        }
    }

    private async Task StopCoreAsync(CancellationToken cancellationToken)
    {
        if (State == CaptureState.Stopped)
        {
            return;
        }

        CaptureState stateBeforeStop = State;
        Exception? readerFailure = null;
        Exception? completionFailure = null;
        CancellationTokenSource? readerCancellation = _readerCancellation;
        Task? readerTask = _readerTask;
        if (readerCancellation is not null && readerTask is not null)
        {
            readerCancellation.Cancel();

            try
            {
                await readerTask;
            }
            catch (OperationCanceledException) when (readerCancellation.IsCancellationRequested)
            {
            }
            catch (Exception exception)
            {
                readerFailure = exception;
            }
            finally
            {
                readerCancellation.Dispose();
                _readerCancellation = null;
                _readerTask = null;
            }
        }

        try
        {
            await _source.ConfigureAsync(CaptureState.Stopped, _deviceIds, cancellationToken);
        }
        catch (Exception exception)
        {
            _stopFailureSeen = true;
            _runStatsKnown = false;
            EnsurePendingMarker(
                "STOP_FAILURE",
                DateTimeOffset.UtcNow,
                _lastCommittedSequence,
                0,
                "INTEGRITY_UNKNOWN");
            completionFailure = exception;
        }

        CaptureSourceStatistics endStatistics = await SampleSourceStatisticsAsync(
            CancellationToken.None);
        CollectStatisticsMarkers(endStatistics, _lastCommittedSequence);

        if (readerFailure is not null &&
            _serviceDropped == 0 &&
            !_sourceRestartSeen &&
            !_stopFailureSeen)
        {
            _runStatsKnown = false;
            EnsurePendingMarker(
                "INTERRUPTED",
                DateTimeOffset.UtcNow,
                _lastCommittedSequence,
                0,
                "INTEGRITY_UNKNOWN");
        }

        if (_pendingRecoveryMarkers.Count > 0)
        {
            try
            {
                await PersistPendingMarkersAsync();
            }
            catch (Exception exception)
            {
                _persistenceFailureSeen = true;
                ReanchorPendingMarkers(_lastCommittedSequence);
                EnsurePendingMarker(
                    "PERSISTENCE_FAILURE",
                    DateTimeOffset.UtcNow,
                    _lastCommittedSequence,
                    0,
                    "INTEGRITY_UNKNOWN");
                completionFailure ??= exception;
            }
        }

        string endReason = GetEndReason(readerFailure);
        bool cleanShutdown = endReason == "STOPPED";

        if (completionFailure is null)
        {
            try
            {
                await FinalizeActiveRunAsync(
                    endStatistics,
                    cleanShutdown,
                    endReason,
                    CancellationToken.None);
            }
            catch (Exception exception)
            {
                _persistenceFailureSeen = true;
                cleanShutdown = false;
                endReason = "PERSISTENCE_FAILURE";
                EnsurePendingMarker(
                    "PERSISTENCE_FAILURE",
                    DateTimeOffset.UtcNow,
                    _lastCommittedSequence,
                    0,
                    "INTEGRITY_UNKNOWN");
                completionFailure = exception;
            }
        }

        if (completionFailure is null)
        {
            State = CaptureState.Stopped;
            UpdateSnapshot(cleanShutdown, endReason);
            _activeRun = null;
        }
        else
        {
            State = stateBeforeStop;
            UpdateSnapshot(cleanShutdown: false, endReason);
        }

        Exception? failure = completionFailure ?? readerFailure;
        if (failure is not null)
        {
            ExceptionDispatchInfo.Capture(failure).Throw();
        }
    }

    private async Task ReadLoopAsync(
        CancellationTokenSource readerCancellation,
        ISessionStore sessionStore)
    {
        var batch = new List<CaptureEvent>(MaximumBatchSize);
        CancellationToken cancellationToken = readerCancellation.Token;
        IAsyncEnumerator<CaptureEvent> enumerator = _source
            .ReadAllAsync(cancellationToken)
            .GetAsyncEnumerator(cancellationToken);
        Task<bool>? pendingRead = null;
        Task statisticsDelay = Task.Delay(StatisticsSampleInterval, cancellationToken);
        Exception? loopFailure = null;

        try
        {
            long batchStarted = 0;

            while (true)
            {
                pendingRead ??= enumerator.MoveNextAsync().AsTask();

                if (batch.Count == 0)
                {
                    Task completed = await Task.WhenAny(pendingRead, statisticsDelay);
                    if (completed == statisticsDelay)
                    {
                        await statisticsDelay;
                        await SampleAndPersistMarkersAsync(sessionStore, cancellationToken);
                        statisticsDelay = Task.Delay(
                            StatisticsSampleInterval,
                            cancellationToken);
                        continue;
                    }

                    Task<bool> read = pendingRead;
                    pendingRead = null;
                    if (!await read)
                    {
                        break;
                    }

                    batch.Add(enumerator.Current);
                    batchStarted = Stopwatch.GetTimestamp();
                    continue;
                }

                TimeSpan remaining = MaximumBatchDelay - Stopwatch.GetElapsedTime(batchStarted);
                if (remaining <= TimeSpan.Zero)
                {
                    await PersistAndPublishAsync(batch, sessionStore);
                    statisticsDelay = Task.Delay(StatisticsSampleInterval, cancellationToken);
                    continue;
                }

                Task timeout = Task.Delay(remaining, cancellationToken);
                Task completedReadOrTimeout = await Task.WhenAny(pendingRead, timeout);
                if (completedReadOrTimeout == timeout)
                {
                    await timeout;
                    await PersistAndPublishAsync(batch, sessionStore);
                    statisticsDelay = Task.Delay(StatisticsSampleInterval, cancellationToken);
                    continue;
                }

                Task<bool> completedRead = pendingRead;
                pendingRead = null;
                if (!await completedRead)
                {
                    break;
                }

                batch.Add(enumerator.Current);
                if (batch.Count == MaximumBatchSize)
                {
                    await PersistAndPublishAsync(batch, sessionStore);
                    statisticsDelay = Task.Delay(StatisticsSampleInterval, cancellationToken);
                }
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
        }
        catch (Exception exception)
        {
            loopFailure = exception;
        }
        finally
        {
            readerCancellation.Cancel();
            if (pendingRead is not null)
            {
                try
                {
                    if (await pendingRead)
                    {
                        batch.Add(enumerator.Current);
                    }
                }
                catch (OperationCanceledException) when (readerCancellation.IsCancellationRequested)
                {
                }
                catch (Exception exception)
                {
                    loopFailure ??= exception;
                }
            }

            try
            {
                await enumerator.DisposeAsync();
            }
            catch (Exception exception)
            {
                loopFailure ??= exception;
            }

            if (batch.Count > 0)
            {
                try
                {
                    await PersistAndPublishAsync(batch, sessionStore);
                }
                catch (Exception exception)
                {
                    loopFailure ??= exception;
                }
            }
        }

        if (loopFailure is not null)
        {
            ExceptionDispatchInfo.Capture(loopFailure).Throw();
        }
    }

    private async Task PersistAndPublishAsync(
        List<CaptureEvent> batch,
        ISessionStore sessionStore)
    {
        int eventCount = batch.Count;
        long projectedLastSequence = checked(_lastCommittedSequence + eventCount);
        CaptureSourceStatistics statistics = await SampleSourceStatisticsAsync(
            CancellationToken.None);
        CollectStatisticsMarkers(statistics, projectedLastSequence);

        long truncated = batch.LongCount(
            captureEvent => captureEvent.Flags.HasFlag(CaptureFlags.Truncated));
        if (truncated > 0)
        {
            _truncationCount = SaturatingAdd(_truncationCount, truncated);
            AddPendingMarker(
                "TRUNCATED",
                DateTimeOffset.UtcNow,
                projectedLastSequence,
                truncated,
                "DATA_GAP");
        }

        ImmutableArray<CaptureEvent> events = batch.ToImmutableArray();
        IntegrityMarker[] markers = _pendingRecoveryMarkers.ToArray();

        IReadOnlyList<CaptureEvent> persistedBatch;
        try
        {
            persistedBatch = await sessionStore.AppendBatchAsync(
                new PersistBatch(events, markers),
                CancellationToken.None);
        }
        catch
        {
            _serviceDropped = SaturatingAdd(_serviceDropped, eventCount);
            _persistenceFailureSeen = true;
            ReanchorPendingMarkers(_lastCommittedSequence);
            EnsurePendingMarker(
                "PERSISTENCE_FAILURE",
                DateTimeOffset.UtcNow,
                _lastCommittedSequence,
                eventCount,
                "DATA_GAP");
            batch.Clear();
            UpdateSnapshot(cleanShutdown: false, endReason: "PERSISTENCE_FAILURE");
            throw;
        }

        _pendingRecoveryMarkers.Clear();
        ImmutableArray<CaptureEvent> committedBatch = persistedBatch.ToImmutableArray();
        batch.Clear();
        if (!committedBatch.IsEmpty)
        {
            _lastCommittedSequence = committedBatch[^1].Sequence;
        }

        UpdateSnapshot(cleanShutdown: false, endReason: null);
        EventsCommitted?.Invoke(this, committedBatch);
        EventsPublished?.Invoke(this, committedBatch);
    }

    private async Task SampleAndPersistMarkersAsync(
        ISessionStore sessionStore,
        CancellationToken cancellationToken)
    {
        CaptureSourceStatistics statistics = await SampleSourceStatisticsAsync(
            cancellationToken);
        int markerCount = _pendingRecoveryMarkers.Count;
        CollectStatisticsMarkers(statistics, _lastCommittedSequence);
        if (_pendingRecoveryMarkers.Count == markerCount)
        {
            return;
        }

        await PersistPendingMarkersAsync();
    }

    private async Task PersistPendingMarkersAsync()
    {
        if (_pendingRecoveryMarkers.Count == 0)
        {
            return;
        }

        ISessionStore sessionStore = _sessionStore ??
            throw new InvalidOperationException("No capture session is active.");
        IntegrityMarker[] markers = _pendingRecoveryMarkers.ToArray();
        await sessionStore.AppendBatchAsync(
            new PersistBatch([], markers),
            CancellationToken.None);
        _pendingRecoveryMarkers.Clear();
    }

    private async Task<CaptureSourceStatistics> SampleSourceStatisticsAsync(
        CancellationToken cancellationToken)
    {
        if (_statisticsProvider is null)
        {
            return CaptureSourceStatistics.Unknown(
                "The capture source does not provide driver statistics.",
                DateTimeOffset.UtcNow);
        }

        try
        {
            CaptureSourceStatistics statistics = await _statisticsProvider
                .GetStatisticsAsync(cancellationToken);
            if (statistics.StatsKnown && !Enum.IsDefined(statistics.State))
            {
                return CaptureSourceStatistics.Unknown(
                    $"The capture source returned undefined state {(uint)statistics.State}.",
                    DateTimeOffset.UtcNow);
            }

            return statistics;
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception exception)
        {
            return CaptureSourceStatistics.Unknown(
                $"Driver statistics are unavailable: {exception.Message}",
                DateTimeOffset.UtcNow);
        }
    }

    private void CollectStatisticsMarkers(
        CaptureSourceStatistics current,
        long afterSequence)
    {
        CaptureSourceStatistics previous = _lastStatistics;
        _lastStatistics = current;

        if (!current.StatsKnown)
        {
            if (previous.StatsKnown)
            {
                AddPendingMarker(
                    "STATS_UNAVAILABLE",
                    current.SampledAtUtc,
                    afterSequence,
                    0,
                    "INTEGRITY_UNKNOWN");
            }

            _runStatsKnown = false;
            UpdateSnapshot(cleanShutdown: false, endReason: null);
            return;
        }

        if (!previous.StatsKnown)
        {
            UpdateSnapshot(cleanShutdown: false, endReason: null);
            return;
        }

        if (current.Dropped < previous.Dropped || current.Sequence < previous.Sequence)
        {
            _sourceRestartSeen = true;
            _runStatsKnown = false;
            AddPendingMarker(
                "SOURCE_RESTART",
                current.SampledAtUtc,
                afterSequence,
                0,
                "INTEGRITY_UNKNOWN");
            UpdateSnapshot(cleanShutdown: false, endReason: "SOURCE_RESTART");
            return;
        }

        ulong droppedDelta = current.Dropped - previous.Dropped;
        if (droppedDelta > 0)
        {
            _driverDropped = SaturatingAdd(_driverDropped, droppedDelta);
            AddPendingMarker(
                "DRIVER_DROPPED",
                current.SampledAtUtc,
                afterSequence,
                ToMarkerCount(droppedDelta),
                "DATA_GAP");
        }

        UpdateSnapshot(cleanShutdown: false, endReason: null);
    }

    private async Task ReconcileInterruptedRunsAsync(
        ISessionStore sessionStore,
        long lastSequence,
        CancellationToken cancellationToken)
    {
        IReadOnlyList<CaptureRunRecord> runs = await sessionStore.ReadRunsAsync(
            cancellationToken);
        CaptureRunRecord[] interrupted = runs
            .Where(run => !run.CleanShutdown && run.StoppedUtc is null)
            .ToArray();
        if (interrupted.Length == 0)
        {
            return;
        }

        DateTimeOffset occurredUtc = DateTimeOffset.UtcNow;
        var markers = new List<IntegrityMarker>(interrupted.Length);
        var reconciledRuns = new List<CaptureRunRecord>(interrupted.Length);
        foreach (CaptureRunRecord run in interrupted)
        {
            long endSequence = Math.Max(lastSequence, run.StartAfterSequence);
            CaptureRunRecord reconciled = run with
            {
                EndSequence = endSequence,
                StoppedUtc = occurredUtc,
                StatsKnown = false,
                CleanShutdown = false,
                EndReason = "INTERRUPTED",
            };
            reconciledRuns.Add(reconciled);

            IReadOnlyList<IntegrityMarker> existingMarkers =
                await sessionStore.ReadMarkersAsync(run.RunId, cancellationToken);
            if (!existingMarkers.Any(marker =>
                    marker.Generation == run.Generation &&
                    marker.MarkerType == "INTERRUPTED"))
            {
                markers.Add(CreateMarker(
                    run,
                    "INTERRUPTED",
                    occurredUtc,
                    endSequence,
                    0,
                    "INTEGRITY_UNKNOWN"));
            }
        }

        if (markers.Count > 0)
        {
            await sessionStore.AppendBatchAsync(
                new PersistBatch([], markers),
                cancellationToken);
        }

        foreach (CaptureRunRecord run in reconciledRuns)
        {
            await sessionStore.UpsertRunAsync(run, cancellationToken);
        }
    }

    private async Task RecordFailedStartAsync(ISessionStore sessionStore)
    {
        CaptureRunRecord? run = _activeRun;
        if (run is null)
        {
            return;
        }

        DateTimeOffset stoppedUtc = DateTimeOffset.UtcNow;
        _runStatsKnown = false;
        AddPendingMarker(
            "START_FAILED",
            stoppedUtc,
            _lastCommittedSequence,
            0,
            "INTEGRITY_UNKNOWN");
        try
        {
            await PersistPendingMarkersAsync();
            await sessionStore.UpsertRunAsync(run with
            {
                EndSequence = _lastCommittedSequence,
                StoppedUtc = stoppedUtc,
                EndStats = ToDriverStatsSnapshot(_lastStatistics),
                StatsKnown = false,
                CleanShutdown = false,
                EndReason = "START_FAILED",
            });
        }
        catch
        {
            // Preserve the driver/configuration failure that prevented capture start.
        }
        finally
        {
            State = CaptureState.Stopped;
            UpdateSnapshot(cleanShutdown: false, endReason: "START_FAILED");
            _activeRun = null;
        }

    }

    private async Task FinalizeActiveRunAsync(
        CaptureSourceStatistics endStatistics,
        bool cleanShutdown,
        string endReason,
        CancellationToken cancellationToken)
    {
        CaptureRunRecord? run = _activeRun;
        ISessionStore? store = _sessionStore;
        if (run is null || store is null)
        {
            return;
        }

        CaptureRunRecord completed = run with
        {
            EndSequence = _lastCommittedSequence,
            StoppedUtc = endStatistics.SampledAtUtc,
            EndStats = ToDriverStatsSnapshot(endStatistics),
            ServiceDropped = _serviceDropped,
            TruncationCount = _truncationCount,
            StatsKnown = _runStatsKnown && endStatistics.StatsKnown,
            CleanShutdown = cleanShutdown,
            EndReason = endReason,
        };
        await store.UpsertRunAsync(completed, cancellationToken);
        _activeRun = completed;
    }

    private void AddPendingMarker(
        string markerType,
        DateTimeOffset occurredUtc,
        long afterSequence,
        long countDelta,
        string code)
    {
        CaptureRunRecord? run = _activeRun;
        if (run is null)
        {
            return;
        }

        _pendingRecoveryMarkers.Add(CreateMarker(
            run,
            markerType,
            occurredUtc,
            afterSequence,
            countDelta,
            code));
    }

    private void EnsurePendingMarker(
        string markerType,
        DateTimeOffset occurredUtc,
        long afterSequence,
        long countDelta,
        string code)
    {
        if (_pendingRecoveryMarkers.Any(marker => marker.MarkerType == markerType))
        {
            return;
        }

        AddPendingMarker(
            markerType,
            occurredUtc,
            afterSequence,
            countDelta,
            code);
    }

    private void ReanchorPendingMarkers(long afterSequence)
    {
        for (int index = 0; index < _pendingRecoveryMarkers.Count; index++)
        {
            _pendingRecoveryMarkers[index] = _pendingRecoveryMarkers[index] with
            {
                AfterSequence = afterSequence,
            };
        }
    }

    private string GetEndReason(Exception? readerFailure)
    {
        if (_persistenceFailureSeen || _serviceDropped > 0)
        {
            return "PERSISTENCE_FAILURE";
        }

        if (_stopFailureSeen)
        {
            return "STOP_FAILURE";
        }

        if (_sourceRestartSeen)
        {
            return "SOURCE_RESTART";
        }

        return readerFailure is null ? "STOPPED" : "INTERRUPTED";
    }

    private void UpdateSnapshot(bool cleanShutdown, string? endReason)
    {
        CaptureSnapshot snapshot = CreateSnapshot(
            State,
            Generation,
            _activeRun,
            _lastCommittedSequence,
            _lastStatistics,
            _driverDropped,
            _serviceDropped,
            _truncationCount,
            _runStatsKnown,
            cleanShutdown,
            endReason);
        Volatile.Write(ref _snapshot, snapshot);
    }

    private static CaptureSnapshot CreateSnapshot(
        CaptureState state,
        long generation,
        CaptureRunRecord? run,
        long lastCommittedSequence,
        CaptureSourceStatistics statistics,
        ulong driverDropped,
        long serviceDropped,
        long truncationCount,
        bool statsKnown,
        bool cleanShutdown,
        string? endReason) =>
        new(
            state,
            generation,
            run?.RunId,
            run?.SessionId,
            run?.OwnerType,
            run?.OwnerSid,
            lastCommittedSequence,
            statistics,
            driverDropped,
            serviceDropped,
            truncationCount,
            statsKnown,
            cleanShutdown,
            endReason);

    private static IntegrityMarker CreateMarker(
        CaptureRunRecord run,
        string markerType,
        DateTimeOffset occurredUtc,
        long afterSequence,
        long countDelta,
        string code) =>
        new(
            null,
            run.RunId,
            run.Generation,
            markerType,
            occurredUtc,
            afterSequence,
            countDelta,
            code);

    private static DriverStatsSnapshot ToDriverStatsSnapshot(
        CaptureSourceStatistics statistics) =>
        new(
            statistics.StatsKnown,
            statistics.Queued,
            statistics.State,
            statistics.Dropped,
            statistics.Sequence,
            statistics.SampledAtUtc,
            statistics.UnavailableReason);

    private static ulong SaturatingAdd(ulong left, ulong right) =>
        ulong.MaxValue - left < right ? ulong.MaxValue : left + right;

    private static long SaturatingAdd(long left, long right) =>
        long.MaxValue - left < right ? long.MaxValue : left + right;

    private static long ToMarkerCount(ulong value) =>
        value > long.MaxValue ? long.MaxValue : (long)value;

    private void EnsureState(CaptureState expected, string message)
    {
        if (State != expected)
        {
            throw new InvalidOperationException(message);
        }
    }

    private void ThrowIfDisposed()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
    }
}
