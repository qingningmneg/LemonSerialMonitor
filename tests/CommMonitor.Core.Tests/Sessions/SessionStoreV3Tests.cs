using System.Collections.Immutable;
using System.Globalization;
using System.Text.Json;
using CommMonitor.Core.Ai;
using CommMonitor.Core.Models;
using CommMonitor.Core.Sessions;
using Microsoft.Data.Sqlite;

namespace CommMonitor.Core.Tests.Sessions;

public sealed class SessionStoreV3Tests
{
    [Fact]
    public async Task InitializeAsync_creates_schema_v3_for_a_new_session()
    {
        string directory = CreateTemporaryDirectory();
        string path = Path.Combine(directory, $"{Guid.NewGuid():N}.cmsession");

        try
        {
            var store = new SessionStore(path);

            await store.InitializeAsync(CancellationToken.None);

            Assert.Equal(3, await store.GetSchemaVersionAsync(CancellationToken.None));
            Assert.Equal(0, await store.CountRunsAsync(CancellationToken.None));
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Theory]
    [InlineData(1)]
    [InlineData(2)]
    public async Task InitializeAsync_migrates_legacy_sessions_directly_to_v3(int version)
    {
        string directory = CreateTemporaryDirectory();
        string path = Path.Combine(directory, $"{Guid.NewGuid():N}.cmsession");

        try
        {
            await CreateVersionedSessionAsync(path, version, includeEvent: true);
            var store = new SessionStore(path);

            await store.InitializeAsync(CancellationToken.None);

            Assert.Equal(3, await store.GetSchemaVersionAsync(CancellationToken.None));
            Assert.Equal(0, await store.CountRunsAsync(CancellationToken.None));
            CaptureEvent captureEvent = Assert.Single(
                await store.ReadAfterAsync(0, 100, CancellationToken.None));
            Assert.Equal(42, captureEvent.Sequence);
            Assert.Equal(version == 1 ? 42 : 7, captureEvent.WireSequence);
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public async Task InitializeAsync_is_idempotent_for_an_existing_v3_session()
    {
        string directory = CreateTemporaryDirectory();
        string path = Path.Combine(directory, $"{Guid.NewGuid():N}.cmsession");

        try
        {
            await CreateVersionedSessionAsync(path, version: 3, includeEvent: false);
            var store = new SessionStore(path);

            await store.InitializeAsync(CancellationToken.None);
            await store.InitializeAsync(CancellationToken.None);

            Assert.Equal(3, await store.GetSchemaVersionAsync(CancellationToken.None));
            Assert.Equal(0, await store.CountRunsAsync(CancellationToken.None));
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public async Task InitializeAsync_never_writes_schema_version_2_while_migrating_v1()
    {
        string directory = CreateTemporaryDirectory();
        string path = Path.Combine(directory, $"{Guid.NewGuid():N}.cmsession");

        try
        {
            await CreateVersionedSessionAsync(path, version: 1, includeEvent: false);
            await using (var connection = new SqliteConnection($"Data Source={path};Pooling=False"))
            {
                await connection.OpenAsync(CancellationToken.None);
                await using SqliteCommand command = connection.CreateCommand();
                command.CommandText = """
                    CREATE TRIGGER reject_schema_version_2
                    BEFORE UPDATE OF value ON metadata
                    WHEN NEW.key = 'schema_version' AND NEW.value = '2'
                    BEGIN
                        SELECT RAISE(ABORT, 'schema version 2 must not be written');
                    END;
                    """;
                await command.ExecuteNonQueryAsync(CancellationToken.None);
            }

            var store = new SessionStore(path);
            await store.InitializeAsync(CancellationToken.None);

            Assert.Equal(3, await store.GetSchemaVersionAsync(CancellationToken.None));
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public async Task InitializeAsync_rejects_a_future_schema_without_downgrading_it()
    {
        string directory = CreateTemporaryDirectory();
        string path = Path.Combine(directory, $"{Guid.NewGuid():N}.cmsession");

        try
        {
            await CreateVersionedSessionAsync(path, version: 4, includeEvent: false);
            var store = new SessionStore(path);

            await Assert.ThrowsAsync<InvalidOperationException>(
                () => store.InitializeAsync(CancellationToken.None));

            Assert.Equal("4", await ReadMetadataVersionAsync(path));
            Assert.False(await TableExistsAsync(path, "capture_runs"));
            Assert.False(await TableExistsAsync(path, "integrity_markers"));
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public async Task InitializeAsync_rejects_future_schema_before_changing_journal_or_sidecars()
    {
        string directory = CreateTemporaryDirectory();
        string path = Path.Combine(directory, $"{Guid.NewGuid():N}.cmsession");
        string[] sidecarPaths = [$"{path}-wal", $"{path}-shm"];

        try
        {
            await CreateVersionedSessionAsync(path, version: 4, includeEvent: false);
            string journalModeBefore = await ReadJournalModeAsync(path);
            bool[] sidecarsBefore = sidecarPaths.Select(File.Exists).ToArray();
            var store = new SessionStore(path);

            await Assert.ThrowsAsync<InvalidOperationException>(
                () => store.InitializeAsync(CancellationToken.None));

            Assert.Equal(journalModeBefore, await ReadJournalModeAsync(path));
            Assert.Equal(sidecarsBefore, sidecarPaths.Select(File.Exists).ToArray());
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public async Task InitializeAsync_preserves_every_v2_event_column_and_payload_byte()
    {
        string directory = CreateTemporaryDirectory();
        string path = Path.Combine(directory, $"{Guid.NewGuid():N}.cmsession");

        try
        {
            await CreateVersionedSessionAsync(path, version: 2, includeEvent: true);
            RawEventSnapshot before = await ReadRawEventAsync(path);

            var store = new SessionStore(path);
            await store.InitializeAsync(CancellationToken.None);

            RawEventSnapshot after = await ReadRawEventAsync(path);
            Assert.Equal(before, after);
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public async Task AppendBatchAsync_rolls_back_events_when_a_real_marker_trigger_aborts()
    {
        string directory = CreateTemporaryDirectory();
        string path = Path.Combine(directory, $"{Guid.NewGuid():N}.cmsession");
        const string runId = "run-trigger";

        try
        {
            var store = new SessionStore(path);
            await store.InitializeAsync(CancellationToken.None);
            await store.UpsertRunAsync(CreateRun(runId), CancellationToken.None);
            await InstallFailingMarkerTriggerAsync(path);
            CaptureEvent[] events = [CreateEvent(10, [0xA1]), CreateEvent(11, [0xB2])];
            IntegrityMarker[] markers =
            [
                new(null, runId, 7, "driver-drop", Utc(5), 0, 2, "DRIVER_DROPPED"),
            ];

            await Assert.ThrowsAsync<SqliteException>(
                () => store.AppendBatchAsync(
                    new PersistBatch(events, markers),
                    CancellationToken.None));

            var reader = new ReadOnlySessionReader(path);
            Assert.Empty(await reader.ReadAfterAsync(0, 100, CancellationToken.None));
            Assert.Empty(await reader.ReadMarkersAsync(runId, CancellationToken.None));
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public async Task AppendBatchAsync_enforces_marker_foreign_keys_and_rolls_back_events()
    {
        string directory = CreateTemporaryDirectory();
        string path = Path.Combine(directory, $"{Guid.NewGuid():N}.cmsession");

        try
        {
            var store = new SessionStore(path);
            await store.InitializeAsync(CancellationToken.None);
            var marker = new IntegrityMarker(
                null,
                "missing-run",
                1,
                "gap",
                Utc(1),
                0,
                1,
                "MISSING_RUN");

            await Assert.ThrowsAsync<SqliteException>(
                () => store.AppendBatchAsync(
                    new PersistBatch([CreateEvent(1, [0x01])], [marker]),
                    CancellationToken.None));

            Assert.Equal(0, await store.GetLastSequenceAsync(CancellationToken.None));
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public async Task AppendBatchAsync_rolls_back_events_when_marker_generation_differs_from_run()
    {
        string directory = CreateTemporaryDirectory();
        string path = Path.Combine(directory, $"{Guid.NewGuid():N}.cmsession");
        const string runId = "run-generation";

        try
        {
            var store = new SessionStore(path);
            await store.InitializeAsync(CancellationToken.None);
            CaptureRunRecord run = CreateRun(runId);
            await store.UpsertRunAsync(run, CancellationToken.None);
            var marker = new IntegrityMarker(
                null,
                runId,
                run.Generation + 1,
                "generation-mismatch",
                Utc(1),
                0,
                1,
                "GENERATION_MISMATCH");

            await Assert.ThrowsAsync<SqliteException>(
                () => store.AppendBatchAsync(
                    new PersistBatch([CreateEvent(1, [0x01])], [marker]),
                    CancellationToken.None));

            var reader = new ReadOnlySessionReader(path);
            Assert.Empty(await reader.ReadAfterAsync(0, 100, CancellationToken.None));
            Assert.Empty(await reader.ReadMarkersAsync(runId, CancellationToken.None));
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public async Task UpsertRunAsync_round_trips_records_and_uses_deterministic_strict_json()
    {
        string directory = CreateTemporaryDirectory();
        string path = Path.Combine(directory, $"{Guid.NewGuid():N}.cmsession");

        try
        {
            var store = new SessionStore(path);
            await store.InitializeAsync(CancellationToken.None);
            CaptureRunRecord run = CreateRun("run-json") with
            {
                SelectedDeviceIds = ["1", "fedcba9876543210"],
            };

            await store.UpsertRunAsync(run, CancellationToken.None);

            (string devicesJson, string startStatsJson) = await ReadRunJsonAsync(path, run.RunId);
            Assert.Equal("[\"0000000000000001\",\"FEDCBA9876543210\"]", devicesJson);
            Assert.Equal(
                JsonSerializer.Serialize(run.StartStats, AiJson.CreateOptions()),
                startStatsJson);
            CaptureRunRecord persisted = Assert.Single(
                await store.ReadRunsAsync(CancellationToken.None));
            Assert.Equal(
                run with { SelectedDeviceIds = persisted.SelectedDeviceIds },
                persisted);
            Assert.Equal(
                ["0000000000000001", "FEDCBA9876543210"],
                persisted.SelectedDeviceIds);
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public async Task UpsertRunAsync_rejects_conflicting_run_identity_and_preserves_the_original()
    {
        string directory = CreateTemporaryDirectory();
        string path = Path.Combine(directory, $"{Guid.NewGuid():N}.cmsession");

        try
        {
            var store = new SessionStore(path);
            await store.InitializeAsync(CancellationToken.None);
            CaptureRunRecord original = CreateRun("stable-run");
            await store.UpsertRunAsync(original, CancellationToken.None);

            CaptureRunRecord[] conflicts =
            [
                original with { SessionId = "other-session" },
                original with { Generation = original.Generation + 1 },
                original with { ServiceInstanceId = "other-service" },
            ];
            foreach (CaptureRunRecord conflict in conflicts)
            {
                await Assert.ThrowsAsync<InvalidOperationException>(
                    () => store.UpsertRunAsync(conflict, CancellationToken.None));
            }

            CaptureRunRecord persisted = Assert.Single(
                await store.ReadRunsAsync(CancellationToken.None));
            Assert.Equal(
                original with { SelectedDeviceIds = persisted.SelectedDeviceIds },
                persisted);
            Assert.Equal(original.SelectedDeviceIds, persisted.SelectedDeviceIds);
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public async Task ClearAsync_deletes_markers_runs_and_events_together()
    {
        string directory = CreateTemporaryDirectory();
        string path = Path.Combine(directory, $"{Guid.NewGuid():N}.cmsession");
        const string runId = "run-clear";

        try
        {
            var store = new SessionStore(path);
            await store.InitializeAsync(CancellationToken.None);
            await store.UpsertRunAsync(CreateRun(runId), CancellationToken.None);
            IReadOnlyList<CaptureEvent> persisted = await store.AppendBatchAsync(
                new PersistBatch(
                    [CreateEvent(91, [0x91])],
                    [new IntegrityMarker(null, runId, 7, "gap", Utc(2), 0, 1, "GAP")]),
                CancellationToken.None);
            Assert.Equal(1, await store.GetLastSequenceAsync(CancellationToken.None));
            Assert.Equal(1, Assert.Single(persisted).Sequence);

            await store.ClearAsync(CancellationToken.None);

            Assert.Empty(await store.ReadAfterAsync(0, 100, CancellationToken.None));
            Assert.Empty(await store.ReadRunsAsync(CancellationToken.None));
            Assert.Empty(await store.ReadMarkersAsync(runId, CancellationToken.None));
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    private static async Task CreateVersionedSessionAsync(
        string path,
        int version,
        bool includeEvent)
    {
        await using var connection = new SqliteConnection($"Data Source={path};Pooling=False");
        await connection.OpenAsync(CancellationToken.None);
        await using SqliteCommand command = connection.CreateCommand();
        string wireColumn = version == 1
            ? string.Empty
            : "wire_sequence INTEGER NOT NULL,";
        string wireName = version == 1 ? string.Empty : "wire_sequence,";
        string wireValue = version == 1 ? string.Empty : "7,";
        string eventSql = includeEvent
            ? $"""
                INSERT INTO events(
                 sequence, {wireName} qpc_ticks, timestamp_utc, device_id, port_name,
                 process_id, process_name, kind, ioctl_code, nt_status,
                 requested_length, completed_length, flags, payload)
                VALUES(
                 42, {wireValue} 420, '2026-07-10T00:00:00.0000000+00:00', -81985529216486896, 'COM''7',
                 123, 'legacy.exe', 2, 2864434397, -1073741823,
                 4, 3, 3, X'00A1FF');
                """
            : string.Empty;
        string v3Sql = version == 3
            ? """
                CREATE TABLE capture_runs(
                 run_id TEXT PRIMARY KEY,
                 session_id TEXT NOT NULL,
                 generation INTEGER NOT NULL,
                 service_instance_id TEXT NOT NULL,
                 owner_type TEXT NOT NULL,
                 owner_sid TEXT NOT NULL,
                 selected_devices_json TEXT NOT NULL,
                 start_after_sequence INTEGER NOT NULL,
                 end_sequence INTEGER NULL,
                 started_utc TEXT NOT NULL,
                 stopped_utc TEXT NULL,
                 start_stats_json TEXT NOT NULL,
                 end_stats_json TEXT NULL,
                 service_dropped INTEGER NOT NULL DEFAULT 0,
                 truncation_count INTEGER NOT NULL DEFAULT 0,
                 stats_known INTEGER NOT NULL,
                 clean_shutdown INTEGER NOT NULL DEFAULT 0,
                 end_reason TEXT NULL,
                 UNIQUE(run_id, generation)
                );
                CREATE TABLE integrity_markers(
                 marker_id INTEGER PRIMARY KEY AUTOINCREMENT,
                 run_id TEXT NOT NULL,
                 generation INTEGER NOT NULL,
                 marker_type TEXT NOT NULL,
                 occurred_utc TEXT NOT NULL,
                 after_sequence INTEGER NOT NULL,
                 count_delta INTEGER NOT NULL,
                 code TEXT NOT NULL,
                 FOREIGN KEY(run_id, generation) REFERENCES capture_runs(run_id, generation)
                );
                CREATE INDEX ix_integrity_run_sequence
                 ON integrity_markers(run_id, after_sequence);
                """
            : string.Empty;
        command.CommandText = $"""
            CREATE TABLE metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL);
            INSERT INTO metadata(key, value) VALUES('schema_version', '{version}');
            CREATE TABLE events(
             sequence INTEGER PRIMARY KEY,
             {wireColumn}
             qpc_ticks INTEGER NOT NULL,
             timestamp_utc TEXT NOT NULL,
             device_id INTEGER NOT NULL,
             port_name TEXT NOT NULL,
             process_id INTEGER NOT NULL,
             process_name TEXT NOT NULL,
             kind INTEGER NOT NULL,
             ioctl_code INTEGER NOT NULL,
             nt_status INTEGER NOT NULL,
             requested_length INTEGER NOT NULL,
             completed_length INTEGER NOT NULL,
             flags INTEGER NOT NULL,
             payload BLOB NOT NULL
            );
            {eventSql}
            {v3Sql}
            """;
        await command.ExecuteNonQueryAsync(CancellationToken.None);
    }

    private static async Task InstallFailingMarkerTriggerAsync(string path)
    {
        await using var connection = new SqliteConnection($"Data Source={path};Pooling=False");
        await connection.OpenAsync(CancellationToken.None);
        await using SqliteCommand command = connection.CreateCommand();
        command.CommandText = """
            CREATE TRIGGER fail_marker_insert
            BEFORE INSERT ON integrity_markers
            BEGIN
                SELECT RAISE(ABORT, 'forced marker failure');
            END;
            """;
        await command.ExecuteNonQueryAsync(CancellationToken.None);
    }

    private static async Task<string?> ReadMetadataVersionAsync(string path)
    {
        await using var connection = new SqliteConnection($"Data Source={path};Pooling=False");
        await connection.OpenAsync(CancellationToken.None);
        await using SqliteCommand command = connection.CreateCommand();
        command.CommandText = "SELECT value FROM metadata WHERE key = 'schema_version';";
        return (string?)await command.ExecuteScalarAsync(CancellationToken.None);
    }

    private static async Task<string> ReadJournalModeAsync(string path)
    {
        var connectionString = new SqliteConnectionStringBuilder
        {
            DataSource = path,
            Mode = SqliteOpenMode.ReadOnly,
            Pooling = false,
        }.ToString();
        await using var connection = new SqliteConnection(connectionString);
        await connection.OpenAsync(CancellationToken.None);
        await using SqliteCommand command = connection.CreateCommand();
        command.CommandText = "PRAGMA journal_mode;";
        return (string)(await command.ExecuteScalarAsync(CancellationToken.None))!;
    }

    private static async Task<bool> TableExistsAsync(string path, string tableName)
    {
        await using var connection = new SqliteConnection($"Data Source={path};Pooling=False");
        await connection.OpenAsync(CancellationToken.None);
        await using SqliteCommand command = connection.CreateCommand();
        command.CommandText = """
            SELECT COUNT(*)
            FROM sqlite_master
            WHERE type = 'table' AND name = $name;
            """;
        command.Parameters.AddWithValue("$name", tableName);
        return (long)(await command.ExecuteScalarAsync(CancellationToken.None))! != 0;
    }

    private static async Task<RawEventSnapshot> ReadRawEventAsync(string path)
    {
        await using var connection = new SqliteConnection($"Data Source={path};Pooling=False");
        await connection.OpenAsync(CancellationToken.None);
        await using SqliteCommand command = connection.CreateCommand();
        command.CommandText = """
            SELECT sequence, wire_sequence, qpc_ticks, timestamp_utc, device_id,
                   port_name, process_id, process_name, kind, ioctl_code, nt_status,
                   requested_length, completed_length, flags, hex(payload)
            FROM events;
            """;
        await using SqliteDataReader reader = await command.ExecuteReaderAsync(CancellationToken.None);
        Assert.True(await reader.ReadAsync(CancellationToken.None));
        return new RawEventSnapshot(
            reader.GetInt64(0),
            reader.GetInt64(1),
            reader.GetInt64(2),
            reader.GetString(3),
            reader.GetInt64(4),
            reader.GetString(5),
            reader.GetInt64(6),
            reader.GetString(7),
            reader.GetInt64(8),
            reader.GetInt64(9),
            reader.GetInt64(10),
            reader.GetInt64(11),
            reader.GetInt64(12),
            reader.GetInt64(13),
            reader.GetString(14));
    }

    private static async Task<(string DevicesJson, string StartStatsJson)> ReadRunJsonAsync(
        string path,
        string runId)
    {
        await using var connection = new SqliteConnection($"Data Source={path};Pooling=False");
        await connection.OpenAsync(CancellationToken.None);
        await using SqliteCommand command = connection.CreateCommand();
        command.CommandText = """
            SELECT selected_devices_json, start_stats_json
            FROM capture_runs
            WHERE run_id = $run_id;
            """;
        command.Parameters.AddWithValue("$run_id", runId);
        await using SqliteDataReader reader = await command.ExecuteReaderAsync(CancellationToken.None);
        Assert.True(await reader.ReadAsync(CancellationToken.None));
        return (reader.GetString(0), reader.GetString(1));
    }

    private static CaptureRunRecord CreateRun(string runId) => new(
        runId,
        "session-1",
        7,
        "service-1",
        "user",
        "S-1-5-21-1000",
        ["0000000000000001"],
        0,
        null,
        Utc(0),
        null,
        new DriverStatsSnapshot(true, 3, CaptureState.Running, 4, 5, Utc(0), null),
        null,
        6,
        7,
        true,
        false,
        null);

    private static CaptureEvent CreateEvent(long wireSequence, byte[] payload) => new(
        wireSequence,
        wireSequence * 10,
        1,
        42,
        CaptureKind.Write,
        0,
        0,
        payload.Length,
        payload.Length,
        CaptureFlags.InputPayload,
        ImmutableArray.CreateRange(payload))
    {
        Timestamp = Utc((int)wireSequence),
        PortName = "COM1",
        ProcessName = "process.exe",
    };

    private static DateTimeOffset Utc(int seconds) =>
        new DateTimeOffset(2026, 7, 13, 1, 2, 3, TimeSpan.Zero).AddSeconds(seconds);

    private static string CreateTemporaryDirectory()
    {
        string path = Path.Combine(Path.GetTempPath(), $"CommMonitor-{Guid.NewGuid():N}");
        Directory.CreateDirectory(path);
        return path;
    }

    private sealed record RawEventSnapshot(
        long Sequence,
        long WireSequence,
        long QpcTicks,
        string TimestampUtc,
        long DeviceId,
        string PortName,
        long ProcessId,
        string ProcessName,
        long Kind,
        long IoctlCode,
        long NtStatus,
        long RequestedLength,
        long CompletedLength,
        long Flags,
        string PayloadHex);
}
