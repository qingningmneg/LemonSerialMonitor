using System.Collections.Immutable;
using System.Runtime.Versioning;
using CommMonitor.Core.Ai;
using CommMonitor.Core.Models;
using CommMonitor.Core.Sessions;
using CommMonitor.Service.Capture;
using CommMonitor.Service.Ipc;
using CommMonitor.Service.Security;
using CommMonitor.Service.Sessions;

namespace CommMonitor.Service.Tests.Capture;

[SupportedOSPlatform("windows")]
public sealed class CaptureLeaseManagerTests
{
    private static readonly DateTimeOffset Now =
        new(2026, 7, 13, 12, 0, 0, TimeSpan.Zero);

    private static readonly CaptureClientOwner Owner =
        new("S-1-5-21-1000", 0x0000_0001_0000_0002, "client-a");

    [Fact]
    public async Task Prepare_reserves_for_ten_seconds_without_starting_capture()
    {
        await using var context = new AuthorityContext();

        PreparedLease pending = await context.Authority.PrepareAiStartAsync(
            Owner,
            Devices(),
            "night shift",
            Now);

        Assert.Equal(CaptureState.Stopped, context.Coordinator.State);
        Assert.Equal(Now + TimeSpan.FromSeconds(10), pending.ExpiresAtUtc);
        Assert.Equal(Owner.ClientInstanceId, pending.ClientInstanceId);
        Assert.Equal(0, pending.Generation);
        Assert.False(string.IsNullOrWhiteSpace(pending.ReservationId));
        Assert.False(string.IsNullOrWhiteSpace(pending.LeaseId));
        Assert.True(pending.Secret.Length >= 40);
        Assert.Empty(Directory.EnumerateFiles(context.Boundary.SessionRoot));
    }

    [Fact]
    public async Task Disconnect_before_ack_expires_reservation_and_never_starts_capture()
    {
        await using var context = new AuthorityContext();
        PreparedLease abandoned = await context.Authority.PrepareAiStartAsync(
            Owner,
            Devices(),
            null,
            Now);

        CaptureLeaseException expired = await Assert.ThrowsAsync<CaptureLeaseException>(
            () => context.Authority.CommitAiStartAsync(
                Owner,
                abandoned.ReservationId,
                abandoned.Secret,
                abandoned.ExpiresAtUtc));

        Assert.Equal(AiErrorCodes.StartReservationExpired, expired.Code);
        Assert.Equal(CaptureState.Stopped, context.Coordinator.State);

        PreparedLease replacement = await context.Authority.PrepareAiStartAsync(
            Owner,
            Devices(0x22),
            null,
            abandoned.ExpiresAtUtc);
        Assert.NotEqual(abandoned.ReservationId, replacement.ReservationId);
    }

    [Fact]
    public async Task Disconnect_cancels_only_the_matching_pending_owner_immediately()
    {
        await using var context = new AuthorityContext();
        PreparedLease abandoned = await context.Authority.PrepareAiStartAsync(
            Owner,
            Devices(),
            null,
            Now);

        await context.Authority.CancelAiStartAsync(
            Owner with { ClientInstanceId = "client-b" },
            abandoned.ReservationId);
        CaptureLeaseException stillReserved = await Assert.ThrowsAsync<CaptureLeaseException>(
            () => context.Authority.PrepareAiStartAsync(
                Owner,
                Devices(0x22),
                null,
                Now).AsTask());
        Assert.Equal(AiErrorCodes.CaptureConflict, stillReserved.Code);

        await context.Authority.CancelAiStartAsync(Owner, abandoned.ReservationId);
        PreparedLease replacement = await context.Authority.PrepareAiStartAsync(
            Owner,
            Devices(0x22),
            null,
            Now);

        Assert.NotEqual(abandoned.ReservationId, replacement.ReservationId);
        Assert.Equal(CaptureState.Stopped, context.Coordinator.State);
    }

