using System.Collections.Immutable;
using System.Globalization;
using CommMonitor.Core.Models;
using Microsoft.Data.Sqlite;

namespace CommMonitor.Core.Sessions;

public sealed class SessionStore : ISessionStore
{
    private const int CurrentSchemaVersion = 3;

    private const string BaseSchemaSql = """
        CREATE TABLE IF NOT EXISTS events(
         sequence INTEGER PRIMARY KEY,
         wire_sequence INTEGER NOT NULL,
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
        CREATE INDEX IF NOT EXISTS ix_events_time ON events(timestamp_utc);
        CREATE INDEX IF NOT EXISTS ix_events_device ON events(device_id, sequence);
        """;

    private const string SchemaV3Sql = """
        CREATE TABLE IF NOT EXISTS capture_runs(
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
        CREATE TABLE IF NOT EXISTS integrity_markers(
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
        CREATE INDEX IF NOT EXISTS ix_integrity_run_sequence
         ON integrity_markers(run_id, after_sequence);
        """;

    private const string InsertEventSql = """
        INSERT INTO events(
         wire_sequence, qpc_ticks, timestamp_utc, device_id, port_name,
         process_id, process_name, kind, ioctl_code, nt_status,
         requested_length, completed_length, flags, payload)
        VALUES(
         $wire_sequence, $qpc_ticks, $timestamp_utc, $device_id, $port_name,
         $process_id, $process_name, $kind, $ioctl_code, $nt_status,
         $requested_length, $completed_length, $flags, $payload)
        RETURNING sequence;
        """;

    private const string InsertMarkerSql = """
        INSERT INTO integrity_markers(
         run_id, generation, marker_type, occurred_utc,
         after_sequence, count_delta, code)
        VALUES(
         $run_id, $generation, $marker_type, $occurred_utc,
         $after_sequence, $count_delta, $code);
        """;

    private const string UpsertRunSql = """
        INSERT INTO capture_runs(
         run_id, session_id, generation, service_instance_id, owner_type, owner_sid,
         selected_devices_json, start_after_sequence, end_sequence, started_utc,
         stopped_utc, start_stats_json, end_stats_json, service_dropped,
         truncation_count, stats_known, clean_shutdown, end_reason)
        VALUES(
         $run_id, $session_id, $generation, $service_instance_id, $owner_type, $owner_sid,
         $selected_devices_json, $start_after_sequence, $end_sequence, $started_utc,
         $stopped_utc, $start_stats_json, $end_stats_json, $service_dropped,
         $truncation_count, $stats_known, $clean_shutdown, $end_reason)
        ON CONFLICT(run_id) DO UPDATE SET
         owner_type = excluded.owner_type,
         owner_sid = excluded.owner_sid,
         selected_devices_json = excluded.selected_devices_json,
         start_after_sequence = excluded.start_after_sequence,
         end_sequence = excluded.end_sequence,
         started_utc = excluded.started_utc,
         stopped_utc = excluded.stopped_utc,
         start_stats_json = excluded.start_stats_json,
         end_stats_json = excluded.end_stats_json,
         service_dropped = excluded.service_dropped,
         truncation_count = excluded.truncation_count,
         stats_known = excluded.stats_known,
         clean_shutdown = excluded.clean_shutdown,
         end_reason = excluded.end_reason
        WHERE capture_runs.session_id = excluded.session_id
          AND capture_runs.generation = excluded.generation
          AND capture_runs.service_instance_id = excluded.service_instance_id
        RETURNING run_id;
        """;

    private readonly string _connectionString;

