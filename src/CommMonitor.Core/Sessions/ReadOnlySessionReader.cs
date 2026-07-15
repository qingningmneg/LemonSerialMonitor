using System.Collections.Immutable;
using System.Globalization;
using System.Text;
using CommMonitor.Core.Models;
using Microsoft.Data.Sqlite;

namespace CommMonitor.Core.Sessions;

public sealed class ReadOnlySessionReader : IReadOnlySessionReader
{
    private const int CurrentSchemaVersion = 3;
    private const string LegacyIntegrityUnknown = "LEGACY_INTEGRITY_UNKNOWN";
    private const string IntegrityUnknown = "INTEGRITY_UNKNOWN";

    private readonly string _connectionString;

    public ReadOnlySessionReader(string path)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        _connectionString = new SqliteConnectionStringBuilder
        {
            DataSource = path,
            Mode = SqliteOpenMode.ReadOnly,
            Pooling = false,
        }.ToString();
    }

    public async Task<int> GetSchemaVersionAsync(CancellationToken cancellationToken = default)
    {
        await using SqliteConnection connection = await OpenConnectionAsync(cancellationToken);
        return await ReadSchemaVersionAsync(connection, null, cancellationToken);
    }

    public async Task<SessionEventPage> ReadAsync(
        SessionEventQuery query,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(query);
        ValidatePageLimit(query.Limit);

        DateTimeOffset? fromUtc = query.FromUtc?.ToUniversalTime();
        DateTimeOffset? toUtc = query.ToUtc?.ToUniversalTime();
        if (fromUtc is not null && toUtc is not null && fromUtc >= toUtc)
        {
            throw new ArgumentException(
                "FromUtc must be earlier than ToUtc for the half-open time range.",
                nameof(query));
        }

        await using SqliteConnection connection = await OpenConnectionAsync(cancellationToken);
        await using SqliteTransaction transaction = connection.BeginTransaction(deferred: true);
        int schemaVersion = await ReadSchemaVersionAsync(
            connection,
            transaction,
            cancellationToken);
        EnsureSupportedSchemaVersion(schemaVersion);
        long databaseMaximum = await ReadMaximumSequenceAsync(
            connection,
            transaction,
            cancellationToken);
        List<CaptureEvent> events = await ReadFilteredEventsAsync(
            connection,
            transaction,
            schemaVersion,
            databaseMaximum,
            query,
            fromUtc,
            toUtc,
            cancellationToken);

        bool hasMore = events.Count > query.Limit;
        if (hasMore)
        {
            events.RemoveAt(events.Count - 1);
        }

        long scannedThroughSequence = hasMore
            ? events[^1].Sequence
            : Math.Max(query.AfterSequence, databaseMaximum);

        IReadOnlyList<CaptureRunRecord> runs;
        IReadOnlyList<IntegrityMarker> markers;
        bool statsKnown;
        IReadOnlyList<string> integrityCodes;
        if (schemaVersion < 3)
        {
            runs = [];
            markers = [];
            statsKnown = false;
            integrityCodes = [LegacyIntegrityUnknown];
        }
        else
        {
            runs = await ReadRunsForIntervalAsync(
                connection,
                transaction,
                query.AfterSequence,
                scannedThroughSequence,
                cancellationToken);
            markers = await ReadMarkersForIntervalAsync(
                connection,
                transaction,
                query.AfterSequence,
                scannedThroughSequence,
                cancellationToken);
            statsKnown = runs.Count > 0 && runs.All(run => run.StatsKnown);
            integrityCodes = BuildIntegrityCodes(markers, statsKnown);
        }

        await transaction.CommitAsync(cancellationToken);
        return new SessionEventPage(
            events,
            scannedThroughSequence,
            hasMore,
            schemaVersion,
            statsKnown,
            integrityCodes,
            runs,
            markers);
    }

    public async Task<IReadOnlyList<CaptureEvent>> ReadAfterAsync(
        long sequence,
        int limit,
        CancellationToken cancellationToken = default)
    {
        ValidateExporterLimit(limit);

        await using SqliteConnection connection = await OpenConnectionAsync(cancellationToken);
        int schemaVersion = await ReadSchemaVersionAsync(connection, null, cancellationToken);
        EnsureSupportedSchemaVersion(schemaVersion);
        string wireSequenceColumn = schemaVersion < 2
            ? "sequence AS wire_sequence"
            : "wire_sequence";
        await using SqliteCommand command = connection.CreateCommand();
        command.CommandText = $"""
            SELECT sequence, {wireSequenceColumn}, qpc_ticks, timestamp_utc, device_id, port_name,
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

    public async Task<IReadOnlyList<CaptureRunRecord>> ReadRunsAsync(
        CancellationToken cancellationToken = default)
    {
        await using SqliteConnection connection = await OpenConnectionAsync(cancellationToken);
        int schemaVersion = await ReadSchemaVersionAsync(connection, null, cancellationToken);
        EnsureSupportedSchemaVersion(schemaVersion);
        if (schemaVersion < 3)
        {
            return [];
        }

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
        int schemaVersion = await ReadSchemaVersionAsync(connection, null, cancellationToken);
        EnsureSupportedSchemaVersion(schemaVersion);
        if (schemaVersion < 3)
        {
            return [];
        }

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

    private static async Task<List<CaptureEvent>> ReadFilteredEventsAsync(
        SqliteConnection connection,
        SqliteTransaction transaction,
        int schemaVersion,
        long maximumSequence,
        SessionEventQuery query,
        DateTimeOffset? fromUtc,
        DateTimeOffset? toUtc,
        CancellationToken cancellationToken)
    {
        string wireSequenceColumn = schemaVersion < 2
            ? "sequence AS wire_sequence"
            : "wire_sequence";
        var sql = new StringBuilder($"""
            SELECT sequence, {wireSequenceColumn}, qpc_ticks, timestamp_utc, device_id, port_name,
                   process_id, process_name, kind, ioctl_code, nt_status,
                   requested_length, completed_length, flags, payload
            FROM events
            WHERE sequence > $after_sequence
              AND sequence <= $maximum_sequence
            """);
        await using SqliteCommand command = connection.CreateCommand();
        command.Transaction = transaction;
        command.Parameters.AddWithValue("$after_sequence", query.AfterSequence);
        command.Parameters.AddWithValue("$maximum_sequence", maximumSequence);
        sql.AppendLine();

        AppendDeviceFilter(sql, command, query.DeviceIds);
        AppendKindFilter(sql, command, query.Kinds);
        if (fromUtc is not null)
        {
            sql.AppendLine("  AND timestamp_utc >= $from_utc");
            command.Parameters.AddWithValue(
                "$from_utc",
                SessionRecordSerialization.FormatUtc(fromUtc.Value));
        }

        if (toUtc is not null)
        {
            sql.AppendLine("  AND timestamp_utc < $to_utc");
            command.Parameters.AddWithValue(
                "$to_utc",
                SessionRecordSerialization.FormatUtc(toUtc.Value));
        }

        sql.AppendLine("ORDER BY sequence");
        sql.AppendLine("LIMIT $fetch_limit;");
        command.Parameters.AddWithValue("$fetch_limit", query.Limit + 1);
        command.CommandText = sql.ToString();

        IReadOnlyList<CaptureEvent> results = await ReadEventsAsync(command, cancellationToken);
        return [.. results];
    }

    private static void AppendDeviceFilter(
        StringBuilder sql,
        SqliteCommand command,
        IReadOnlyList<ulong>? deviceIds)
    {
        if (deviceIds is null)
        {
            return;
        }

        if (deviceIds.Count == 0)
        {
            sql.AppendLine("  AND 0 = 1");
            return;
        }

        var parameterNames = new string[deviceIds.Count];
        for (int index = 0; index < deviceIds.Count; index++)
        {
            string parameterName = $"$device_id_{index}";
            parameterNames[index] = parameterName;
            command.Parameters.AddWithValue(parameterName, unchecked((long)deviceIds[index]));
        }

        sql.Append("  AND device_id IN (");
        sql.AppendJoin(", ", parameterNames);
        sql.AppendLine(")");
    }

    private static void AppendKindFilter(
        StringBuilder sql,
        SqliteCommand command,
        IReadOnlyList<CaptureKind>? kinds)
    {
        if (kinds is null)
        {
            return;
        }

        if (kinds.Count == 0)
        {
            sql.AppendLine("  AND 0 = 1");
            return;
        }

        var parameterNames = new string[kinds.Count];
        for (int index = 0; index < kinds.Count; index++)
        {
            string parameterName = $"$kind_{index}";
            parameterNames[index] = parameterName;
            command.Parameters.AddWithValue(parameterName, (long)kinds[index]);
        }

        sql.Append("  AND kind IN (");
        sql.AppendJoin(", ", parameterNames);
        sql.AppendLine(")");
    }

    private static async Task<IReadOnlyList<CaptureRunRecord>> ReadRunsForIntervalAsync(
        SqliteConnection connection,
        SqliteTransaction transaction,
        long afterSequence,
        long scannedThroughSequence,
        CancellationToken cancellationToken)
    {
        if (scannedThroughSequence <= afterSequence)
        {
            return [];
        }

        await using SqliteCommand command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = """
            SELECT run_id, session_id, generation, service_instance_id, owner_type, owner_sid,
                   selected_devices_json, start_after_sequence, end_sequence, started_utc,
                   stopped_utc, start_stats_json, end_stats_json, service_dropped,
                   truncation_count, stats_known, clean_shutdown, end_reason
            FROM capture_runs
            WHERE start_after_sequence < $scanned_through_sequence
              AND (end_sequence IS NULL OR end_sequence > $after_sequence)
            ORDER BY start_after_sequence, started_utc, run_id;
            """;
        command.Parameters.AddWithValue("$after_sequence", afterSequence);
        command.Parameters.AddWithValue("$scanned_through_sequence", scannedThroughSequence);
        return await ReadRunsAsync(command, cancellationToken);
    }

    private static async Task<IReadOnlyList<IntegrityMarker>> ReadMarkersForIntervalAsync(
        SqliteConnection connection,
        SqliteTransaction transaction,
        long afterSequence,
        long scannedThroughSequence,
        CancellationToken cancellationToken)
    {
        if (scannedThroughSequence <= afterSequence)
        {
            return [];
        }

        await using SqliteCommand command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = """
            SELECT marker_id, run_id, generation, marker_type, occurred_utc,
                   after_sequence, count_delta, code
            FROM integrity_markers
            WHERE after_sequence > $after_sequence
              AND after_sequence <= $scanned_through_sequence
            ORDER BY after_sequence, marker_id;
            """;
        command.Parameters.AddWithValue("$after_sequence", afterSequence);
        command.Parameters.AddWithValue("$scanned_through_sequence", scannedThroughSequence);
        return await ReadMarkersAsync(command, cancellationToken);
    }

    private static IReadOnlyList<string> BuildIntegrityCodes(
        IReadOnlyList<IntegrityMarker> markers,
        bool statsKnown)
    {
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var codes = new List<string>();
        foreach (IntegrityMarker marker in markers)
        {
            if (seen.Add(marker.Code))
            {
                codes.Add(marker.Code);
            }
        }

        if (!statsKnown && seen.Add(IntegrityUnknown))
        {
            codes.Add(IntegrityUnknown);
        }

        return codes;
    }

    private static async Task<long> ReadMaximumSequenceAsync(
        SqliteConnection connection,
        SqliteTransaction transaction,
        CancellationToken cancellationToken)
    {
        await using SqliteCommand command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = "SELECT COALESCE(MAX(sequence), 0) FROM events;";
        object? result = await command.ExecuteScalarAsync(cancellationToken);
        return Convert.ToInt64(result, CultureInfo.InvariantCulture);
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
        if (result is null || result is DBNull
            || !int.TryParse(
                Convert.ToString(result, CultureInfo.InvariantCulture),
                NumberStyles.None,
                CultureInfo.InvariantCulture,
                out int version)
            || version < 0)
        {
            throw new InvalidOperationException("Session schema version is missing or invalid.");
        }

        return version;
    }

    private static void EnsureSupportedSchemaVersion(int schemaVersion)
    {
        if (schemaVersion > CurrentSchemaVersion)
        {
            throw new InvalidOperationException(
                $"Session schema version {schemaVersion} is newer than supported version {CurrentSchemaVersion}.");
        }
    }

    private static async Task<IReadOnlyList<CaptureEvent>> ReadEventsAsync(
        SqliteCommand command,
        CancellationToken cancellationToken)
    {
        var events = new List<CaptureEvent>();
        await using SqliteDataReader reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            byte[] payload = reader.GetFieldValue<byte[]>(14);
            events.Add(new CaptureEvent(
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
            });
        }

        return events;
    }

    private static async Task<IReadOnlyList<CaptureRunRecord>> ReadRunsAsync(
        SqliteCommand command,
        CancellationToken cancellationToken)
    {
        var runs = new List<CaptureRunRecord>();
        await using SqliteDataReader reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            runs.Add(new CaptureRunRecord(
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
                reader.IsDBNull(17) ? null : reader.GetString(17)));
        }

        return runs;
    }

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

    private static void ValidatePageLimit(int limit)
    {
        if (limit is < 1 or > 1_000)
        {
            throw new ArgumentOutOfRangeException(
                nameof(limit),
                limit,
                "Limit must be between 1 and 1000.");
        }
    }

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
            return connection;
        }
        catch
        {
            await connection.DisposeAsync();
            throw;
        }
    }
}
