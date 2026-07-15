using System.Collections.Immutable;
using System.Globalization;
using System.Runtime.Versioning;
using System.Text;
using CommMonitor.Core.Ai;
using CommMonitor.Core.Models;
using CommMonitor.Core.Sessions;
using CommMonitor.Service.Ipc;
using CommMonitor.Service.Sessions;

namespace CommMonitor.Service.Capture;

[SupportedOSPlatform("windows")]
internal sealed class CaptureAuthority
{
    private readonly CaptureCoordinator _coordinator;
    private readonly ICaptureSource _captureSource;
    private readonly ICaptureSourceStatisticsProvider? _statisticsProvider;
    private readonly CaptureLeaseManager _leases;
    private readonly ServiceStorageBoundary _storageBoundary;
    private readonly SessionCatalog _sessionCatalog;
    private readonly SemaphoreSlim _transitionGate = new(1, 1);

    private CaptureAuthorityOwner _owner;
    private bool _startupReconciled;
    private bool _driverStateKnown;
    private bool _orphanedDriverCapture;

    public CaptureAuthority(
        CaptureCoordinator coordinator,
        ICaptureSource captureSource,
        CaptureLeaseManager leases,
        ServiceStorageBoundary storageBoundary,
        SessionCatalog sessionCatalog)
    {
        _coordinator = coordinator ?? throw new ArgumentNullException(nameof(coordinator));
        _captureSource = captureSource ?? throw new ArgumentNullException(nameof(captureSource));
        _statisticsProvider = captureSource as ICaptureSourceStatisticsProvider;
        _leases = leases ?? throw new ArgumentNullException(nameof(leases));
        _storageBoundary = storageBoundary ??
            throw new ArgumentNullException(nameof(storageBoundary));
        _sessionCatalog = sessionCatalog ?? throw new ArgumentNullException(nameof(sessionCatalog));
        _owner = CaptureAuthorityOwner.Unknown;
    }

    /// <summary>
    /// Reconciles persisted runs and the kernel capture state. The service host must
    /// await this idempotent operation before starting any control or AI listener.
    /// </summary>
    public async Task InitializeAsync(CancellationToken cancellationToken = default)
    {
        await _transitionGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await EnsureStartupReconciledAsync(cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _transitionGate.Release();
        }
    }