    public SessionStore(string path)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        _connectionString = new SqliteConnectionStringBuilder
        {
            DataSource = path,
            Mode = SqliteOpenMode.ReadWriteCreate,
            Pooling = false,
        }.ToString();
    }

    public async Task InitializeAsync(CancellationToken cancellationToken = default)
    {
        await using SqliteConnection connection = await OpenConnectionAsync(cancellationToken);
        EnsureSupportedSchemaVersion(await ReadExistingSchemaVersionAsync(
            connection,
            null,
            cancellationToken));

        await using (var journalCommand = connection.CreateCommand())
        {
            journalCommand.CommandText = "PRAGMA journal_mode=WAL;";
            await journalCommand.ExecuteScalarAsync(cancellationToken);
        }

        await using SqliteTransaction transaction =
            (SqliteTransaction)await connection.BeginTransactionAsync(cancellationToken);
        EnsureSupportedSchemaVersion(await ReadExistingSchemaVersionAsync(
            connection,
            transaction,
            cancellationToken));

        await using (var metadataTableCommand = connection.CreateCommand())
        {
            metadataTableCommand.Transaction = transaction;
            metadataTableCommand.CommandText =
                "CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL);";
            await metadataTableCommand.ExecuteNonQueryAsync(cancellationToken);
        }

        await using (var baseSchemaCommand = connection.CreateCommand())
        {
            baseSchemaCommand.Transaction = transaction;
            baseSchemaCommand.CommandText = BaseSchemaSql;
            await baseSchemaCommand.ExecuteNonQueryAsync(cancellationToken);
        }

        if (!await HasWireSequenceColumnAsync(connection, transaction, cancellationToken))
        {
            await using var migrateCommand = connection.CreateCommand();
            migrateCommand.Transaction = transaction;
            migrateCommand.CommandText = """
                ALTER TABLE events
                ADD COLUMN wire_sequence INTEGER NOT NULL DEFAULT 0;
                UPDATE events SET wire_sequence = sequence;
                """;
            await migrateCommand.ExecuteNonQueryAsync(cancellationToken);
        }

        await using (var v3SchemaCommand = connection.CreateCommand())
        {
            v3SchemaCommand.Transaction = transaction;
            v3SchemaCommand.CommandText = SchemaV3Sql;
            await v3SchemaCommand.ExecuteNonQueryAsync(cancellationToken);
        }

        await using (var metadataCommand = connection.CreateCommand())
        {
            metadataCommand.Transaction = transaction;
            metadataCommand.CommandText = """
                INSERT INTO metadata(key, value) VALUES('schema_version', '3')
                ON CONFLICT(key) DO UPDATE SET value = excluded.value;
                """;
            await metadataCommand.ExecuteNonQueryAsync(cancellationToken);
        }

        await transaction.CommitAsync(cancellationToken);
    }

    public async Task<int> GetSchemaVersionAsync(CancellationToken cancellationToken = default)
    {
        await using SqliteConnection connection = await OpenConnectionAsync(cancellationToken);
        return await ReadSchemaVersionAsync(connection, null, cancellationToken);
    }

    public async Task<long> GetLastSequenceAsync(CancellationToken cancellationToken = default)
    {
        await using SqliteConnection connection = await OpenConnectionAsync(cancellationToken);
        await using SqliteCommand command = connection.CreateCommand();
        command.CommandText = "SELECT COALESCE(MAX(sequence), 0) FROM events;";
        object? result = await command.ExecuteScalarAsync(cancellationToken);
        return Convert.ToInt64(result, CultureInfo.InvariantCulture);
    }

    public async Task<long> CountRunsAsync(CancellationToken cancellationToken = default)
    {
        await using SqliteConnection connection = await OpenConnectionAsync(cancellationToken);
        await using SqliteCommand command = connection.CreateCommand();
        command.CommandText = "SELECT COUNT(*) FROM capture_runs;";
        object? result = await command.ExecuteScalarAsync(cancellationToken);
        return Convert.ToInt64(result, CultureInfo.InvariantCulture);
    }

    public async Task UpsertRunAsync(
        CaptureRunRecord run,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(run);

        await using SqliteConnection connection = await OpenConnectionAsync(cancellationToken);
        await using SqliteCommand command = connection.CreateCommand();
        command.CommandText = UpsertRunSql;
        command.Parameters.AddWithValue("$run_id", run.RunId);
        command.Parameters.AddWithValue("$session_id", run.SessionId);
        command.Parameters.AddWithValue("$generation", run.Generation);
        command.Parameters.AddWithValue("$service_instance_id", run.ServiceInstanceId);
        command.Parameters.AddWithValue("$owner_type", run.OwnerType);
        command.Parameters.AddWithValue("$owner_sid", run.OwnerSid);
        command.Parameters.AddWithValue(
            "$selected_devices_json",
            SessionRecordSerialization.SerializeSelectedDeviceIds(run.SelectedDeviceIds));
        command.Parameters.AddWithValue("$start_after_sequence", run.StartAfterSequence);
        command.Parameters.AddWithValue("$end_sequence", DbValue(run.EndSequence));
        command.Parameters.AddWithValue(
            "$started_utc",
            SessionRecordSerialization.FormatUtc(run.StartedUtc));
        command.Parameters.AddWithValue(
            "$stopped_utc",
            DbValue(run.StoppedUtc is null
                ? null
                : SessionRecordSerialization.FormatUtc(run.StoppedUtc.Value)));
        command.Parameters.AddWithValue(
            "$start_stats_json",
            SessionRecordSerialization.SerializeStats(run.StartStats));
        command.Parameters.AddWithValue(
            "$end_stats_json",
            DbValue(run.EndStats is null
                ? null
                : SessionRecordSerialization.SerializeStats(run.EndStats)));
        command.Parameters.AddWithValue("$service_dropped", run.ServiceDropped);
        command.Parameters.AddWithValue("$truncation_count", run.TruncationCount);
        command.Parameters.AddWithValue("$stats_known", run.StatsKnown ? 1 : 0);
        command.Parameters.AddWithValue("$clean_shutdown", run.CleanShutdown ? 1 : 0);
        command.Parameters.AddWithValue("$end_reason", DbValue(run.EndReason));
        command.Prepare();

        object? result = await command.ExecuteScalarAsync(cancellationToken);
        if (result is null || result is DBNull)
        {
            throw new InvalidOperationException(
                $"Run '{run.RunId}' already exists with a different session, generation, or service instance.");
        }
    }

    public async Task<IReadOnlyList<CaptureRunRecord>> ReadRunsAsync(
        CancellationToken cancellationToken = default)
    {
        await using SqliteConnection connection = await OpenConnectionAsync(cancellationToken);
        await using SqliteCommand command = connection.CreateCommand();
        command.CommandText = """
            SELECT run_id, session_id, generation, service_instance_id, owner_type, owner_sid,
                   selected_devices_json, start_after_sequence, end_sequence, started_utc,
                   stopped_utc, start_stats_json, end_stats_json, service_dropped,
                   truncation_count, stats_known, clean_shutdown, end_reason
            FROM capture_runs
            ORDER BY start_after_sequence, started_utc, run_id;
            """;
        return await ReadRunsAsync(command, cancellationToken);
    }

    public async Task<IReadOnlyList<IntegrityMarker>> ReadMarkersAsync(
        string runId,
        CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(runId);

        await using SqliteConnection connection = await OpenConnectionAsync(cancellationToken);
        await using SqliteCommand command = connection.CreateCommand();
        command.CommandText = """
            SELECT marker_id, run_id, generation, marker_type, occurred_utc,
                   after_sequence, count_delta, code
            FROM integrity_markers
            WHERE run_id = $run_id
            ORDER BY after_sequence, marker_id;
            """;
        command.Parameters.AddWithValue("$run_id", runId);
        return await ReadMarkersAsync(command, cancellationToken);
    }

    public Task<IReadOnlyList<CaptureEvent>> AppendAsync(
        IReadOnlyList<CaptureEvent> events,
        CancellationToken cancellationToken = default) =>
        AppendBatchAsync(new PersistBatch(events, []), cancellationToken);

    public async Task<IReadOnlyList<CaptureEvent>> AppendBatchAsync(
        PersistBatch batch,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(batch);
        ArgumentNullException.ThrowIfNull(batch.Events);
        ArgumentNullException.ThrowIfNull(batch.Markers);

        await using SqliteConnection connection = await OpenConnectionAsync(cancellationToken);
        await using SqliteTransaction transaction =
            (SqliteTransaction)await connection.BeginTransactionAsync(cancellationToken);
        await using SqliteCommand eventCommand = CreateEventCommand(connection, transaction);
        await using SqliteCommand markerCommand = CreateMarkerCommand(connection, transaction);

        var persistedEvents = new List<CaptureEvent>(batch.Events.Count);
        foreach (CaptureEvent captureEvent in batch.Events)
        {
            ArgumentNullException.ThrowIfNull(captureEvent);
            cancellationToken.ThrowIfCancellationRequested();
            BindEvent(eventCommand, captureEvent);

            object? result = await eventCommand.ExecuteScalarAsync(cancellationToken);
            long sequence = Convert.ToInt64(result, CultureInfo.InvariantCulture);
            persistedEvents.Add(captureEvent with
            {
                Sequence = sequence,
                WireSequence = captureEvent.WireSequence,
            });
        }

        foreach (IntegrityMarker marker in batch.Markers)
        {
            ArgumentNullException.ThrowIfNull(marker);
            cancellationToken.ThrowIfCancellationRequested();
            BindMarker(markerCommand, marker);
            await markerCommand.ExecuteNonQueryAsync(cancellationToken);
        }

        await transaction.CommitAsync(cancellationToken);
        return persistedEvents;
    }

    public async Task<IReadOnlyList<CaptureEvent>> ReadAfterAsync(
        long sequence,
        int limit,
        CancellationToken cancellationToken = default)
    {
        ValidateExporterLimit(limit);

        await using SqliteConnection connection = await OpenConnectionAsync(cancellationToken);
        await using SqliteCommand command = connection.CreateCommand();
        command.CommandText = """
            SELECT sequence, wire_sequence, qpc_ticks, timestamp_utc, device_id, port_name,
                   process_id, process_name, kind, ioctl_code, nt_status,
                   requested_length, completed_length, flags, payload
            FROM events
            WHERE sequence > $sequence
            ORDER BY sequence
            LIMIT $limit;
            """;
        command.Parameters.AddWithValue("$sequence", sequence);
        command.Parameters.AddWithValue("$limit", limit);

        return await ReadEventsAsync(command, cancellationToken);
    }

    public async Task ClearAsync(CancellationToken cancellationToken = default)
    {
        await using SqliteConnection connection = await OpenConnectionAsync(cancellationToken);
        await using SqliteTransaction transaction =
            (SqliteTransaction)await connection.BeginTransactionAsync(cancellationToken);
        await using SqliteCommand command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = """
            DELETE FROM integrity_markers;
            DELETE FROM capture_runs;
            DELETE FROM events;
            """;
        await command.ExecuteNonQueryAsync(cancellationToken);
        await transaction.CommitAsync(cancellationToken);
    }

    private static async Task<int> ReadSchemaVersionAsync(
        SqliteConnection connection,
        SqliteTransaction? transaction,
        CancellationToken cancellationToken)
    {
        await using SqliteCommand command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = "SELECT value FROM metadata WHERE key = 'schema_version';";
        object? result = await command.ExecuteScalarAsync(cancellationToken);
        if (result is null || result is DBNull)
        {
            return 0;
        }

        if (!int.TryParse(
            Convert.ToString(result, CultureInfo.InvariantCulture),
            NumberStyles.None,
            CultureInfo.InvariantCulture,
            out int version)
            || version < 0)
        {
            throw new InvalidOperationException("Session schema version is invalid.");
        }

        return version;
    }

    private static async Task<int> ReadExistingSchemaVersionAsync(
        SqliteConnection connection,
        SqliteTransaction? transaction,
        CancellationToken cancellationToken)
    {
        await using (var tableCommand = connection.CreateCommand())
        {
            tableCommand.Transaction = transaction;
            tableCommand.CommandText = """
                SELECT COUNT(*)
                FROM sqlite_master
                WHERE type = 'table' AND name = 'metadata';
                """;
            long tableCount = Convert.ToInt64(
                await tableCommand.ExecuteScalarAsync(cancellationToken),
                CultureInfo.InvariantCulture);
            if (tableCount == 0)
            {
                return 0;
            }
        }

        return await ReadSchemaVersionAsync(connection, transaction, cancellationToken);
    }

    private static void EnsureSupportedSchemaVersion(int schemaVersion)
    {
        if (schemaVersion > CurrentSchemaVersion)
        {
            throw new InvalidOperationException(
                $"Session schema version {schemaVersion} is newer than supported version {CurrentSchemaVersion}.");
        }
    }

    private static async Task<bool> HasWireSequenceColumnAsync(
        SqliteConnection connection,
        SqliteTransaction transaction,
        CancellationToken cancellationToken)
    {
        await using SqliteCommand command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = "PRAGMA table_info(events);";
        await using SqliteDataReader columns = await command.ExecuteReaderAsync(cancellationToken);
        while (await columns.ReadAsync(cancellationToken))
        {
            if (string.Equals(
                columns.GetString(1),
                "wire_sequence",
                StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
        }

        return false;
    }

    private static SqliteCommand CreateEventCommand(
        SqliteConnection connection,
        SqliteTransaction transaction)
    {
        SqliteCommand command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = InsertEventSql;
        command.Parameters.Add("$wire_sequence", SqliteType.Integer);
        command.Parameters.Add("$qpc_ticks", SqliteType.Integer);
        command.Parameters.Add("$timestamp_utc", SqliteType.Text);
        command.Parameters.Add("$device_id", SqliteType.Integer);
        command.Parameters.Add("$port_name", SqliteType.Text);
        command.Parameters.Add("$process_id", SqliteType.Integer);
        command.Parameters.Add("$process_name", SqliteType.Text);
        command.Parameters.Add("$kind", SqliteType.Integer);
        command.Parameters.Add("$ioctl_code", SqliteType.Integer);
        command.Parameters.Add("$nt_status", SqliteType.Integer);
        command.Parameters.Add("$requested_length", SqliteType.Integer);
        command.Parameters.Add("$completed_length", SqliteType.Integer);
        command.Parameters.Add("$flags", SqliteType.Integer);
        command.Parameters.Add("$payload", SqliteType.Blob);
        command.Prepare();
        return command;
    }

    private static void BindEvent(SqliteCommand command, CaptureEvent captureEvent)
    {
        command.Parameters["$wire_sequence"].Value = captureEvent.WireSequence;
        command.Parameters["$qpc_ticks"].Value = captureEvent.QpcTicks;
        command.Parameters["$timestamp_utc"].Value =
            SessionRecordSerialization.FormatUtc(captureEvent.Timestamp);
        command.Parameters["$device_id"].Value = unchecked((long)captureEvent.DeviceId);
        command.Parameters["$port_name"].Value = captureEvent.PortName;
        command.Parameters["$process_id"].Value = captureEvent.ProcessId;
        command.Parameters["$process_name"].Value = captureEvent.ProcessName;
        command.Parameters["$kind"].Value = (long)captureEvent.Kind;
        command.Parameters["$ioctl_code"].Value = captureEvent.IoctlCode;
        command.Parameters["$nt_status"].Value = captureEvent.NtStatus;
        command.Parameters["$requested_length"].Value = captureEvent.RequestedLength;
        command.Parameters["$completed_length"].Value = captureEvent.CompletedLength;
        command.Parameters["$flags"].Value = (long)captureEvent.Flags;
        command.Parameters["$payload"].Value = captureEvent.Payload.AsSpan().ToArray();
    }

    private static SqliteCommand CreateMarkerCommand(
        SqliteConnection connection,
        SqliteTransaction transaction)
    {
        SqliteCommand command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = InsertMarkerSql;
        command.Parameters.Add("$run_id", SqliteType.Text);
        command.Parameters.Add("$generation", SqliteType.Integer);
        command.Parameters.Add("$marker_type", SqliteType.Text);
        command.Parameters.Add("$occurred_utc", SqliteType.Text);
        command.Parameters.Add("$after_sequence", SqliteType.Integer);
        command.Parameters.Add("$count_delta", SqliteType.Integer);
        command.Parameters.Add("$code", SqliteType.Text);
        command.Prepare();
        return command;
    }

    private static void BindMarker(SqliteCommand command, IntegrityMarker marker)
    {
        command.Parameters["$run_id"].Value = marker.RunId;
        command.Parameters["$generation"].Value = marker.Generation;
        command.Parameters["$marker_type"].Value = marker.MarkerType;
        command.Parameters["$occurred_utc"].Value =
            SessionRecordSerialization.FormatUtc(marker.OccurredUtc);
        command.Parameters["$after_sequence"].Value = marker.AfterSequence;
        command.Parameters["$count_delta"].Value = marker.CountDelta;
        command.Parameters["$code"].Value = marker.Code;
    }

    private static async Task<IReadOnlyList<CaptureEvent>> ReadEventsAsync(
        SqliteCommand command,
        CancellationToken cancellationToken)
    {
        var events = new List<CaptureEvent>();
        await using SqliteDataReader reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            events.Add(ReadEvent(reader));
        }

        return events;
    }

    private static CaptureEvent ReadEvent(SqliteDataReader reader)
    {
        byte[] payload = reader.GetFieldValue<byte[]>(14);
        return new CaptureEvent(
            reader.GetInt64(0),
            reader.GetInt64(2),
            unchecked((ulong)reader.GetInt64(4)),
            reader.GetInt32(6),
            (CaptureKind)reader.GetInt64(8),
            unchecked((uint)reader.GetInt64(9)),
            reader.GetInt32(10),
            reader.GetInt32(11),
            reader.GetInt32(12),
            (CaptureFlags)reader.GetInt64(13),
            ImmutableArray.CreateRange(payload))
        {
            WireSequence = reader.GetInt64(1),
            Timestamp = SessionRecordSerialization.ParseUtc(reader.GetString(3)),
            PortName = reader.GetString(5),
            ProcessName = reader.GetString(7),
        };
    }

    private static async Task<IReadOnlyList<CaptureRunRecord>> ReadRunsAsync(
        SqliteCommand command,
        CancellationToken cancellationToken)
    {
        var runs = new List<CaptureRunRecord>();
        await using SqliteDataReader reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            runs.Add(ReadRun(reader));
        }

        return runs;
    }

    private static CaptureRunRecord ReadRun(SqliteDataReader reader) => new(
        reader.GetString(0),
        reader.GetString(1),
        reader.GetInt64(2),
        reader.GetString(3),
        reader.GetString(4),
        reader.GetString(5),
        SessionRecordSerialization.DeserializeSelectedDeviceIds(reader.GetString(6)),
        reader.GetInt64(7),
        reader.IsDBNull(8) ? null : reader.GetInt64(8),
        SessionRecordSerialization.ParseUtc(reader.GetString(9)),
        reader.IsDBNull(10)
            ? null
            : SessionRecordSerialization.ParseUtc(reader.GetString(10)),
        SessionRecordSerialization.DeserializeStats(reader.GetString(11)),
        reader.IsDBNull(12)
            ? null
            : SessionRecordSerialization.DeserializeStats(reader.GetString(12)),
        reader.GetInt64(13),
        reader.GetInt64(14),
        reader.GetInt64(15) != 0,
        reader.GetInt64(16) != 0,
        reader.IsDBNull(17) ? null : reader.GetString(17));

    private static async Task<IReadOnlyList<IntegrityMarker>> ReadMarkersAsync(
        SqliteCommand command,
        CancellationToken cancellationToken)
    {
        var markers = new List<IntegrityMarker>();
        await using SqliteDataReader reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            markers.Add(new IntegrityMarker(
                reader.GetInt64(0),
                reader.GetString(1),
                reader.GetInt64(2),
                reader.GetString(3),
                SessionRecordSerialization.ParseUtc(reader.GetString(4)),
                reader.GetInt64(5),
                reader.GetInt64(6),
                reader.GetString(7)));
        }

        return markers;
    }

    private static object DbValue(object? value) => value ?? DBNull.Value;

    private static void ValidateExporterLimit(int limit)
    {
        if (limit is < 1 or > 10_000)
        {
            throw new ArgumentOutOfRangeException(
                nameof(limit),
                limit,
                "Limit must be between 1 and 10000.");
        }
    }

    private async Task<SqliteConnection> OpenConnectionAsync(CancellationToken cancellationToken)
    {
        var connection = new SqliteConnection(_connectionString);
        try
        {
            await connection.OpenAsync(cancellationToken);
            await using SqliteCommand command = connection.CreateCommand();
            command.CommandText = """
                PRAGMA foreign_keys=ON;
                PRAGMA synchronous=NORMAL;
                """;
            await command.ExecuteNonQueryAsync(cancellationToken);
            return connection;
        }
        catch
        {
            await connection.DisposeAsync();
            throw;
        }
    }
}