    [Fact]
    public async Task Commit_is_idempotent_when_the_success_reply_is_lost()
    {
        await using var context = new AuthorityContext();
        PreparedLease pending = await context.Authority.PrepareAiStartAsync(
            Owner,
            Devices(),
            "reply-loss",
            Now);

        ActiveLease first = await context.Authority.CommitAiStartAsync(
            Owner,
            pending.ReservationId,
            pending.LeaseId,
            pending.Secret,
            pending.Generation,
            Now + TimeSpan.FromSeconds(1));
        long generationAfterFirstCommit = context.Coordinator.Generation;

        ActiveLease replay = await context.Authority.CommitAiStartAsync(
            Owner,
            pending.ReservationId,
            pending.LeaseId,
            pending.Secret,
            pending.Generation,
            Now + TimeSpan.FromSeconds(2));

        Assert.Equal(CaptureState.Running, context.Coordinator.State);
        Assert.Equal(generationAfterFirstCommit, context.Coordinator.Generation);
        Assert.Equal(first, replay);
        Assert.StartsWith("s1.", first.SessionId, StringComparison.Ordinal);
        Assert.Equal(1, first.Generation);
    }

    [Fact]
    public async Task Ack_then_driver_start_failure_revokes_candidate_and_keeps_stopped()
    {
        await using var context = new AuthorityContext(new FailingStartSource());
        PreparedLease pending = await context.Authority.PrepareAiStartAsync(
            Owner,
            Devices(),
            "failed-start",
            Now);

        await Assert.ThrowsAsync<InvalidOperationException>(() =>
            context.Authority.CommitAiStartAsync(
                Owner,
                pending.ReservationId,
                pending.Secret,
                Now + TimeSpan.FromSeconds(1)));

        Assert.Equal(CaptureState.Stopped, context.Coordinator.State);
        CaptureLeaseException replay = await Assert.ThrowsAsync<CaptureLeaseException>(() =>
            context.Authority.CommitAiStartAsync(
                Owner,
                pending.ReservationId,
                pending.Secret,
                Now + TimeSpan.FromSeconds(2)));
        Assert.Equal(AiErrorCodes.InvalidLease, replay.Code);
    }

