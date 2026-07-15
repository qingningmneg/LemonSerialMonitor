using System.Collections.Immutable;
using System.Globalization;
using System.Runtime.Versioning;
using System.Text.Json;
using CommMonitor.Core.Ai;
using CommMonitor.Core.Models;
using CommMonitor.Core.Sessions;
using CommMonitor.Service.Ipc;
using CommMonitor.Service.Security;
using CommMonitor.Service.Sessions;
using Microsoft.Data.Sqlite;

namespace CommMonitor.Service.Tests.Sessions;

[SupportedOSPlatform("windows")]
public sealed class AiSessionServiceTests
{
    private static readonly DateTimeOffset Now =
        new(2026, 7, 13, 13, 0, 0, TimeSpan.Zero);

    [Fact]
    public async Task Read_uses_committed_sqlite_rows_and_returns_cursor_and_receipt()
    {
        await using var context = await SessionContext.CreateAsync(
            [CreateEvent(1, [0x01])]);
        await using SqliteConnection writer = await OpenWriterAsync(context.SessionPath);
        await using SqliteTransaction transaction = writer.BeginTransaction();
        await InsertUncommittedEventAsync(writer, transaction, sequence: 2);

        AiEventPage beforeCommit = await context.Service.ReadAsync(
            ReadRequest(context.SessionId, limit: 100),
            Now);

        Assert.Single(beforeCommit.Events);
        Assert.Equal("1", beforeCommit.Events[0].Sequence);
        Assert.StartsWith("c1.", beforeCommit.NextCursor, StringComparison.Ordinal);
        Assert.StartsWith("r1.", beforeCommit.ResumeReceipt, StringComparison.Ordinal);

        await transaction.CommitAsync();
        AiEventPage afterCommit = await context.Service.ReadAsync(
            ReadRequest(
                context.SessionId,
                cursor: beforeCommit.NextCursor,
                receipt: beforeCommit.ResumeReceipt,
                limit: 100),
            Now + TimeSpan.FromSeconds(1));

        Assert.Single(afterCommit.Events);
        Assert.Equal("2", afterCommit.Events[0].Sequence);
    }

    [Fact]
    public async Task Wait_uses_query_register_query_to_close_the_commit_race()
    {
        await using var context = await SessionContext.CreateAsync([]);
        context.Notifications.OnRegister = _ =>
            InsertCommittedEvent(context.SessionPath, sequence: 1, payload: 0x42);

        AiEventPage page = await context.Service.WaitAsync(
            "client-race",
            WaitRequest(context.SessionId, timeoutSeconds: 30),
            Now);

        Assert.Single(page.Events);
        Assert.Equal("Qg==", page.Events[0].PayloadBase64);
        Assert.Equal(0, context.Notifications.WaitCalls);
        Assert.Equal(1, context.Notifications.Registrations);
    }

    [Fact]
    public async Task Wait_reads_after_a_commit_notification_not_from_in_memory_events()
    {
        await using var context = await SessionContext.CreateAsync([]);
        using var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        Task<AiEventPage> waiting = context.Service.WaitAsync(
            "client-commit",
            WaitRequest(context.SessionId, timeoutSeconds: 30),
            Now,
            cancellation.Token);

        await context.Notifications.Registered.Task.WaitAsync(cancellation.Token);
        await context.Store.AppendAsync([CreateEvent(7, [0xA5])], cancellation.Token);
        context.Notifications.Publish(context.SessionId);

        AiEventPage page = await waiting;
        Assert.Single(page.Events);
        Assert.Equal("pQ==", page.Events[0].PayloadBase64);
        Assert.Equal(1, context.Notifications.WaitCalls);
    }