    public async ValueTask<PreparedLease> PrepareAiStartAsync(
        CaptureClientOwner owner,
        IReadOnlySet<ulong> deviceIds,
        string? label,
        DateTimeOffset now,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(owner);
        ArgumentNullException.ThrowIfNull(deviceIds);
        if (deviceIds.Count == 0)
        {
            throw new ArgumentException(
                "At least one capture device must be selected.",
                nameof(deviceIds));
        }

        await _transitionGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await EnsureStartupReconciledAsync(cancellationToken).ConfigureAwait(false);
            ReconcileStoppedCapture();
            if (_coordinator.State != CaptureState.Stopped ||
                _owner != CaptureAuthorityOwner.None ||
                _leases.HasReservationOrLease(now))
            {
                throw Conflict("Capture is already reserved or running.");
            }

            string displayName = CreateDisplayName(label, now);
            string sessionPath = Path.Combine(
                _storageBoundary.SessionRoot,
                displayName + ".cmsession");
            var selection = new CaptureSelection(
                deviceIds.ToHashSet(),
                sessionPath,
                RunId: Guid.NewGuid().ToString("N"),
                SessionId: null,
                OwnerType: "AI",
                OwnerSid: owner.Sid);
            return _leases.Prepare(owner, _coordinator.Generation, selection, now);
        }
        finally
        {
            _transitionGate.Release();
        }
    }

    public async Task CancelAiStartAsync(
        CaptureClientOwner owner,
        string reservationId,
        CancellationToken cancellationToken = default)
    {
        await _transitionGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await EnsureStartupReconciledAsync(cancellationToken).ConfigureAwait(false);
            _ = _leases.CancelPending(owner, reservationId);
        }
        finally
        {
            _transitionGate.Release();
        }
    }

    public async Task InvalidateLogonSessionAsync(
        string sid,
        ulong logonLuid,
        CancellationToken cancellationToken = default)
    {
        await _transitionGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await EnsureStartupReconciledAsync(cancellationToken).ConfigureAwait(false);
            _ = _leases.InvalidateLogonSession(sid, logonLuid);
        }
        finally
        {
            _transitionGate.Release();
        }
    }

    public Task<ActiveLease> CommitAiStartAsync(
        CaptureClientOwner owner,
        string reservationId,
        string secret,
        DateTimeOffset now,
        CancellationToken cancellationToken = default) =>
        CommitAiStartCoreAsync(
            owner,
            reservationId,
            leaseId: null,
            secret,
            generation: null,
            now,
            cancellationToken);

    public Task<ActiveLease> CommitAiStartAsync(
        CaptureClientOwner owner,
        string reservationId,
        string leaseId,
        string secret,
        long generation,
        DateTimeOffset now,
        CancellationToken cancellationToken = default) =>
        CommitAiStartCoreAsync(
            owner,
            reservationId,
            leaseId,
            secret,
            generation,
            now,
            cancellationToken);

    public async Task<ActiveLease> RecoverLeaseAsync(
        CaptureClientOwner owner,
        string leaseId,
        string secret,
        long generation,
        DateTimeOffset now,
        CancellationToken cancellationToken = default)
    {
        await _transitionGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await EnsureStartupReconciledAsync(cancellationToken).ConfigureAwait(false);
            cancellationToken.ThrowIfCancellationRequested();
            if (_owner != CaptureAuthorityOwner.Ai ||
                _coordinator.State == CaptureState.Stopped)
            {
                _leases.Invalidate();
                throw Expired("The AI capture lease did not survive the service lifecycle.");
            }

            return _leases.Recover(
                owner,
                leaseId,
                secret,
                generation,
                _coordinator.Generation,
                _coordinator.State);
        }
        finally
        {
            _transitionGate.Release();
        }
    }

    public Task<ActiveLease> PauseAiAsync(
        CaptureClientOwner owner,
        string leaseId,
        string secret,
        long generation,
        CancellationToken cancellationToken = default) =>
        ChangeAiStateAsync(
            owner,
            leaseId,
            secret,
            generation,
            CaptureState.Running,
            static (coordinator, token) => coordinator.PauseAsync(token),
            cancellationToken);

    public Task<ActiveLease> ResumeAiAsync(
        CaptureClientOwner owner,
        string leaseId,
        string secret,
        long generation,
        CancellationToken cancellationToken = default) =>
        ChangeAiStateAsync(
            owner,
            leaseId,
            secret,
            generation,
            CaptureState.Paused,
            static (coordinator, token) => coordinator.ResumeAsync(token),
            cancellationToken);

    public async Task StopAiAsync(
        CaptureClientOwner owner,
        string leaseId,
        string secret,
        long generation,
        CancellationToken cancellationToken = default)
    {
        await _transitionGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await EnsureStartupReconciledAsync(cancellationToken).ConfigureAwait(false);
            _ = _leases.Validate(
                owner,
                leaseId,
                secret,
                generation,
                _coordinator.Generation,
                _coordinator.State);
            EnsureAiOwner();
            await _coordinator.StopAsync(cancellationToken).ConfigureAwait(false);
            _leases.Invalidate();
            _owner = CaptureAuthorityOwner.None;
        }
        finally
        {
            _transitionGate.Release();
        }
    }

    public async Task StartWpfAsync(
        CaptureSelection selection,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(selection);
        await _transitionGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await EnsureStartupReconciledAsync(cancellationToken).ConfigureAwait(false);
            ReconcileStoppedCapture();
            if (_coordinator.State != CaptureState.Stopped ||
                _owner != CaptureAuthorityOwner.None ||
                _leases.HasReservationOrLease(DateTimeOffset.UtcNow))
            {
                throw Conflict("Capture is already reserved or running.");
            }

            try
            {
                await _coordinator.StartAsync(selection, cancellationToken)
                    .ConfigureAwait(false);
                _owner = CaptureAuthorityOwner.Wpf;
            }
            catch
            {
                _owner = CaptureAuthorityOwner.None;
                throw;
            }
        }
        finally
        {
            _transitionGate.Release();
        }
    }

    public async Task StopWpfAsync(CancellationToken cancellationToken = default)
    {
        await _transitionGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await EnsureStartupReconciledAsync(cancellationToken).ConfigureAwait(false);
            if (_coordinator.State != CaptureState.Stopped)
            {
                await _coordinator.StopAsync(cancellationToken).ConfigureAwait(false);
            }

            _leases.Invalidate();
            _owner = CaptureAuthorityOwner.None;
            _driverStateKnown = true;
            _orphanedDriverCapture = false;
        }
        finally
        {
            _transitionGate.Release();
        }
    }

    private async Task<ActiveLease> CommitAiStartCoreAsync(
        CaptureClientOwner owner,
        string reservationId,
        string? leaseId,
        string secret,
        long? generation,
        DateTimeOffset now,
        CancellationToken cancellationToken)
    {
        await _transitionGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await EnsureStartupReconciledAsync(cancellationToken).ConfigureAwait(false);
            LeaseCommit commit = leaseId is null || generation is null
                ? _leases.BeginCommit(owner, reservationId, secret, now)
                : _leases.BeginCommit(
                    owner,
                    reservationId,
                    leaseId,
                    secret,
                    generation.Value,
                    now);
            if (commit.AlreadyCommitted)
            {
                if (_owner != CaptureAuthorityOwner.Ai ||
                    _coordinator.Generation != commit.Active!.Generation ||
                    _coordinator.State == CaptureState.Stopped)
                {
                    _leases.Invalidate();
                    throw Expired("The committed AI capture lease is no longer active.");
                }

                return commit.Active with { CaptureState = _coordinator.State };
            }

            if (_coordinator.State != CaptureState.Stopped ||
                _owner != CaptureAuthorityOwner.None)
            {
                _leases.FailCommit(reservationId);
                throw Conflict("Capture started before the reservation could be committed.");
            }

            if (_coordinator.Generation != commit.PreparedGeneration)
            {
                _leases.FailCommit(reservationId);
                throw Expired("The capture generation changed before commit.");
            }

            CaptureSelection pendingSelection = commit.Selection!;
            bool coordinatorAttempted = false;
            try
            {
                await PublishInitializedSessionAsync(
                    pendingSelection.SessionPath,
                    cancellationToken).ConfigureAwait(false);
                string sessionId = await FindSessionIdAsync(
                    pendingSelection.SessionPath,
                    cancellationToken).ConfigureAwait(false);
                var committedSelection = pendingSelection with { SessionId = sessionId };
                coordinatorAttempted = true;
                await _coordinator.StartAsync(committedSelection, cancellationToken)
                    .ConfigureAwait(false);
                ActiveLease active = _leases.Activate(
                    reservationId,
                    _coordinator.Generation,
                    sessionId,
                    _coordinator.State);
                _owner = CaptureAuthorityOwner.Ai;
                return active;
            }
            catch
            {
                _leases.FailCommit(reservationId);
                if (_coordinator.State == CaptureState.Stopped)
                {
                    _owner = CaptureAuthorityOwner.None;
                }

                if (!coordinatorAttempted)
                {
                    TryDeletePublishedSession(pendingSelection.SessionPath);
                }

                throw;
            }
        }
        finally
        {
            _transitionGate.Release();
        }
    }

    private async Task<ActiveLease> ChangeAiStateAsync(
        CaptureClientOwner owner,
        string leaseId,
        string secret,
        long generation,
        CaptureState expectedState,
        Func<CaptureCoordinator, CancellationToken, Task> transition,
        CancellationToken cancellationToken)
    {
        await _transitionGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await EnsureStartupReconciledAsync(cancellationToken).ConfigureAwait(false);
            _ = _leases.Validate(
                owner,
                leaseId,
                secret,
                generation,
                _coordinator.Generation,
                _coordinator.State);
            EnsureAiOwner();
            if (_coordinator.State != expectedState)
            {
                throw new InvalidOperationException(
                    $"Capture must be {expectedState} for this transition.");
            }

            await transition(_coordinator, cancellationToken).ConfigureAwait(false);
            return _leases.Describe(_coordinator.State);
        }
        finally
        {
            _transitionGate.Release();
        }
    }

    private void EnsureAiOwner()
    {
        if (_owner != CaptureAuthorityOwner.Ai ||
            _coordinator.State == CaptureState.Stopped)
        {
            _leases.Invalidate();
            throw Expired("The active capture is not controlled by an AI lease.");
        }
    }

    private void ReconcileStoppedCapture()
    {
        if (_coordinator.State != CaptureState.Stopped ||
            !_driverStateKnown ||
            _orphanedDriverCapture)
        {
            return;
        }

        if (_owner is CaptureAuthorityOwner.Ai or
            CaptureAuthorityOwner.Wpf or
            CaptureAuthorityOwner.Unknown)
        {
            _leases.Invalidate();
            _owner = CaptureAuthorityOwner.None;
        }
    }

    private async Task EnsureStartupReconciledAsync(
        CancellationToken cancellationToken)
    {
        if (_startupReconciled)
        {
            return;
        }

        await ReconcileInterruptedSessionsAsync(cancellationToken).ConfigureAwait(false);
        CaptureSourceStatistics statistics = await ReadDriverStatisticsAsync(
            cancellationToken).ConfigureAwait(false);
        if (!statistics.StatsKnown)
        {
            SetStartupDegraded(statistics.StatsKnown);
            throw DriverUnavailable(
                statistics.UnavailableReason ??
                "The driver state is unavailable during service startup.");
        }

        if (_coordinator.State == CaptureState.Stopped &&
            statistics.State != CaptureState.Stopped)
        {
            try
            {
                SetStartupDegraded(driverStateKnown: true);
                await _captureSource.ConfigureAsync(
                        CaptureState.Stopped,
                        ImmutableHashSet<ulong>.Empty,
                        cancellationToken)
                    .ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                throw;
            }
            catch (Exception exception)
            {
                SetStartupDegraded(driverStateKnown: true);
                throw DriverUnavailable(
                    "The orphaned kernel capture could not be stopped during service startup.",
                    exception);
            }

            statistics = await ReadDriverStatisticsAsync(cancellationToken)
                .ConfigureAwait(false);
            if (!statistics.StatsKnown || statistics.State != CaptureState.Stopped)
            {
                SetStartupDegraded(statistics.StatsKnown);
                throw DriverUnavailable(
                    statistics.UnavailableReason ??
                    "The driver did not confirm a stopped state after startup recovery.");
            }
        }

        _driverStateKnown = statistics.StatsKnown;
        _orphanedDriverCapture = false;
        if (_coordinator.State == CaptureState.Stopped &&
            statistics.State == CaptureState.Stopped)
        {
            _owner = CaptureAuthorityOwner.None;
        }
        else
        {
            _owner = CaptureAuthorityOwner.Unknown;
        }

        _startupReconciled = true;
    }

    private async Task<CaptureSourceStatistics> ReadDriverStatisticsAsync(
        CancellationToken cancellationToken)
    {
        if (_statisticsProvider is null)
        {
            return CaptureSourceStatistics.Unknown(
                "The capture source does not expose driver statistics.",
                DateTimeOffset.UtcNow);
        }

        try
        {
            return await _statisticsProvider
                .GetStatisticsAsync(cancellationToken)
                .ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception exception)
        {
            return CaptureSourceStatistics.Unknown(
                string.IsNullOrWhiteSpace(exception.Message)
                    ? "The driver statistics query failed."
                    : exception.Message,
                DateTimeOffset.UtcNow);
        }
    }

    private void SetStartupDegraded(bool driverStateKnown)
    {
        _driverStateKnown = driverStateKnown;
        _orphanedDriverCapture = true;
        _owner = CaptureAuthorityOwner.Unknown;
        _startupReconciled = false;
        _leases.Invalidate();
    }

    private async Task ReconcileInterruptedSessionsAsync(
        CancellationToken cancellationToken)
    {
        IReadOnlyList<SessionCatalogItem> sessions = await _sessionCatalog
            .ListAsync(cancellationToken)
            .ConfigureAwait(false);
        foreach (SessionCatalogItem item in sessions)
        {
            cancellationToken.ThrowIfCancellationRequested();
            using ResolvedSession resolved = await _sessionCatalog
                .ResolveAsync(item.SessionId, cancellationToken)
                .ConfigureAwait(false);
            var reader = new ReadOnlySessionReader(resolved.FullPath);
            int schemaVersion;
            IReadOnlyList<CaptureRunRecord> runs;
            try
            {
                schemaVersion = await reader.GetSchemaVersionAsync(cancellationToken)
                    .ConfigureAwait(false);
                if (schemaVersion != 3)
                {
                    continue;
                }

                runs = await reader.ReadRunsAsync(cancellationToken).ConfigureAwait(false);
            }
            catch (Exception exception) when (
                exception is IOException or InvalidDataException or InvalidOperationException)
            {
                continue;
            }

            CaptureRunRecord[] unfinished = runs
                .Where(static run => run.StoppedUtc is null && !run.CleanShutdown)
                .ToArray();
            if (unfinished.Length == 0)
            {
                continue;
            }

            var store = new SessionStore(resolved.FullPath);
            await store.InitializeAsync(cancellationToken).ConfigureAwait(false);
            long lastSequence = await store.GetLastSequenceAsync(cancellationToken)
                .ConfigureAwait(false);
            DateTimeOffset stoppedUtc = DateTimeOffset.UtcNow;
            foreach (CaptureRunRecord run in unfinished)
            {
                var unavailable = new DriverStatsSnapshot(
                    false,
                    0,
                    CaptureState.Stopped,
                    0,
                    0,
                    stoppedUtc,
                    "Service restarted before final driver statistics were recorded.");
                await store.UpsertRunAsync(
                    run with
                    {
                        EndSequence = lastSequence,
                        StoppedUtc = stoppedUtc,
                        EndStats = unavailable,
                        StatsKnown = false,
                        CleanShutdown = false,
                        EndReason = "SERVICE_RESTART",
                    },
                    cancellationToken).ConfigureAwait(false);
                await store.AppendBatchAsync(
                    new PersistBatch(
                        [],
                        [new IntegrityMarker(
                            null,
                            run.RunId,
                            run.Generation,
                            "INTERRUPTED",
                            stoppedUtc,
                            lastSequence,
                            0,
                            AiErrorCodes.IntegrityUnknown)]),
                    cancellationToken).ConfigureAwait(false);
            }
        }
    }

    private async Task PublishInitializedSessionAsync(
        string path,
        CancellationToken cancellationToken)
    {
        string canonicalPath = Path.GetFullPath(path);
        string? parent = Path.GetDirectoryName(canonicalPath);
        if (!string.Equals(
                parent,
                Path.GetFullPath(_storageBoundary.SessionRoot),
                StringComparison.OrdinalIgnoreCase))
        {
            throw new IOException("The generated AI session path escaped managed storage.");
        }

        string temporaryPath = canonicalPath + $".pending-{Guid.NewGuid():N}";
        try
        {
            using (var stream = new FileStream(
                       temporaryPath,
                       FileMode.CreateNew,
                       FileAccess.ReadWrite,
                       FileShare.Read,
                       bufferSize: 4096,
                       FileOptions.WriteThrough))
            {
                stream.Flush(flushToDisk: true);
            }

            var store = new SessionStore(temporaryPath);
            await store.InitializeAsync(cancellationToken).ConfigureAwait(false);
            int schemaVersion = await new ReadOnlySessionReader(temporaryPath)
                .GetSchemaVersionAsync(cancellationToken)
                .ConfigureAwait(false);
            if (schemaVersion != 3)
            {
                throw new InvalidDataException(
                    "The initialized AI session did not use schema version 3.");
            }

            File.Move(temporaryPath, canonicalPath, overwrite: false);
            _storageBoundary.VerifySessionPath(canonicalPath);
        }
        finally
        {
            TryDeleteFile(temporaryPath);
            TryDeleteFile(temporaryPath + "-wal");
            TryDeleteFile(temporaryPath + "-shm");
        }
    }

    private async ValueTask<string> FindSessionIdAsync(
        string path,
        CancellationToken cancellationToken)
    {
        string displayName = Path.GetFileNameWithoutExtension(path);
        IReadOnlyList<SessionCatalogItem> sessions = await _sessionCatalog
            .ListAsync(cancellationToken)
            .ConfigureAwait(false);
        SessionCatalogItem? item = sessions.SingleOrDefault(candidate =>
            string.Equals(
                candidate.DisplayName,
                displayName,
                StringComparison.OrdinalIgnoreCase));
        return item?.SessionId ??
            throw new IOException("The reserved AI session could not be cataloged safely.");
    }

    private static void TryDeletePublishedSession(string path)
    {
        TryDeleteFile(path);
        TryDeleteFile(path + "-wal");
        TryDeleteFile(path + "-shm");
    }

    private static void TryDeleteFile(string path)
    {
        try
        {
            File.Delete(path);
        }
        catch (Exception exception) when (
            exception is IOException or UnauthorizedAccessException)
        {
            // Generated session artifacts can be cleaned by the next maintenance pass.
        }
    }

    private static string CreateDisplayName(string? label, DateTimeOffset now)
    {
        string safeLabel = SanitizeLabel(label);
        string timestamp = now.ToUniversalTime().ToString(
            "yyyyMMdd-HHmmss",
            CultureInfo.InvariantCulture);
        return string.Create(
            CultureInfo.InvariantCulture,
            $"{safeLabel}-{timestamp}-{Guid.NewGuid():N}");
    }

    private static string SanitizeLabel(string? label)
    {
        string input = string.IsNullOrWhiteSpace(label) ? "capture" : label.Trim();
        var safe = new StringBuilder(Math.Min(input.Length, 40));
        bool lastWasSeparator = false;
        foreach (char character in input.Normalize(NormalizationForm.FormC))
        {
            if (safe.Length >= 40)
            {
                break;
            }

            if (char.IsLetterOrDigit(character) || character is '-' or '_')
            {
                safe.Append(character);
                lastWasSeparator = false;
            }
            else if (!lastWasSeparator)
            {
                safe.Append('-');
                lastWasSeparator = true;
            }
        }

        string result = safe.ToString().Trim('-');
        return result.Length == 0 ? "capture" : result;
    }

    private static CaptureLeaseException Conflict(string message) =>
        new(AiErrorCodes.CaptureConflict, message);

    private static CaptureLeaseException Expired(string message) =>
        new(AiErrorCodes.LeaseExpired, message);

    private static CaptureLeaseException DriverUnavailable(
        string message,
        Exception? innerException = null) =>
        new(AiErrorCodes.DriverUnavailable, message, innerException);

    private enum CaptureAuthorityOwner
    {
        None,
        Wpf,
        Ai,
        Unknown,
    }
}