    [Fact]
    public async Task Service_crash_before_commit_discards_pending_without_starting_driver()
    {
        await using var context = new AuthorityContext();
        PreparedLease lost = await context.Authority.PrepareAiStartAsync(
            Owner,
            Devices(),
            "before-crash",
            Now);

        CaptureAuthority restarted = context.CreateRestartedAuthority();
        PreparedLease replacement = await restarted.PrepareAiStartAsync(
            Owner,
            Devices(0x33),
            "after-crash",
            Now + TimeSpan.FromSeconds(1));

        Assert.Equal(CaptureState.Stopped, context.Coordinator.State);
        Assert.NotEqual(lost.LeaseId, replacement.LeaseId);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task Startup_reconciles_open_run_and_stops_known_orphan_before_listeners(
        bool pauseBeforeCrash)
    {
        await using var context = new AuthorityContext();
        ActiveLease active = await context.StartAiAsync(Owner, Now);
        if (pauseBeforeCrash)
        {
            active = await context.Authority.PauseAiAsync(
                Owner,
                active.LeaseId,
                active.Secret,
                active.Generation);
        }

        (CaptureAuthority restarted, CaptureCoordinator restartedCoordinator) =
            context.CreateFreshRestartedAuthority();
        await using (restartedCoordinator)
        {
            await restarted.InitializeAsync();
            await restarted.InitializeAsync();
            Assert.Equal(CaptureState.Stopped, context.DriverState.State);

            using (ResolvedSession initialized = await context.Catalog.ResolveAsync(
                       active.SessionId))
            {
                var initializedReader = new ReadOnlySessionReader(initialized.FullPath);
                CaptureRunRecord initializedRun = Assert.Single(
                    await initializedReader.ReadRunsAsync());
                Assert.Equal("SERVICE_RESTART", initializedRun.EndReason);
                Assert.False(initializedRun.StatsKnown);
                Assert.False(initializedRun.CleanShutdown);
                Assert.NotNull(initializedRun.StoppedUtc);
                Assert.Single(
                    (await initializedReader.ReadMarkersAsync(initializedRun.RunId))
                    .Where(marker => marker.Code == AiErrorCodes.IntegrityUnknown));
            }

            CaptureLeaseException recovery = await Assert.ThrowsAsync<CaptureLeaseException>(() =>
                restarted.RecoverLeaseAsync(
                    Owner,
                    active.LeaseId,
                    active.Secret,
                    active.Generation,
                    Now + TimeSpan.FromSeconds(2)));
            Assert.Equal(AiErrorCodes.LeaseExpired, recovery.Code);

            PreparedLease replacement = await restarted.PrepareAiStartAsync(
                Owner,
                Devices(0x44),
                "after-startup-recovery",
                Now + TimeSpan.FromSeconds(4));
            Assert.NotEqual(active.LeaseId, replacement.LeaseId);
        }
    }

    [Fact]
    public async Task Startup_with_unknown_driver_statistics_stays_degraded_and_blocks_mutation()
    {
        await using var context = new AuthorityContext();
        ActiveLease active = await context.StartAiAsync(Owner, Now);
        var source = new UnknownStatisticsCaptureSource(context.DriverState);
        (CaptureAuthority restarted, CaptureCoordinator restartedCoordinator) =
            context.CreateFreshRestartedAuthority(source);
        await using (restartedCoordinator)
        {
            CaptureLeaseException degraded = await Assert.ThrowsAsync<CaptureLeaseException>(
                () => restarted.InitializeAsync());
            Assert.Equal(AiErrorCodes.DriverUnavailable, degraded.Code);
            Assert.Equal(CaptureState.Running, context.DriverState.State);
            Assert.Equal(0, source.ConfigureCalls);

            CaptureLeaseException blocked = await Assert.ThrowsAsync<CaptureLeaseException>(() =>
                restarted.PrepareAiStartAsync(
                    Owner,
                    Devices(0x44),
                    "blocked",
                    Now + TimeSpan.FromSeconds(3)).AsTask());
            Assert.Equal(AiErrorCodes.DriverUnavailable, blocked.Code);
            Assert.Empty(Directory.EnumerateFiles(
                context.Boundary.SessionRoot,
                "*blocked*"));

            using ResolvedSession resolved = await context.Catalog.ResolveAsync(active.SessionId);
            CaptureRunRecord run = Assert.Single(
                await new ReadOnlySessionReader(resolved.FullPath).ReadRunsAsync());
            Assert.Equal("SERVICE_RESTART", run.EndReason);
        }
    }

    [Fact]
    public async Task Startup_stop_failure_stays_degraded_and_blocks_mutation()
    {
        await using var context = new AuthorityContext();
        _ = await context.StartAiAsync(Owner, Now);
        var source = new FailingRecoveryStopSource(context.DriverState);
        (CaptureAuthority restarted, CaptureCoordinator restartedCoordinator) =
            context.CreateFreshRestartedAuthority(source);
        await using (restartedCoordinator)
        {
            CaptureLeaseException degraded = await Assert.ThrowsAsync<CaptureLeaseException>(
                () => restarted.InitializeAsync());
            Assert.Equal(AiErrorCodes.DriverUnavailable, degraded.Code);
            Assert.Equal(CaptureState.Running, context.DriverState.State);
            Assert.Equal(1, source.ConfigureCalls);

            CaptureLeaseException blocked = await Assert.ThrowsAsync<CaptureLeaseException>(() =>
                restarted.StartWpfAsync(new CaptureSelection(
                    Devices(0x44),
                    Path.Combine(context.Boundary.SessionRoot, "blocked.cmsession"))));
            Assert.Equal(AiErrorCodes.DriverUnavailable, blocked.Code);
            Assert.Equal(2, source.ConfigureCalls);
            Assert.Equal(CaptureState.Running, context.DriverState.State);
        }
    }

    [Fact]
    public async Task Recovery_requires_same_sid_luid_and_client_instance()
    {
        await using var context = new AuthorityContext();
        ActiveLease active = await context.StartAiAsync(Owner, Now);

        CaptureLeaseException wrongSid = await Assert.ThrowsAsync<CaptureLeaseException>(() =>
            context.Authority.RecoverLeaseAsync(
                Owner with { Sid = "S-1-5-21-2000" },
                active.LeaseId,
                active.Secret,
                active.Generation,
                Now + TimeSpan.FromSeconds(2)));
        CaptureLeaseException wrongClient = await Assert.ThrowsAsync<CaptureLeaseException>(() =>
            context.Authority.RecoverLeaseAsync(
                Owner with { ClientInstanceId = "client-b" },
                active.LeaseId,
                active.Secret,
                active.Generation,
                Now + TimeSpan.FromSeconds(2)));

        Assert.Equal(AiErrorCodes.InvalidLease, wrongSid.Code);
        Assert.Equal(AiErrorCodes.InvalidLease, wrongClient.Code);

        ActiveLease recovered = await context.Authority.RecoverLeaseAsync(
            Owner,
            active.LeaseId,
            active.Secret,
            active.Generation,
            Now + TimeSpan.FromSeconds(3));
        Assert.NotEqual(active.Secret, recovered.Secret);
    }

    [Fact]
    public async Task Logout_luid_change_and_generation_change_expire_the_lease()
    {
        await using var first = new AuthorityContext();
        ActiveLease active = await first.StartAiAsync(Owner, Now);

        CaptureLeaseException logout = await Assert.ThrowsAsync<CaptureLeaseException>(() =>
            first.Authority.RecoverLeaseAsync(
                Owner with { LogonLuid = Owner.LogonLuid + 1 },
                active.LeaseId,
                active.Secret,
                active.Generation,
                Now + TimeSpan.FromSeconds(2)));
        Assert.Equal(AiErrorCodes.LeaseExpired, logout.Code);

        CaptureLeaseException afterLogout = await Assert.ThrowsAsync<CaptureLeaseException>(() =>
            first.Authority.PauseAiAsync(
                Owner,
                active.LeaseId,
                active.Secret,
                active.Generation));
        Assert.Equal(AiErrorCodes.LeaseExpired, afterLogout.Code);
        await first.Authority.StopWpfAsync();

        await using var second = new AuthorityContext();
        ActiveLease next = await second.StartAiAsync(Owner, Now);
        CaptureLeaseException generation = await Assert.ThrowsAsync<CaptureLeaseException>(() =>
            second.Authority.RecoverLeaseAsync(
                Owner,
                next.LeaseId,
                next.Secret,
                next.Generation + 1,
                Now + TimeSpan.FromSeconds(2)));
        Assert.Equal(AiErrorCodes.LeaseExpired, generation.Code);
        await second.Authority.StopWpfAsync();
    }

    [Fact]
    public async Task Recovery_retry_after_lost_reply_returns_same_rotated_secret_until_ack()
    {
        await using var context = new AuthorityContext();
        ActiveLease active = await context.StartAiAsync(Owner, Now);

        ActiveLease rotated = await context.Authority.RecoverLeaseAsync(
            Owner,
            active.LeaseId,
            active.Secret,
            active.Generation,
            Now + TimeSpan.FromSeconds(2));

        Assert.NotEqual(active.Secret, rotated.Secret);
        ActiveLease retry = await context.Authority.RecoverLeaseAsync(
            Owner,
            active.LeaseId,
            active.Secret,
            active.Generation,
            Now + TimeSpan.FromSeconds(3));
        Assert.Equal(rotated, retry);

        CaptureLeaseException replay = await Assert.ThrowsAsync<CaptureLeaseException>(() =>
            context.Authority.PauseAiAsync(
                Owner,
                active.LeaseId,
                active.Secret,
                active.Generation));
        Assert.Equal(AiErrorCodes.InvalidLease, replay.Code);

        ActiveLease paused = await context.Authority.PauseAiAsync(
            Owner,
            rotated.LeaseId,
            rotated.Secret,
            rotated.Generation);
        Assert.Equal(CaptureState.Paused, paused.CaptureState);

        CaptureLeaseException afterAck = await Assert.ThrowsAsync<CaptureLeaseException>(() =>
            context.Authority.RecoverLeaseAsync(
                Owner,
                active.LeaseId,
                active.Secret,
                active.Generation,
                Now + TimeSpan.FromSeconds(4)));
        Assert.Equal(AiErrorCodes.InvalidLease, afterAck.Code);
    }

    [Fact]
    public async Task Logout_notification_invalidates_matching_pending_and_active_leases()
    {
        await using var context = new AuthorityContext();
        PreparedLease pending = await context.Authority.PrepareAiStartAsync(
            Owner,
            Devices(),
            null,
            Now);

        await context.Authority.InvalidateLogonSessionAsync(
            Owner.Sid,
            Owner.LogonLuid + 1);
        CaptureLeaseException stillReserved = await Assert.ThrowsAsync<CaptureLeaseException>(
            () => context.Authority.PrepareAiStartAsync(
                Owner,
                Devices(0x22),
                null,
                Now).AsTask());
        Assert.Equal(AiErrorCodes.CaptureConflict, stillReserved.Code);

        await context.Authority.InvalidateLogonSessionAsync(Owner.Sid, Owner.LogonLuid);
        CaptureClientOwner relogged = Owner with { LogonLuid = Owner.LogonLuid + 1 };
        PreparedLease replacement = await context.Authority.PrepareAiStartAsync(
            relogged,
            Devices(0x22),
            null,
            Now);
        ActiveLease active = await context.Authority.CommitAiStartAsync(
            relogged,
            replacement.ReservationId,
            replacement.Secret,
            Now + TimeSpan.FromSeconds(1));

        await context.Authority.InvalidateLogonSessionAsync(relogged.Sid, relogged.LogonLuid);
        CaptureLeaseException expired = await Assert.ThrowsAsync<CaptureLeaseException>(() =>
            context.Authority.PauseAiAsync(
                relogged,
                active.LeaseId,
                active.Secret,
                active.Generation));
        Assert.Equal(AiErrorCodes.LeaseExpired, expired.Code);
        Assert.Equal(CaptureState.Running, context.Coordinator.State);

        await context.Authority.StopWpfAsync();
    }

    [Fact]
    public async Task Different_live_logon_for_same_sid_cannot_revoke_the_active_owner()
    {
        await using var context = new AuthorityContext();
        PreparedLease pending = await context.Authority.PrepareAiStartAsync(
            Owner,
            Devices(),
            "original-logon",
            Now);
        CaptureClientOwner otherLogon = Owner with
        {
            LogonLuid = Owner.LogonLuid + 1,
            ClientInstanceId = "client-other-logon",
        };

        CaptureLeaseException pendingConflict =
            await Assert.ThrowsAsync<CaptureLeaseException>(() =>
                context.Authority.PrepareAiStartAsync(
                    otherLogon,
                    Devices(0x22),
                    "other-logon",
                    Now + TimeSpan.FromSeconds(2)).AsTask());
        Assert.Equal(AiErrorCodes.CaptureConflict, pendingConflict.Code);

        ActiveLease active = await context.Authority.CommitAiStartAsync(
            Owner,
            pending.ReservationId,
            pending.Secret,
            Now + TimeSpan.FromSeconds(3));
        CaptureLeaseException activeConflict =
            await Assert.ThrowsAsync<CaptureLeaseException>(() =>
                context.Authority.PrepareAiStartAsync(
                    otherLogon,
                    Devices(0x22),
                    "other-logon",
                    Now + TimeSpan.FromSeconds(4)).AsTask());
        Assert.Equal(AiErrorCodes.CaptureConflict, activeConflict.Code);

        ActiveLease paused = await context.Authority.PauseAiAsync(
            Owner,
            active.LeaseId,
            active.Secret,
            active.Generation);
        Assert.Equal(CaptureState.Paused, paused.CaptureState);
    }

    [Fact]
    public async Task Invalid_proof_is_rejected_before_transition_state_is_disclosed()
    {
        await using var context = new AuthorityContext();
        ActiveLease active = await context.StartAiAsync(Owner, Now);
        ActiveLease paused = await context.Authority.PauseAiAsync(
            Owner,
            active.LeaseId,
            active.Secret,
            active.Generation);

        CaptureLeaseException invalid = await Assert.ThrowsAsync<CaptureLeaseException>(() =>
            context.Authority.PauseAiAsync(
                Owner,
                paused.LeaseId,
                "not-a-secret",
                paused.Generation));

        Assert.Equal(AiErrorCodes.InvalidLease, invalid.Code);
    }

    [Fact]
    public async Task Commit_publishes_only_an_initialized_schema_v3_session()
    {
        var keyRing = new BlockingKeyRing();
        await using var context = new AuthorityContext(keyRing: keyRing);
        PreparedLease pending = await context.Authority.PrepareAiStartAsync(
            Owner,
            Devices(),
            "atomic-publish",
            Now);
        keyRing.BlockNextActiveKeyRead();

        Task<ActiveLease> commit = context.Authority.CommitAiStartAsync(
            Owner,
            pending.ReservationId,
            pending.Secret,
            Now + TimeSpan.FromSeconds(1));
        await keyRing.Blocked.WaitAsync(TimeSpan.FromSeconds(5));
        try
        {
            string path = Assert.Single(Directory.EnumerateFiles(
                context.Boundary.SessionRoot,
                "*.cmsession"));
            Assert.Equal(3, await new ReadOnlySessionReader(path).GetSchemaVersionAsync());
        }
        finally
        {
            keyRing.Release();
        }

        await commit;
    }

    [Fact]
    public async Task Wpf_state_changes_run_through_the_capture_authority()
    {
        await using var context = new AuthorityContext();
        await context.Authority.StartWpfAsync(new CaptureSelection(
            Devices(),
            Path.Combine(context.Boundary.SessionRoot, "wpf.cmsession")));
        Assert.Equal(CaptureState.Running, context.Coordinator.State);

        await context.Authority.PauseWpfAsync();
        Assert.Equal(CaptureState.Paused, context.Coordinator.State);
        await context.Authority.ResumeWpfAsync();
        Assert.Equal(CaptureState.Running, context.Coordinator.State);
        await context.Authority.StopWpfAsync();
        Assert.Equal(CaptureState.Stopped, context.Coordinator.State);
    }

    [Fact]
    public async Task Wpf_pause_and_resume_cannot_mutate_an_ai_owned_capture()
    {
        await using var context = new AuthorityContext();
        ActiveLease active = await context.StartAiAsync(Owner, Now);

        CaptureLeaseException pause = await Assert.ThrowsAsync<CaptureLeaseException>(
            () => context.Authority.PauseWpfAsync());

        Assert.Equal(AiErrorCodes.CaptureConflict, pause.Code);
        Assert.Equal(CaptureState.Running, context.Coordinator.State);

        ActiveLease paused = await context.Authority.PauseAiAsync(
            Owner,
            active.LeaseId,
            active.Secret,
            active.Generation);
        CaptureLeaseException resume = await Assert.ThrowsAsync<CaptureLeaseException>(
            () => context.Authority.ResumeWpfAsync());

        Assert.Equal(AiErrorCodes.CaptureConflict, resume.Code);
        Assert.Equal(CaptureState.Paused, paused.CaptureState);
        Assert.Equal(CaptureState.Paused, context.Coordinator.State);
    }

    [Fact]
    public async Task Wpf_capture_conflicts_with_ai_and_ai_cannot_force_stop_it()
    {
        await using var context = new AuthorityContext();
        string path = Path.Combine(
            context.Boundary.SessionRoot,
            $"wpf-{Guid.NewGuid():N}.cmsession");
        await context.Authority.StartWpfAsync(new CaptureSelection(
            Devices(),
            path,
            OwnerType: "WPF",
            OwnerSid: Owner.Sid));

        CaptureLeaseException conflict = await Assert.ThrowsAsync<CaptureLeaseException>(() =>
            context.Authority.PrepareAiStartAsync(
                Owner,
                Devices(0x99),
                "ai",
                Now).AsTask());
        CaptureLeaseException forcedStop = await Assert.ThrowsAsync<CaptureLeaseException>(() =>
            context.Authority.StopAiAsync(
                Owner,
                "not-a-lease",
                "not-a-secret",
                context.Coordinator.Generation));

        Assert.Equal(AiErrorCodes.CaptureConflict, conflict.Code);
        Assert.Contains(
            forcedStop.Code,
            new[] { AiErrorCodes.InvalidLease, AiErrorCodes.LeaseExpired });
        Assert.Equal(CaptureState.Running, context.Coordinator.State);

        await context.Authority.StopWpfAsync();
        Assert.Equal(CaptureState.Stopped, context.Coordinator.State);
    }

    [Fact]
    public async Task Explicit_ai_stop_invalidates_the_lease()
    {
        await using var context = new AuthorityContext();
        ActiveLease active = await context.StartAiAsync(Owner, Now);

        await context.Authority.StopAiAsync(
            Owner,
            active.LeaseId,
            active.Secret,
            active.Generation);

        Assert.Equal(CaptureState.Stopped, context.Coordinator.State);
        CaptureLeaseException replay = await Assert.ThrowsAsync<CaptureLeaseException>(() =>
            context.Authority.ResumeAiAsync(
                Owner,
                active.LeaseId,
                active.Secret,
                active.Generation));
        Assert.Equal(AiErrorCodes.LeaseExpired, replay.Code);
    }

    [Theory]
    [InlineData("")]
    [InlineData("not-base64!")]
    [InlineData("AA")]
    public async Task Malformed_or_wrong_secrets_use_the_same_invalid_lease_error(string secret)
    {
        await using var context = new AuthorityContext();
        ActiveLease active = await context.StartAiAsync(Owner, Now);

        CaptureLeaseException exception = await Assert.ThrowsAsync<CaptureLeaseException>(() =>
            context.Authority.PauseAiAsync(
                Owner,
                active.LeaseId,
                secret,
                active.Generation));

        Assert.Equal(AiErrorCodes.InvalidLease, exception.Code);
    }

    private static IReadOnlySet<ulong> Devices(ulong deviceId = 0x11) =>
        new HashSet<ulong> { deviceId };

    private sealed class AuthorityContext : IAsyncDisposable
    {
        private readonly IProtectedKeyRing _keyRing;

        public AuthorityContext(
            ICaptureSource? source = null,
            IProtectedKeyRing? keyRing = null)
        {
            Root = Path.Combine(
                Path.GetTempPath(),
                "CommMonitor-CaptureAuthorityTests",
                Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(Root);
            Boundary = ServiceStorageBoundary.Open(
                Root,
                Path.Combine(Root, "Sessions"),
                Path.Combine(Root, "Exports"));
            _keyRing = keyRing ?? new MemoryKeyRing();
            Catalog = new SessionCatalog(Boundary, _keyRing);
            DriverState = new PersistentDriverState();
            Source = source ?? new PersistentCaptureSource(DriverState);
            Coordinator = new CaptureCoordinator(Source, new SessionStoreFactory());
            Authority = CreateRestartedAuthority();
        }

        public string Root { get; }

        public ServiceStorageBoundary Boundary { get; }

        public SessionCatalog Catalog { get; }

        public PersistentDriverState DriverState { get; }

        public ICaptureSource Source { get; }

        public CaptureCoordinator Coordinator { get; }

        public CaptureAuthority Authority { get; }

        public CaptureAuthority CreateRestartedAuthority() =>
            new(Coordinator, Source, new CaptureLeaseManager(), Boundary, Catalog);

        public (CaptureAuthority Authority, CaptureCoordinator Coordinator)
            CreateFreshRestartedAuthority(ICaptureSource? captureSource = null)
        {
            ICaptureSource source = captureSource ?? new PersistentCaptureSource(DriverState);
            var coordinator = new CaptureCoordinator(source, new SessionStoreFactory());
            return (
                new CaptureAuthority(
                    coordinator,
                    source,
                    new CaptureLeaseManager(),
                    Boundary,
                    Catalog),
                coordinator);
        }

        public async Task<ActiveLease> StartAiAsync(
            CaptureClientOwner owner,
            DateTimeOffset now)
        {
            PreparedLease pending = await Authority.PrepareAiStartAsync(
                owner,
                Devices(),
                "ai-run",
                now);
            return await Authority.CommitAiStartAsync(
                owner,
                pending.ReservationId,
                pending.Secret,
                now + TimeSpan.FromSeconds(1));
        }

        public async ValueTask DisposeAsync()
        {
            await Coordinator.DisposeAsync();
            Boundary.Dispose();
            try
            {
                Directory.Delete(Root, recursive: true);
            }
            catch (IOException)
            {
                // SQLite/AV teardown may briefly retain a handle; test content is under temp.
            }
            catch (UnauthorizedAccessException)
            {
                // Best-effort cleanup only.
            }
        }
    }

    private sealed class MemoryKeyRing : IProtectedKeyRing
    {
        private readonly ProtectedKeyMaterial _material = new(
            "test-key",
            Enumerable.Range(0, 32).Select(static value => (byte)value).ToArray());

        public ValueTask<ProtectedKeyMaterial> GetActiveKeyAsync(
            CancellationToken cancellationToken = default) =>
            ValueTask.FromResult(_material);

        public ValueTask<ProtectedKeyMaterial> GetKeyAsync(
            string keyId,
            DateTimeOffset now,
            CancellationToken cancellationToken = default) =>
            ValueTask.FromResult(_material);

        public ValueTask RetainKeyUntilAsync(
            string keyId,
            DateTimeOffset expiresAtUtc,
            CancellationToken cancellationToken = default) =>
            ValueTask.CompletedTask;
    }

    private sealed class BlockingKeyRing : IProtectedKeyRing
    {
        private readonly ProtectedKeyMaterial _material = new(
            "test-key",
            Enumerable.Range(0, 32).Select(static value => (byte)value).ToArray());
        private readonly TaskCompletionSource _blocked =
            new(TaskCreationOptions.RunContinuationsAsynchronously);
        private readonly TaskCompletionSource _release =
            new(TaskCreationOptions.RunContinuationsAsynchronously);
        private int _blockNext;

        public Task Blocked => _blocked.Task;

        public void BlockNextActiveKeyRead() => Volatile.Write(ref _blockNext, 1);

        public void Release() => _release.TrySetResult();

        public async ValueTask<ProtectedKeyMaterial> GetActiveKeyAsync(
            CancellationToken cancellationToken = default)
        {
            if (Interlocked.Exchange(ref _blockNext, 0) == 1)
            {
                _blocked.TrySetResult();
                await _release.Task.WaitAsync(cancellationToken);
            }

            return _material;
        }

        public ValueTask<ProtectedKeyMaterial> GetKeyAsync(
            string keyId,
            DateTimeOffset now,
            CancellationToken cancellationToken = default) =>
            ValueTask.FromResult(_material);

        public ValueTask RetainKeyUntilAsync(
            string keyId,
            DateTimeOffset expiresAtUtc,
            CancellationToken cancellationToken = default) =>
            ValueTask.CompletedTask;
    }

    private sealed class PersistentDriverState
    {
        private readonly object _gate = new();
        private CaptureState _state;

        public CaptureState State
        {
            get
            {
                lock (_gate)
                {
                    return _state;
                }
            }
        }

        public void Set(CaptureState state)
        {
            lock (_gate)
            {
                _state = state;
            }
        }
    }

    private sealed class PersistentCaptureSource(
        PersistentDriverState driverState) : ICaptureSource, ICaptureSourceStatisticsProvider
    {
        public ValueTask ConfigureAsync(
            CaptureState state,
            IReadOnlySet<ulong> deviceIds,
            CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            driverState.Set(state);
            return ValueTask.CompletedTask;
        }

        public ValueTask<CaptureSourceStatistics> GetStatisticsAsync(
            CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            return ValueTask.FromResult(new CaptureSourceStatistics(
                true,
                0,
                driverState.State,
                0,
                0,
                DateTimeOffset.UtcNow,
                null));
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

    private sealed class UnknownStatisticsCaptureSource(
        PersistentDriverState driverState) : ICaptureSource, ICaptureSourceStatisticsProvider
    {
        public int ConfigureCalls { get; private set; }

        public ValueTask ConfigureAsync(
            CaptureState state,
            IReadOnlySet<ulong> deviceIds,
            CancellationToken cancellationToken)
        {
            ConfigureCalls++;
            driverState.Set(state);
            return ValueTask.CompletedTask;
        }

        public ValueTask<CaptureSourceStatistics> GetStatisticsAsync(
            CancellationToken cancellationToken) =>
            ValueTask.FromResult(CaptureSourceStatistics.Unknown(
                "Scripted unknown driver state.",
                DateTimeOffset.UtcNow));

        public async IAsyncEnumerable<CaptureEvent> ReadAllAsync(
            [System.Runtime.CompilerServices.EnumeratorCancellation]
            CancellationToken cancellationToken)
        {
            await Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken);
            yield break;
        }

        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }

    private sealed class FailingRecoveryStopSource(
        PersistentDriverState driverState) : ICaptureSource, ICaptureSourceStatisticsProvider
    {
        public int ConfigureCalls { get; private set; }

        public ValueTask ConfigureAsync(
            CaptureState state,
            IReadOnlySet<ulong> deviceIds,
            CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            ConfigureCalls++;
            throw new IOException("Scripted startup driver-stop failure.");
        }

        public ValueTask<CaptureSourceStatistics> GetStatisticsAsync(
            CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            return ValueTask.FromResult(new CaptureSourceStatistics(
                true,
                0,
                driverState.State,
                0,
                0,
                DateTimeOffset.UtcNow,
                null));
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

    private sealed class FailingStartSource : ICaptureSource, ICaptureSourceStatisticsProvider
    {
        public ValueTask ConfigureAsync(
            CaptureState state,
            IReadOnlySet<ulong> deviceIds,
            CancellationToken cancellationToken)
        {
            if (state == CaptureState.Running)
            {
                throw new InvalidOperationException("Scripted driver start failure.");
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

        public ValueTask<CaptureSourceStatistics> GetStatisticsAsync(
            CancellationToken cancellationToken) =>
            ValueTask.FromResult(new CaptureSourceStatistics(
                true,
                0,
                CaptureState.Stopped,
                0,
                0,
                DateTimeOffset.UtcNow,
                null));

        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }
}