    [Fact]
    public async Task Only_one_wait_is_active_per_client()
    {
        await using var context = await SessionContext.CreateAsync([]);
        using var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        Task<AiEventPage> first = context.Service.WaitAsync(
            "same-client",
            WaitRequest(context.SessionId, timeoutSeconds: 30),
            Now,
            cancellation.Token);
        await context.Notifications.Registered.Task.WaitAsync(cancellation.Token);

        AiSessionException duplicate = await Assert.ThrowsAsync<AiSessionException>(() =>
            context.Service.WaitAsync(
                "same-client",
                WaitRequest(context.SessionId, timeoutSeconds: 1),
                Now,
                cancellation.Token));

        Assert.Equal(AiErrorCodes.LimitExceeded, duplicate.Code);
        cancellation.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => first);
    }

    [Fact]
    public async Task Wait_caps_the_requested_timeout_at_thirty_seconds()
    {
        await using var context = await SessionContext.CreateAsync([]);
        context.Notifications.CompleteImmediately = true;

        AiEventPage page = await context.Service.WaitAsync(
            "client-timeout",
            WaitRequest(context.SessionId, timeoutSeconds: 600),
            Now);

        Assert.Empty(page.Events);
        Assert.Equal(TimeSpan.FromSeconds(30), context.Notifications.LastTimeout);
    }

    [Fact]
    public async Task Read_enforces_the_one_thousand_event_hard_limit()
    {
        CaptureEvent[] events = Enumerable.Range(1, 1001)
            .Select(index => CreateEvent(index, [(byte)(index % 251)]))
            .ToArray();
        await using var context = await SessionContext.CreateAsync(events);

        AiSessionException excessive = await Assert.ThrowsAsync<AiSessionException>(() =>
            context.Service.ReadAsync(
                ReadRequest(context.SessionId, limit: 1001),
                Now));
        Assert.Equal(AiErrorCodes.LimitExceeded, excessive.Code);

        AiEventPage page = await context.Service.ReadAsync(
            ReadRequest(context.SessionId, limit: 1000),
            Now);
        Assert.Equal(1000, page.Events.Count);
        Assert.True(page.HasMore);
    }

    [Fact]
    public async Task Read_truncates_at_four_mib_without_losing_the_resume_position()
    {
        byte[] payload = Enumerable.Range(0, 4096)
            .Select(static index => (byte)(index % 251))
            .ToArray();
        CaptureEvent[] events = Enumerable.Range(1, 1000)
            .Select(index => CreateEvent(index, payload))
            .ToArray();
        await using var context = await SessionContext.CreateAsync(events);

        AiEventPage first = await context.Service.ReadAsync(
            ReadRequest(context.SessionId, limit: 1000),
            Now);
        byte[] encoded = JsonSerializer.SerializeToUtf8Bytes(first, AiJson.CreateOptions());

        Assert.InRange(first.Events.Count, 1, 999);
        Assert.True(first.HasMore);
        Assert.True(encoded.Length <= AiProtocol.MaximumResponseBytes);
        Assert.Equal(first.Events[^1].Sequence, first.ScannedThroughSequence);

        AiEventPage second = await context.Service.ReadAsync(
            ReadRequest(
                context.SessionId,
                cursor: first.NextCursor,
                receipt: first.ResumeReceipt,
                limit: 1000),
            Now + TimeSpan.FromSeconds(1));
        Assert.NotEmpty(second.Events);
        Assert.Equal(
            long.Parse(first.ScannedThroughSequence, CultureInfo.InvariantCulture) + 1,
            long.Parse(second.Events[0].Sequence, CultureInfo.InvariantCulture));
    }

    [Fact]
    public async Task Read_cursor_is_bound_to_the_normalized_filter()
    {
        await using var context = await SessionContext.CreateAsync(
            [CreateEvent(1, [0x41, 0x42])]);
        var firstFilter = new AiEventFilter(
            DeviceIds: null,
            Kinds: null,
            FromUtc: null,
            ToUtc: null,
            IncludeHex: true);
        AiEventPage first = await context.Service.ReadAsync(
            ReadRequest(context.SessionId, limit: 100, filter: firstFilter),
            Now);
        Assert.Equal("41 42", first.Events[0].PayloadHex);

        var changedFilter = firstFilter with { IncludeHex = false };
        AiCursorException mismatch = await Assert.ThrowsAsync<AiCursorException>(() =>
            context.Service.ReadAsync(
                ReadRequest(
                    context.SessionId,
                    cursor: first.NextCursor,
                    receipt: first.ResumeReceipt,
                    limit: 100,
                    filter: changedFilter),
                Now + TimeSpan.FromSeconds(1)));
        Assert.Equal(AiErrorCodes.CursorFilterMismatch, mismatch.Code);
    }

    [Theory]
    [InlineData("json")]
    [InlineData("jsonl")]
    [InlineData("csv")]
    [InlineData("txt")]
    [InlineData("raw")]
    public async Task Export_creates_unique_service_managed_files_without_overwrite(
        string format)
    {
        await using var context = await SessionContext.CreateAsync(
            [CreateEvent(1, [0x00, 0x80, 0xFF])]);
        var request = new ExportSessionRequest(context.SessionId, format, "safe label");

        AiExportDto first = await context.Service.ExportAsync(request, Now);
        byte[] original = await File.ReadAllBytesAsync(first.FullPath);
        AiExportDto second = await context.Service.ExportAsync(
            request,
            Now + TimeSpan.FromSeconds(1));

        Assert.Equal(context.Boundary.ExportRoot, Path.GetDirectoryName(first.FullPath));
        Assert.Equal(context.Boundary.ExportRoot, Path.GetDirectoryName(second.FullPath));
        Assert.NotEqual(first.FullPath, second.FullPath);
        Assert.Equal(original, await File.ReadAllBytesAsync(first.FullPath));
        Assert.True(long.Parse(first.ByteLength, CultureInfo.InvariantCulture) > 0);
        Assert.Equal(64, first.Sha256.Length);
        Assert.Equal(format, first.Format);
    }

    [Fact]
    public async Task Export_rejects_unknown_formats_and_directory_like_labels()
    {
        await using var context = await SessionContext.CreateAsync(
            [CreateEvent(1, [0x01])]);

        await Assert.ThrowsAsync<ArgumentException>(() => context.Service.ExportAsync(
            new ExportSessionRequest(context.SessionId, "xml", "label"),
            Now));
        await Assert.ThrowsAsync<ArgumentException>(() => context.Service.ExportAsync(
            new ExportSessionRequest(context.SessionId, "json", "..\\outside"),
            Now));
        Assert.Empty(Directory.EnumerateFiles(
            Path.GetDirectoryName(context.Boundary.ExportRoot)!));
    }

    [Fact]
    public async Task Sqlite_export_snapshot_freezes_the_committed_upper_bound_while_writer_grows()
    {
        await using var context = await SessionContext.CreateAsync(
            [CreateEvent(1, [0x11])]);
        await using SqliteSessionExportSnapshot snapshot =
            await SqliteSessionExportSnapshot.OpenAsync(context.SessionPath);

        await context.Store.AppendAsync([CreateEvent(2, [0x22])]);
        IReadOnlyList<CaptureEvent> first = await snapshot.ReadNextAsync(512);
        IReadOnlyList<CaptureEvent> exhausted = await snapshot.ReadNextAsync(512);

        CaptureEvent captured = Assert.Single(first);
        Assert.Equal(1, captured.Sequence);
        Assert.Equal(1, snapshot.MaximumSequence);
        Assert.Empty(exhausted);
    }

    [Fact]
    public async Task Export_streams_multiple_pages_with_one_csv_header_and_one_json_array()
    {
        CaptureEvent[] events = Enumerable.Range(1, 1200)
            .Select(index => CreateEvent(index, [(byte)(index % 251)]))
            .ToArray();
        await using var context = await SessionContext.CreateAsync(events);

        AiExportDto csv = await context.Service.ExportAsync(
            new ExportSessionRequest(context.SessionId, "csv", "multipage"),
            Now);
        string csvText = await File.ReadAllTextAsync(csv.FullPath);
        Assert.Equal(
            1,
            csvText.Split(
                "Sequence,Timestamp,Port,Direction,Process,Data",
                StringSplitOptions.None).Length - 1);
        Assert.Equal(1201, csvText.Split("\r\n", StringSplitOptions.RemoveEmptyEntries).Length);

        AiExportDto json = await context.Service.ExportAsync(
            new ExportSessionRequest(context.SessionId, "json", "multipage"),
            Now + TimeSpan.FromSeconds(1));
        using JsonDocument document = JsonDocument.Parse(
            await File.ReadAllBytesAsync(json.FullPath));
        Assert.Equal(JsonValueKind.Array, document.RootElement.ValueKind);
        Assert.Equal(1200, document.RootElement.GetArrayLength());
    }

    [Fact]
    public async Task Unfinished_run_is_never_reported_complete_even_when_start_stats_are_known()
    {
        await using var context = await SessionContext.CreateAsync(
            [CreateEvent(1, [0x11])]);
        var known = new DriverStatsSnapshot(
            true,
            0,
            CaptureState.Running,
            0,
            1,
            Now,
            null);
        await context.Store.UpsertRunAsync(new CaptureRunRecord(
            "open-run",
            context.SessionId,
            1,
            "service-before-restart",
            "AI",
            "S-1-5-21-1000",
            ["0000000000000011"],
            0,
            null,
            Now,
            null,
            known,
            null,
            0,
            0,
            true,
            false,
            null));

        AiEventPage page = await context.Service.ReadAsync(
            ReadRequest(context.SessionId),
            Now + TimeSpan.FromSeconds(1));

        Assert.False(page.Integrity.StatsKnown);
        Assert.False(page.Integrity.CompleteForReturnedRange);
        Assert.Contains(AiErrorCodes.IntegrityUnknown, page.Warnings);
    }

    [Fact]
    public async Task List_returns_opaque_session_summaries_without_accepting_paths()
    {
        await using var context = await SessionContext.CreateAsync(
            [CreateEvent(1, [0x01])],
            displayName: "catalog-entry");

        AiSessionPage page = await context.Service.ListAsync(
            new ListSessionsRequest(null, 100));

        AiSessionSummaryDto summary = Assert.Single(page.Sessions);
        Assert.Equal(context.SessionId, summary.SessionId);
        Assert.Equal("catalog-entry", summary.DisplayName);
        Assert.Equal(3, summary.SchemaVersion);
        Assert.Equal("1", summary.EventCount);
        Assert.DoesNotContain(context.SessionPath, summary.SessionId, StringComparison.OrdinalIgnoreCase);
    }

    private static ReadEventsRequest ReadRequest(
        string sessionId,
        string? cursor = null,
        string? receipt = null,
        int limit = 100,
        AiEventFilter? filter = null) =>
        new(
            sessionId,
            cursor,
            receipt,
            AfterSequence: null,
            AllowUnverifiedSeek: false,
            limit,
            filter);

    private static WaitEventsRequest WaitRequest(
        string sessionId,
        int timeoutSeconds) =>
        new(
            sessionId,
            Cursor: null,
            ResumeReceipt: null,
            AfterSequence: null,
            AllowUnverifiedSeek: false,
            Limit: 100,
            Filter: null,
            timeoutSeconds);

    private static CaptureEvent CreateEvent(
        long wireSequence,
        IReadOnlyList<byte> payload) =>
        new(
            wireSequence,
            wireSequence * 10,
            0x11,
            42,
            CaptureKind.Read,
            0,
            0,
            payload.Count,
            payload.Count,
            CaptureFlags.InputPayload,
            ImmutableArray.CreateRange(payload))
        {
            Timestamp = Now + TimeSpan.FromMilliseconds(wireSequence),
            PortName = "COM1",
            ProcessName = "reader.exe",
        };

    private static async Task<SqliteConnection> OpenWriterAsync(string path)
    {
        var connection = new SqliteConnection(
            new SqliteConnectionStringBuilder
            {
                DataSource = path,
                Mode = SqliteOpenMode.ReadWrite,
                Pooling = false,
            }.ToString());
        await connection.OpenAsync();
        return connection;
    }

    private static async Task InsertUncommittedEventAsync(
        SqliteConnection connection,
        SqliteTransaction transaction,
        long sequence)
    {
        await using SqliteCommand command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = """
            INSERT INTO events(
             sequence, wire_sequence, qpc_ticks, timestamp_utc, device_id, port_name,
             process_id, process_name, kind, ioctl_code, nt_status,
             requested_length, completed_length, flags, payload)
            VALUES(
             $sequence, $wire_sequence, $qpc_ticks, $timestamp_utc, $device_id, 'COM1',
             42, 'writer.exe', $kind, 0, 0, 1, 1, 0, X'7F');
            """;
        command.Parameters.AddWithValue("$sequence", sequence);
        command.Parameters.AddWithValue("$wire_sequence", sequence);
        command.Parameters.AddWithValue("$qpc_ticks", sequence * 10);
        command.Parameters.AddWithValue(
            "$timestamp_utc",
            (Now + TimeSpan.FromSeconds(sequence)).ToString("O", CultureInfo.InvariantCulture));
        command.Parameters.AddWithValue("$device_id", 0x11);
        command.Parameters.AddWithValue("$kind", (long)CaptureKind.Read);
        await command.ExecuteNonQueryAsync();
    }

    private static void InsertCommittedEvent(
        string path,
        long sequence,
        byte payload)
    {
        using var connection = new SqliteConnection(
            new SqliteConnectionStringBuilder
            {
                DataSource = path,
                Mode = SqliteOpenMode.ReadWrite,
                Pooling = false,
            }.ToString());
        connection.Open();
        using SqliteCommand command = connection.CreateCommand();
        command.CommandText = """
            INSERT INTO events(
             sequence, wire_sequence, qpc_ticks, timestamp_utc, device_id, port_name,
             process_id, process_name, kind, ioctl_code, nt_status,
             requested_length, completed_length, flags, payload)
            VALUES(
             $sequence, $wire_sequence, $qpc_ticks, $timestamp_utc, $device_id, 'COM1',
             42, 'writer.exe', $kind, 0, 0, 1, 1, 0, $payload);
            """;
        command.Parameters.AddWithValue("$sequence", sequence);
        command.Parameters.AddWithValue("$wire_sequence", sequence);
        command.Parameters.AddWithValue("$qpc_ticks", sequence * 10);
        command.Parameters.AddWithValue(
            "$timestamp_utc",
            (Now + TimeSpan.FromSeconds(sequence)).ToString("O", CultureInfo.InvariantCulture));
        command.Parameters.AddWithValue("$device_id", 0x11);
        command.Parameters.AddWithValue("$kind", (long)CaptureKind.Read);
        command.Parameters.AddWithValue("$payload", new[] { payload });
        command.ExecuteNonQuery();
    }

    private sealed class SessionContext : IAsyncDisposable
    {
        private SessionContext(
            string root,
            ServiceStorageBoundary boundary,
            SessionStore store,
            string sessionPath,
            string sessionId,
            TestCommitNotifications notifications,
            AiSessionService service)
        {
            Root = root;
            Boundary = boundary;
            Store = store;
            SessionPath = sessionPath;
            SessionId = sessionId;
            Notifications = notifications;
            Service = service;
        }

        public string Root { get; }

        public ServiceStorageBoundary Boundary { get; }

        public SessionStore Store { get; }

        public string SessionPath { get; }

        public string SessionId { get; }

        public TestCommitNotifications Notifications { get; }

        public AiSessionService Service { get; }

        public static async Task<SessionContext> CreateAsync(
            IReadOnlyList<CaptureEvent> events,
            string displayName = "session")
        {
            string root = Path.Combine(
                Path.GetTempPath(),
                "CommMonitor-AiSessionServiceTests",
                Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(root);
            ServiceStorageBoundary boundary = ServiceStorageBoundary.Open(
                root,
                Path.Combine(root, "Sessions"),
                Path.Combine(root, "Exports"));
            string sessionPath = Path.Combine(
                boundary.SessionRoot,
                displayName + ".cmsession");
            var store = new SessionStore(sessionPath);
            await store.InitializeAsync();
            if (events.Count > 0)
            {
                await store.AppendAsync(events);
            }

            boundary.VerifySessionPath(sessionPath);
            var keyRing = new MemoryKeyRing();
            var catalog = new SessionCatalog(boundary, keyRing);
            SessionCatalogItem item = Assert.Single(await catalog.ListAsync());
            var notifications = new TestCommitNotifications();
            var service = new AiSessionService(
                catalog,
                new CursorProtector(keyRing),
                boundary,
                notifications);
            return new SessionContext(
                root,
                boundary,
                store,
                sessionPath,
                item.SessionId,
                notifications,
                service);
        }

        public ValueTask DisposeAsync()
        {
            Boundary.Dispose();
            try
            {
                Directory.Delete(Root, recursive: true);
            }
            catch (IOException)
            {
                // Best-effort temp cleanup.
            }
            catch (UnauthorizedAccessException)
            {
                // Best-effort temp cleanup.
            }

            return ValueTask.CompletedTask;
        }
    }

    private sealed class MemoryKeyRing : IProtectedKeyRing
    {
        private readonly ProtectedKeyMaterial _material = new(
            "test-key",
            Enumerable.Range(1, 32).Select(static value => (byte)value).ToArray());

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

    private sealed class TestCommitNotifications : ICommitNotificationSource
    {
        private readonly object _gate = new();
        private readonly List<TestRegistration> _registrations = [];

        public TaskCompletionSource Registered { get; } =
            new(TaskCreationOptions.RunContinuationsAsynchronously);

        public Action<string>? OnRegister { get; set; }

        public bool CompleteImmediately { get; set; }

        public int Registrations { get; private set; }

        public int WaitCalls { get; private set; }

        public TimeSpan? LastTimeout { get; private set; }

        public ICommitRegistration Register(string sessionId)
        {
            var registration = new TestRegistration(this, sessionId);
            lock (_gate)
            {
                _registrations.Add(registration);
                Registrations++;
            }

            OnRegister?.Invoke(sessionId);
            Registered.TrySetResult();
            return registration;
        }

        public void Publish(string sessionId)
        {
            TestRegistration[] registrations;
            lock (_gate)
            {
                registrations = _registrations
                    .Where(item => item.SessionId == sessionId)
                    .ToArray();
            }

            foreach (TestRegistration registration in registrations)
            {
                registration.Signal();
            }
        }

        private void Remove(TestRegistration registration)
        {
            lock (_gate)
            {
                _registrations.Remove(registration);
            }
        }

        private async Task<bool> WaitAsync(
            TestRegistration registration,
            TimeSpan timeout,
            CancellationToken cancellationToken)
        {
            WaitCalls++;
            LastTimeout = timeout;
            if (CompleteImmediately)
            {
                return false;
            }

            try
            {
                return await registration.SignalTask.WaitAsync(timeout, cancellationToken);
            }
            catch (TimeoutException)
            {
                return false;
            }
        }

        private sealed class TestRegistration(
            TestCommitNotifications owner,
            string sessionId) : ICommitRegistration
        {
            private readonly TaskCompletionSource<bool> _signal =
                new(TaskCreationOptions.RunContinuationsAsynchronously);
            private int _disposed;

            public string SessionId { get; } = sessionId;

            public Task<bool> SignalTask => _signal.Task;

            public Task<bool> WaitAsync(
                TimeSpan timeout,
                CancellationToken cancellationToken) =>
                owner.WaitAsync(this, timeout, cancellationToken);

            public void Signal() => _signal.TrySetResult(true);

            public ValueTask DisposeAsync()
            {
                if (Interlocked.Exchange(ref _disposed, 1) == 0)
                {
                    owner.Remove(this);
                }

                return ValueTask.CompletedTask;
            }
        }
    }
}
