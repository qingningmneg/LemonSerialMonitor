using System.Collections.Immutable;
using System.Reflection;
using System.Runtime.CompilerServices;
using CommMonitor.Core.Models;
using CommMonitor.Core.Sessions;
using Microsoft.Data.Sqlite;

namespace CommMonitor.Core.Tests.Sessions;

public sealed class ReadOnlySessionReaderTests
{
    [Fact]
    public async Task Reader_never_creates_a_missing_session_file()
    {
        string directory = CreateTemporaryDirectory();
        string path = Path.Combine(directory, $"{Guid.NewGuid():N}.cmsession");

        try
        {
            var reader = new ReadOnlySessionReader(path);

            await Assert.ThrowsAsync<SqliteException>(
                () => reader.GetSchemaVersionAsync(CancellationToken.None));
            Assert.False(File.Exists(path));
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Theory]
    [InlineData("ReadAsync")]
    [InlineData("ReadAfterAsync")]
    [InlineData("ReadRunsAsync")]
    [InlineData("ReadMarkersAsync")]
    public async Task Content_read_apis_fail_closed_for_a_future_schema(string operation)
    {
        string directory = CreateTemporaryDirectory();
        string path = Path.Combine(directory, $"{Guid.NewGuid():N}.cmsession");

        try
        {
            var store = new SessionStore(path);
            await store.InitializeAsync(CancellationToken.None);
            await SetSchemaVersionAsync(path, 4);
            var reader = new ReadOnlySessionReader(path);
            Assert.Equal(4, await reader.GetSchemaVersionAsync(CancellationToken.None));

            async Task InvokeAsync()
            {
                switch (operation)
                {
                    case "ReadAsync":
                        await reader.ReadAsync(
                            new SessionEventQuery(0, 100, null, null, null, null),
                            CancellationToken.None);
                        break;
                    case "ReadAfterAsync":
                        await reader.ReadAfterAsync(0, 100, CancellationToken.None);
                        break;
                    case "ReadRunsAsync":
                        await reader.ReadRunsAsync(CancellationToken.None);
                        break;
                    case "ReadMarkersAsync":
                        await reader.ReadMarkersAsync("run-1", CancellationToken.None);
                        break;
                    default:
                        throw new InvalidOperationException($"Unknown test operation '{operation}'.");
                }
            }

            InvalidOperationException exception =
                await Assert.ThrowsAsync<InvalidOperationException>(InvokeAsync);
            Assert.Contains("4", exception.Message, StringComparison.Ordinal);
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Theory]
    [InlineData(1)]
    [InlineData(2)]
    public async Task Legacy_pages_report_unknown_integrity_without_fabricating_evidence(int version)
    {
        string directory = CreateTemporaryDirectory();
        string path = Path.Combine(directory, $"{Guid.NewGuid():N}.cmsession");

        try
        {
            await CreateLegacySessionAsync(path, version);
            var reader = new ReadOnlySessionReader(path);

            SessionEventPage page = await reader.ReadAsync(
                new SessionEventQuery(0, 100, null, null, null, null),
                CancellationToken.None);

            Assert.Equal(version, await reader.GetSchemaVersionAsync(CancellationToken.None));
            Assert.Equal(version, page.SchemaVersion);
            Assert.False(page.StatsKnown);
            Assert.Equal(["LEGACY_INTEGRITY_UNKNOWN"], page.IntegrityCodes);
            Assert.Empty(page.Runs);
            Assert.Empty(page.Markers);
            CaptureEvent captureEvent = Assert.Single(page.Events);
            Assert.Equal(42, captureEvent.Sequence);
            Assert.Equal(version == 1 ? 42 : 7, captureEvent.WireSequence);
            Assert.Equal([0x00, 0xA1, 0xFF], captureEvent.Payload.AsSpan().ToArray());
            Assert.Empty(await reader.ReadRunsAsync(CancellationToken.None));
            Assert.Empty(await reader.ReadMarkersAsync("legacy-run", CancellationToken.None));
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public async Task ReadAsync_applies_parameterized_device_kind_and_half_open_utc_filters()
    {
        string directory = CreateTemporaryDirectory();
        string path = Path.Combine(directory, $"{Guid.NewGuid():N}.cmsession");

        try
        {
            await SeedV3SessionAsync(path);
            var reader = new ReadOnlySessionReader(path);

            SessionEventPage page = await reader.ReadAsync(
                new SessionEventQuery(
                    0,
                    100,
                    [0x11],
                    [CaptureKind.Read],
                    Utc(0).ToOffset(TimeSpan.FromHours(8)),
                    Utc(3).ToOffset(TimeSpan.FromHours(-5))),
                CancellationToken.None);

            CaptureEvent captureEvent = Assert.Single(page.Events);
            Assert.Equal(1, captureEvent.Sequence);
            Assert.Equal(0x11UL, captureEvent.DeviceId);
            Assert.Equal(CaptureKind.Read, captureEvent.Kind);
            Assert.False(page.HasMore);
            Assert.Equal(4, page.ScannedThroughSequence);
            Assert.False(page.StatsKnown);
            Assert.Equal(
                ["FIRST_CODE", "SECOND_CODE", "INTEGRITY_UNKNOWN"],
                page.IntegrityCodes);
            Assert.Equal(["run-known", "run-unknown"], page.Runs.Select(run => run.RunId));
            Assert.Equal([1L, 4L], page.Markers.Select(marker => marker.AfterSequence));
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public async Task ReadAsync_uses_limit_plus_one_and_returns_only_interval_evidence()
    {
        string directory = CreateTemporaryDirectory();
        string path = Path.Combine(directory, $"{Guid.NewGuid():N}.cmsession");

        try
        {
            await SeedV3SessionAsync(path);
            var reader = new ReadOnlySessionReader(path);

            SessionEventPage first = await reader.ReadAsync(
                new SessionEventQuery(0, 1, [0x11], null, null, null),
                CancellationToken.None);

            Assert.Equal([1L], first.Events.Select(captureEvent => captureEvent.Sequence));
            Assert.True(first.HasMore);
            Assert.Equal(1, first.ScannedThroughSequence);
            Assert.True(first.StatsKnown);
            Assert.Equal(["FIRST_CODE"], first.IntegrityCodes);
            Assert.Equal(["run-known"], first.Runs.Select(run => run.RunId));
            IntegrityMarker firstMarker = Assert.Single(first.Markers);
            Assert.Equal(1, firstMarker.AfterSequence);
            Assert.NotNull(firstMarker.MarkerId);

            SessionEventPage second = await reader.ReadAsync(
                new SessionEventQuery(1, 2, [0x11], null, null, null),
                CancellationToken.None);

            Assert.Equal([3L, 4L], second.Events.Select(captureEvent => captureEvent.Sequence));
            Assert.False(second.HasMore);
            Assert.Equal(4, second.ScannedThroughSequence);
            Assert.False(second.StatsKnown);
            Assert.Equal(
                ["SECOND_CODE", "INTEGRITY_UNKNOWN"],
                second.IntegrityCodes);
            Assert.Equal(
                ["run-known", "run-unknown"],
                second.Runs.Select(run => run.RunId));
            Assert.Equal([4L], second.Markers.Select(marker => marker.AfterSequence));
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public async Task ReadAsync_advances_a_selective_empty_page_to_the_consistent_maximum()
    {
        string directory = CreateTemporaryDirectory();
        string path = Path.Combine(directory, $"{Guid.NewGuid():N}.cmsession");

        try
        {
            await SeedV3SessionAsync(path);
            var reader = new ReadOnlySessionReader(path);

            SessionEventPage page = await reader.ReadAsync(
                new SessionEventQuery(0, 100, [ulong.MaxValue], null, null, null),
                CancellationToken.None);

            Assert.Empty(page.Events);
            Assert.False(page.HasMore);
            Assert.Equal(4, page.ScannedThroughSequence);
            Assert.Equal(["run-known", "run-unknown"], page.Runs.Select(run => run.RunId));
            Assert.Equal([1L, 4L], page.Markers.Select(marker => marker.AfterSequence));
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public async Task ReadAsync_uses_a_deferred_snapshot_while_a_wal_writer_is_uncommitted()
    {
        string directory = CreateTemporaryDirectory();
        string path = Path.Combine(directory, $"{Guid.NewGuid():N}.cmsession");

        try
        {
            var store = new SessionStore(path);
            await store.InitializeAsync(CancellationToken.None);
            await store.AppendAsync(
                [CreateEvent(1, 0x11, CaptureKind.Read, Utc(0))],
                CancellationToken.None);

            var writerConnectionString = new SqliteConnectionStringBuilder
            {
                DataSource = path,
                Mode = SqliteOpenMode.ReadWrite,
                Pooling = false,
            }.ToString();
            await using var writerConnection = new SqliteConnection(writerConnectionString);
            await writerConnection.OpenAsync(CancellationToken.None);
            await using SqliteTransaction writerTransaction = writerConnection.BeginTransaction();
            await using (var insert = writerConnection.CreateCommand())
            {
                insert.Transaction = writerTransaction;
                insert.CommandText = """
                    INSERT INTO events(
                     wire_sequence, qpc_ticks, timestamp_utc, device_id, port_name,
                     process_id, process_name, kind, ioctl_code, nt_status,
                     requested_length, completed_length, flags, payload)
                    VALUES(
                     2, 20, '2026-07-13T01:02:04.0000000+00:00', 17, 'COM1',
                     42, 'uncommitted.exe', 1, 0, 0, 1, 1, 0, X'EE');
                    """;
                await insert.ExecuteNonQueryAsync(CancellationToken.None);
            }

            var reader = new ReadOnlySessionReader(path);
            Task<SessionEventPage> readTask = reader.ReadAsync(
                new SessionEventQuery(0, 100, null, null, null, null),
                CancellationToken.None);
            Task completed = await Task.WhenAny(readTask, Task.Delay(TimeSpan.FromSeconds(2)));
            bool completedWhileWriterHeld = ReferenceEquals(completed, readTask);
            if (!completedWhileWriterHeld)
            {
                await writerTransaction.RollbackAsync(CancellationToken.None);
            }

            SessionEventPage page = await readTask;
            if (completedWhileWriterHeld)
            {
                await writerTransaction.RollbackAsync(CancellationToken.None);
            }

            Assert.True(
                completedWhileWriterHeld,
                "The read did not complete while the WAL writer transaction remained open.");
            CaptureEvent captureEvent = Assert.Single(page.Events);
            Assert.Equal(1, captureEvent.Sequence);
            Assert.Equal(1, page.ScannedThroughSequence);
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public void ReadAsync_explicitly_begins_a_deferred_transaction()
    {
        MethodInfo readAsync = typeof(ReadOnlySessionReader).GetMethod(
            nameof(ReadOnlySessionReader.ReadAsync),
            [typeof(SessionEventQuery), typeof(CancellationToken)])!;
        MethodInfo deferredBeginTransaction = typeof(SqliteConnection).GetMethod(
            nameof(SqliteConnection.BeginTransaction),
            [typeof(bool)])!;

        Assert.True(
            CallsWithTrueLiteral(readAsync, deferredBeginTransaction),
            "ReadAsync must explicitly call BeginTransaction(deferred: true).");
    }

    [Theory]
    [InlineData(0)]
    [InlineData(1_001)]
    public async Task ReadAsync_rejects_page_limits_outside_one_to_one_thousand(int limit)
    {
        string directory = CreateTemporaryDirectory();
        string path = Path.Combine(directory, $"{Guid.NewGuid():N}.cmsession");

        try
        {
            var store = new SessionStore(path);
            await store.InitializeAsync(CancellationToken.None);
            var reader = new ReadOnlySessionReader(path);

            await Assert.ThrowsAsync<ArgumentOutOfRangeException>(
                () => reader.ReadAsync(
                    new SessionEventQuery(0, limit, null, null, null, null),
                    CancellationToken.None));
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Theory]
    [InlineData(0)]
    [InlineData(-1)]
    public async Task ReadAsync_rejects_empty_or_reversed_utc_ranges(int endOffsetSeconds)
    {
        string directory = CreateTemporaryDirectory();
        string path = Path.Combine(directory, $"{Guid.NewGuid():N}.cmsession");

        try
        {
            var store = new SessionStore(path);
            await store.InitializeAsync(CancellationToken.None);
            var reader = new ReadOnlySessionReader(path);

            await Assert.ThrowsAsync<ArgumentException>(
                () => reader.ReadAsync(
                    new SessionEventQuery(
                        0,
                        100,
                        null,
                        null,
                        Utc(0),
                        Utc(endOffsetSeconds)),
                    CancellationToken.None));
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public async Task ReadAsync_de_duplicates_marker_codes_in_sequence_and_marker_order()
    {
        string directory = CreateTemporaryDirectory();
        string path = Path.Combine(directory, $"{Guid.NewGuid():N}.cmsession");
        const string runId = "run-codes";

        try
        {
            var store = new SessionStore(path);
            await store.InitializeAsync(CancellationToken.None);
            await store.UpsertRunAsync(CreateRun(runId, 0, null, statsKnown: false), CancellationToken.None);
            await store.AppendBatchAsync(
                new PersistBatch(
                    [CreateEvent(1, 0x11, CaptureKind.Read, Utc(1))],
                    [
                        new IntegrityMarker(null, runId, 1, "first", Utc(1), 1, 1, "B"),
                        new IntegrityMarker(null, runId, 1, "second", Utc(1), 1, 1, "A"),
                        new IntegrityMarker(null, runId, 1, "duplicate", Utc(1), 1, 1, "B"),
                    ]),
                CancellationToken.None);
            var reader = new ReadOnlySessionReader(path);

            SessionEventPage page = await reader.ReadAsync(
                new SessionEventQuery(0, 100, null, null, null, null),
                CancellationToken.None);

            Assert.Equal(["B", "A", "INTEGRITY_UNKNOWN"], page.IntegrityCodes);
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    private static async Task SeedV3SessionAsync(string path)
    {
        var store = new SessionStore(path);
        await store.InitializeAsync(CancellationToken.None);
        await store.UpsertRunAsync(
            CreateRun("run-known", 0, 2, statsKnown: true),
            CancellationToken.None);
        await store.UpsertRunAsync(
            CreateRun("run-unknown", 2, 4, statsKnown: false),
            CancellationToken.None);
        await store.AppendBatchAsync(
            new PersistBatch(
                [
                    CreateEvent(101, 0x11, CaptureKind.Read, Utc(0)),
                    CreateEvent(102, 0x22, CaptureKind.Read, Utc(1)),
                    CreateEvent(103, 0x11, CaptureKind.Write, Utc(2)),
                    CreateEvent(104, 0x11, CaptureKind.Read, Utc(3)),
                ],
                [
                    new IntegrityMarker(
                        null,
                        "run-known",
                        1,
                        "known-marker",
                        Utc(1),
                        1,
                        1,
                        "FIRST_CODE"),
                    new IntegrityMarker(
                        null,
                        "run-unknown",
                        1,
                        "unknown-marker",
                        Utc(4),
                        4,
                        1,
                        "SECOND_CODE"),
                ]),
            CancellationToken.None);
    }

    private static CaptureRunRecord CreateRun(
        string runId,
        long startAfterSequence,
        long? endSequence,
        bool statsKnown) => new(
            runId,
            "session-1",
            1,
            "service-1",
            "user",
            "S-1-5-21-1000",
            ["0000000000000011"],
            startAfterSequence,
            endSequence,
            Utc((int)startAfterSequence),
            endSequence is null ? null : Utc((int)endSequence.Value),
            new DriverStatsSnapshot(
                statsKnown,
                0,
                CaptureState.Running,
                0,
                0,
                Utc((int)startAfterSequence),
                statsKnown ? null : "driver unavailable"),
            null,
            0,
            0,
            statsKnown,
            endSequence is not null,
            endSequence is null ? null : "stopped");

    private static CaptureEvent CreateEvent(
        long wireSequence,
        ulong deviceId,
        CaptureKind kind,
        DateTimeOffset timestamp) => new(
            wireSequence,
            wireSequence * 10,
            deviceId,
            42,
            kind,
            0,
            0,
            1,
            1,
            CaptureFlags.None,
            ImmutableArray.Create((byte)wireSequence))
        {
            Timestamp = timestamp,
            PortName = "COM1",
            ProcessName = "process.exe",
        };

    private static async Task CreateLegacySessionAsync(string path, int version)
    {
        await using var connection = new SqliteConnection($"Data Source={path};Pooling=False");
        await connection.OpenAsync(CancellationToken.None);
        await using SqliteCommand command = connection.CreateCommand();
        string wireColumn = version == 1
            ? string.Empty
            : "wire_sequence INTEGER NOT NULL,";
        string wireName = version == 1 ? string.Empty : "wire_sequence,";
        string wireValue = version == 1 ? string.Empty : "7,";
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
            INSERT INTO events(
             sequence, {wireName} qpc_ticks, timestamp_utc, device_id, port_name,
             process_id, process_name, kind, ioctl_code, nt_status,
             requested_length, completed_length, flags, payload)
            VALUES(
             42, {wireValue} 420, '2026-07-10T00:00:00.0000000+00:00', 17, 'COM1',
             42, 'legacy.exe', 2, 0, 0, 3, 3, 0, X'00A1FF');
            """;
        await command.ExecuteNonQueryAsync(CancellationToken.None);
    }

    private static async Task SetSchemaVersionAsync(string path, int version)
    {
        await using var connection = new SqliteConnection($"Data Source={path};Pooling=False");
        await connection.OpenAsync(CancellationToken.None);
        await using SqliteCommand command = connection.CreateCommand();
        command.CommandText = """
            UPDATE metadata
            SET value = $version
            WHERE key = 'schema_version';
            """;
        command.Parameters.AddWithValue("$version", version.ToString());
        await command.ExecuteNonQueryAsync(CancellationToken.None);
    }

    private static DateTimeOffset Utc(int seconds) =>
        new DateTimeOffset(2026, 7, 13, 1, 2, 3, TimeSpan.Zero).AddSeconds(seconds);

    private static bool CallsWithTrueLiteral(MethodInfo asyncMethod, MethodInfo targetMethod)
    {
        Type stateMachineType = asyncMethod
            .GetCustomAttribute<AsyncStateMachineAttribute>()!
            .StateMachineType;
        MethodInfo moveNext = stateMachineType.GetMethod(
            "MoveNext",
            BindingFlags.Instance | BindingFlags.NonPublic)!;
        byte[] il = moveNext.GetMethodBody()!.GetILAsByteArray()!;
        for (int index = 1; index <= il.Length - 5; index++)
        {
            if (il[index - 1] != 0x17 || il[index] is not (0x28 or 0x6F))
            {
                continue;
            }

            int metadataToken = BitConverter.ToInt32(il, index + 1);
            try
            {
                if (moveNext.Module.ResolveMethod(metadataToken) == targetMethod)
                {
                    return true;
                }
            }
            catch (ArgumentException)
            {
                // A call opcode byte inside another operand is not an instruction.
            }
        }

        return false;
    }

    private static string CreateTemporaryDirectory()
    {
        string path = Path.Combine(Path.GetTempPath(), $"CommMonitor-{Guid.NewGuid():N}");
        Directory.CreateDirectory(path);
        return path;
    }
}
