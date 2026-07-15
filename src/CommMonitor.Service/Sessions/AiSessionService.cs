using System.Collections.Concurrent;
using System.Collections.Immutable;
using System.Diagnostics;
using System.Globalization;
using System.Runtime.Versioning;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using CommMonitor.Core.Ai;
using CommMonitor.Core.Copying;
using CommMonitor.Core.Export;
using CommMonitor.Core.Models;
using CommMonitor.Core.Sessions;
using CommMonitor.Service.Capture;
using CommMonitor.Service.Ipc;
using Microsoft.Data.Sqlite;

namespace CommMonitor.Service.Sessions;

internal interface ICommitNotificationSource
{
    ICommitRegistration Register(string sessionId);
}

internal interface ICommitRegistration : IAsyncDisposable
{
    Task<bool> WaitAsync(TimeSpan timeout, CancellationToken cancellationToken);
}

internal sealed class CaptureCommitNotificationSource :
    ICommitNotificationSource,
    IDisposable
{
    private readonly CaptureCoordinator _coordinator;
    private readonly object _gate = new();
    private readonly HashSet<Registration> _registrations = [];
    private bool _disposed;

    public CaptureCommitNotificationSource(CaptureCoordinator coordinator)
    {
        _coordinator = coordinator ?? throw new ArgumentNullException(nameof(coordinator));
        _coordinator.EventsCommitted += OnEventsCommitted;
    }

    public ICommitRegistration Register(string sessionId)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(sessionId);
        lock (_gate)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            var registration = new Registration(this, sessionId);
            _registrations.Add(registration);
            return registration;
        }
    }

    public void Dispose()
    {
        Registration[] registrations;
        lock (_gate)
        {
            if (_disposed)
            {
                return;
            }

            _disposed = true;
            registrations = _registrations.ToArray();
            _registrations.Clear();
        }

        _coordinator.EventsCommitted -= OnEventsCommitted;
        foreach (Registration registration in registrations)
        {
            registration.Cancel();
        }
    }

    private void OnEventsCommitted(object? sender, ImmutableArray<CaptureEvent> events)
    {
        Registration[] registrations;
        lock (_gate)
        {
            if (_disposed)
            {
                return;
            }

            // A commit can be associated with a legacy WPF session name rather than
            // its opaque catalog ID. Waking all bounded waiters is safe; each waiter
            // re-queries its own committed SQLite session and spurious wakeups carry no data.
            registrations = _registrations.ToArray();
        }

        foreach (Registration registration in registrations)
        {
            registration.Signal();
        }
    }

    private void Remove(Registration registration)
    {
        lock (_gate)
        {
            _registrations.Remove(registration);
        }
    }

    private sealed class Registration(
        CaptureCommitNotificationSource owner,
        string sessionId) : ICommitRegistration
    {
        private readonly TaskCompletionSource<bool> _completion =
            new(TaskCreationOptions.RunContinuationsAsynchronously);
        private int _disposed;

        public string SessionId { get; } = sessionId;

        public async Task<bool> WaitAsync(
            TimeSpan timeout,
            CancellationToken cancellationToken)
        {
            try
            {
                return await _completion.Task
                    .WaitAsync(timeout, cancellationToken)
                    .ConfigureAwait(false);
            }
            catch (TimeoutException)
            {
                return false;
            }
        }

        public void Signal() => _completion.TrySetResult(true);

        public void Cancel() => _completion.TrySetCanceled();

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

internal sealed class SqliteSessionExportSnapshot : IAsyncDisposable
{
    private const int CurrentSchemaVersion = 3;

    private readonly SqliteConnection _connection;
    private readonly SqliteTransaction _transaction;
    private readonly int _schemaVersion;
    private long _afterSequence;
    private bool _disposed;

    private SqliteSessionExportSnapshot(
        SqliteConnection connection,
        SqliteTransaction transaction,
        int schemaVersion,
        long maximumSequence)
    {
        _connection = connection;
        _transaction = transaction;
        _schemaVersion = schemaVersion;
        MaximumSequence = maximumSequence;
    }

    public long MaximumSequence { get; }

    public static async Task<SqliteSessionExportSnapshot> OpenAsync(
        string path,
        CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        var connection = new SqliteConnection(
            new SqliteConnectionStringBuilder
            {
                DataSource = path,
                Mode = SqliteOpenMode.ReadOnly,
                Pooling = false,
            }.ToString());
        SqliteTransaction? transaction = null;
        try
        {
            await connection.OpenAsync(cancellationToken).ConfigureAwait(false);
            transaction = connection.BeginTransaction(deferred: true);
            int schemaVersion = await ReadSchemaVersionAsync(
                connection,
                transaction,
                cancellationToken).ConfigureAwait(false);
            if (schemaVersion is < 1 or > CurrentSchemaVersion)
            {
                throw new NotSupportedException(
                    $"Session schema version {schemaVersion} is not supported for export.");
            }

            long maximumSequence = await ReadMaximumSequenceAsync(
                connection,
                transaction,
                cancellationToken).ConfigureAwait(false);
            return new SqliteSessionExportSnapshot(
                connection,
                transaction,
                schemaVersion,
                maximumSequence);
        }
        catch
        {
            if (transaction is not null)
            {
                await transaction.DisposeAsync().ConfigureAwait(false);
            }

            await connection.DisposeAsync().ConfigureAwait(false);
            throw;
        }
    }

    public async Task<IReadOnlyList<CaptureEvent>> ReadNextAsync(
        int limit,
        CancellationToken cancellationToken = default)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (limit is < 1 or > 10_000)
        {
            throw new ArgumentOutOfRangeException(
                nameof(limit),
                "The export page limit must be between 1 and 10000.");
        }

        if (_afterSequence >= MaximumSequence)
        {
            return [];
        }

        string wireSequenceColumn = _schemaVersion < 2
            ? "sequence AS wire_sequence"
            : "wire_sequence";
        await using SqliteCommand command = _connection.CreateCommand();
        command.Transaction = _transaction;
        command.CommandText = $"""
            SELECT sequence, {wireSequenceColumn}, qpc_ticks, timestamp_utc, device_id, port_name,
                   process_id, process_name, kind, ioctl_code, nt_status,
                   requested_length, completed_length, flags, payload
            FROM events
            WHERE sequence > $after_sequence
              AND sequence <= $maximum_sequence
            ORDER BY sequence
            LIMIT $limit;
            """;
        command.Parameters.AddWithValue("$after_sequence", _afterSequence);
        command.Parameters.AddWithValue("$maximum_sequence", MaximumSequence);
        command.Parameters.AddWithValue("$limit", limit);

        var events = new List<CaptureEvent>(Math.Min(limit, 1024));
        await using SqliteDataReader reader = await command
            .ExecuteReaderAsync(cancellationToken)
            .ConfigureAwait(false);
        while (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
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
                Timestamp = DateTimeOffset.Parse(
                    reader.GetString(3),
                    CultureInfo.InvariantCulture,
                    DateTimeStyles.RoundtripKind),
                PortName = reader.GetString(5),
                ProcessName = reader.GetString(7),
            });
        }

        if (events.Count > 0)
        {
            _afterSequence = events[^1].Sequence;
        }

        return events;
    }

    public async ValueTask DisposeAsync()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        await _transaction.DisposeAsync().ConfigureAwait(false);
        await _connection.DisposeAsync().ConfigureAwait(false);
    }

    private static async Task<int> ReadSchemaVersionAsync(
        SqliteConnection connection,
        SqliteTransaction transaction,
        CancellationToken cancellationToken)
    {
        await using SqliteCommand command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = "SELECT value FROM metadata WHERE key = 'schema_version';";
        object? value = await command.ExecuteScalarAsync(cancellationToken)
            .ConfigureAwait(false);
        return int.TryParse(
            Convert.ToString(value, CultureInfo.InvariantCulture),
            NumberStyles.None,
            CultureInfo.InvariantCulture,
            out int schemaVersion)
            ? schemaVersion
            : 0;
    }

    private static async Task<long> ReadMaximumSequenceAsync(
        SqliteConnection connection,
        SqliteTransaction transaction,
        CancellationToken cancellationToken)
    {
        await using SqliteCommand command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = "SELECT COALESCE(MAX(sequence), 0) FROM events;";
        object? value = await command.ExecuteScalarAsync(cancellationToken)
            .ConfigureAwait(false);
        return Convert.ToInt64(value, CultureInfo.InvariantCulture);
    }
}

[SupportedOSPlatform("windows")]
internal sealed class AiSessionService
{
    private const int ResponseEnvelopeReserve = 128 * 1024;
    private const int ExportReadPageSize = 512;
    private const int MaximumTextPreviewBytes = 4096;
    private const string SessionListCursorPrefix = "l1";

    private readonly SessionCatalog _catalog;
    private readonly CursorProtector _cursorProtector;
    private readonly ServiceStorageBoundary _storageBoundary;
    private readonly ICommitNotificationSource _notifications;
    private readonly ConcurrentDictionary<string, byte> _activeWaitClients =
        new(StringComparer.Ordinal);

    public AiSessionService(
        SessionCatalog catalog,
        CursorProtector cursorProtector,
        ServiceStorageBoundary storageBoundary,
        ICommitNotificationSource notifications)
    {
        _catalog = catalog ?? throw new ArgumentNullException(nameof(catalog));
        _cursorProtector = cursorProtector ??
            throw new ArgumentNullException(nameof(cursorProtector));
        _storageBoundary = storageBoundary ??
            throw new ArgumentNullException(nameof(storageBoundary));
        _notifications = notifications ??
            throw new ArgumentNullException(nameof(notifications));
    }

    public async Task<AiSessionPage> ListAsync(
        ListSessionsRequest request,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);
        int limit = NormalizeLimit(request.Limit);
        IReadOnlyList<SessionCatalogItem> sessions = await _catalog
            .ListAsync(cancellationToken)
            .ConfigureAwait(false);
        int startIndex = ResolveListStart(request.Cursor, sessions);
        SessionCatalogItem[] selected = sessions
            .Skip(startIndex)
            .Take(limit)
            .ToArray();
        var summaries = new List<AiSessionSummaryDto>(selected.Length);
        foreach (SessionCatalogItem item in selected)
        {
            summaries.Add(await ReadSummaryAsync(item, cancellationToken)
                .ConfigureAwait(false));
        }

        bool hasMore = startIndex + selected.Length < sessions.Count;
        string? nextCursor = hasMore && selected.Length > 0
            ? ProtectListCursor(selected[^1].SessionId)
            : null;
        return new AiSessionPage(summaries, nextCursor, hasMore);
    }

    public async Task<AiEventPage> ReadAsync(
        ReadEventsRequest request,
        DateTimeOffset now,
        CancellationToken cancellationToken = default) =>
        (await ReadCoreAsync(request, now, cancellationToken).ConfigureAwait(false)).Page;

    public async Task<AiEventPage> WaitAsync(
        string clientId,
        WaitEventsRequest request,
        DateTimeOffset now,
        CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(clientId);
        ArgumentNullException.ThrowIfNull(request);
        if (!_activeWaitClients.TryAdd(clientId, 0))
        {
            throw new AiSessionException(
                AiErrorCodes.LimitExceeded,
                "Only one wait request may be active for a client.");
        }

        try
        {
            ReadEventsRequest readRequest = ToReadRequest(request);
            ReadResult first = await ReadCoreAsync(readRequest, now, cancellationToken)
                .ConfigureAwait(false);
            if (HasProgress(first))
            {
                return first.Page;
            }

            await using ICommitRegistration registration =
                _notifications.Register(request.SessionId);
            ReadResult second = await ReadCoreAsync(readRequest, now, cancellationToken)
                .ConfigureAwait(false);
            if (HasProgress(second))
            {
                return second.Page;
            }

            TimeSpan timeout = NormalizeWaitTimeout(request.TimeoutSeconds);
            _ = await registration.WaitAsync(timeout, cancellationToken)
                .ConfigureAwait(false);
            return (await ReadCoreAsync(readRequest, now, cancellationToken)
                    .ConfigureAwait(false))
                .Page;
        }
        finally
        {
            _activeWaitClients.TryRemove(clientId, out _);
        }
    }

    public async Task<AiExportDto> ExportAsync(
        ExportSessionRequest request,
        DateTimeOffset now,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);
        ArgumentException.ThrowIfNullOrWhiteSpace(request.SessionId);
        string format = NormalizeExportFormat(request.Format);
        string label = NormalizeExportLabel(request.SuggestedLabel);

        using ResolvedSession session = await _catalog
            .ResolveAsync(request.SessionId, cancellationToken)
            .ConfigureAwait(false);
        await using SqliteSessionExportSnapshot snapshot =
            await SqliteSessionExportSnapshot
                .OpenAsync(session.FullPath, cancellationToken)
                .ConfigureAwait(false);
        (string path, FileStream stream) = CreateUniqueExportFile(label, format, now);
        string exportId = Guid.NewGuid().ToString("N");
        try
        {
            await using (stream.ConfigureAwait(false))
            {
                await WriteExportAsync(stream, snapshot, format, cancellationToken)
                    .ConfigureAwait(false);
                await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
                stream.Flush(flushToDisk: true);
                long byteLength = stream.Length;
                stream.Position = 0;
                byte[] hash = await SHA256.HashDataAsync(stream, cancellationToken)
                    .ConfigureAwait(false);
                _storageBoundary.VerifyExportPath(path);
                return new AiExportDto(
                    exportId,
                    Path.GetFileName(path),
                    path,
                    format,
                    byteLength.ToString(CultureInfo.InvariantCulture),
                    Convert.ToHexString(hash),
                    now.ToUniversalTime().ToString("O", CultureInfo.InvariantCulture));
            }
        }
        catch
        {
            TryDeleteExport(path);
            throw;
        }
    }

    private async Task<ReadResult> ReadCoreAsync(
        ReadEventsRequest request,
        DateTimeOffset now,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        ArgumentException.ThrowIfNullOrWhiteSpace(request.SessionId);
        int limit = NormalizeLimit(request.Limit);
        NormalizedFilter filter = NormalizeFilter(request.Filter);
        long? afterSequence = ParseAfterSequence(request.AfterSequence);
        CursorResolution position = _cursorProtector.ResolvePosition(
            request.SessionId,
            filter.Hash,
            request.Cursor,
            request.ResumeReceipt,
            afterSequence,
            request.AllowUnverifiedSeek,
            now);

        using ResolvedSession session = await _catalog
            .ResolveAsync(request.SessionId, cancellationToken)
            .ConfigureAwait(false);
        var reader = new ReadOnlySessionReader(session.FullPath);
        var query = new SessionEventQuery(
            position.Sequence,
            limit,
            filter.DeviceIds,
            filter.Kinds,
            filter.FromUtc,
            filter.ToUtc);
        SessionEventPage source = await reader.ReadAsync(query, cancellationToken)
            .ConfigureAwait(false);
        List<AiEventDto> events = MapEvents(source.Events, filter);

        int budgetCount = CountEventsWithinBudget(events);
        if (budgetCount == 0 && events.Count > 0)
        {
            throw new AiSessionException(
                AiErrorCodes.ResponseBudgetExceeded,
                "A single event exceeds the maximum AI response budget.");
        }

        if (budgetCount < events.Count)
        {
            query = query with { Limit = budgetCount };
            source = await reader.ReadAsync(query, cancellationToken).ConfigureAwait(false);
            events = MapEvents(source.Events, filter);
        }

        AiEventPage page = BuildPage(
            request.SessionId,
            filter.Hash,
            position,
            source,
            events,
            now);
        int encodedLength = JsonSerializer.SerializeToUtf8Bytes(
            page,
            AiJson.CreateOptions()).Length;
        while (encodedLength > AiProtocol.MaximumResponseBytes && events.Count > 1)
        {
            int reducedLimit = Math.Max(
                1,
                (int)Math.Floor(
                    events.Count *
                    (AiProtocol.MaximumResponseBytes / (double)encodedLength) *
                    0.95));
            if (reducedLimit >= events.Count)
            {
                reducedLimit = events.Count - 1;
            }

            query = query with { Limit = reducedLimit };
            source = await reader.ReadAsync(query, cancellationToken).ConfigureAwait(false);
            events = MapEvents(source.Events, filter);
            page = BuildPage(
                request.SessionId,
                filter.Hash,
                position,
                source,
                events,
                now);
            encodedLength = JsonSerializer.SerializeToUtf8Bytes(
                page,
                AiJson.CreateOptions()).Length;
        }

        if (encodedLength > AiProtocol.MaximumResponseBytes)
        {
            throw new AiSessionException(
                AiErrorCodes.ResponseBudgetExceeded,
                "The AI event page exceeds the maximum response budget.");
        }

        return new ReadResult(page, position.Sequence);
    }

    private AiEventPage BuildPage(
        string sessionId,
        string filterHash,
        CursorResolution position,
        SessionEventPage source,
        IReadOnlyList<AiEventDto> events,
        DateTimeOffset now)
    {
        long scannedThrough = source.ScannedThroughSequence;
        SignedCursor cursor = _cursorProtector.ProtectCursor(
            sessionId,
            filterHash,
            scannedThrough,
            now);
        SignedResumeReceipt receipt = _cursorProtector.ProtectResumeReceipt(
            sessionId,
            filterHash,
            scannedThrough,
            now);
        bool statsKnown = AreRunStatisticsTrustworthy(
            source.StatsKnown,
            source.Runs);
        IReadOnlyList<string> integrityCodes = source.IntegrityCodes
            .Concat(BuildIntegrityCodes(source.Markers, statsKnown))
            .Distinct(StringComparer.Ordinal)
            .ToArray();
        AiIntegrityDto integrity = BuildIntegrity(
            source.SchemaVersion,
            statsKnown,
            integrityCodes,
            source.Runs,
            source.Markers,
            source.Events,
            position.ContinuityProven);
        IReadOnlyList<string> warnings = position.Warnings
            .Concat(integrityCodes)
            .Distinct(StringComparer.Ordinal)
            .ToArray();
        return new AiEventPage(
            events,
            cursor.Value,
            source.HasMore,
            scannedThrough.ToString(CultureInfo.InvariantCulture),
            receipt.Value,
            integrity,
            warnings);
    }

    private async Task<AiSessionSummaryDto> ReadSummaryAsync(
        SessionCatalogItem item,
        CancellationToken cancellationToken)
    {
        using ResolvedSession session = await _catalog
            .ResolveAsync(item.SessionId, cancellationToken)
            .ConfigureAwait(false);
        var reader = new ReadOnlySessionReader(session.FullPath);
        int schemaVersion = await reader.GetSchemaVersionAsync(cancellationToken)
            .ConfigureAwait(false);
        IReadOnlyList<CaptureRunRecord> runs = await reader
            .ReadRunsAsync(cancellationToken)
            .ConfigureAwait(false);
        var markers = new List<IntegrityMarker>();
        foreach (CaptureRunRecord run in runs)
        {
            markers.AddRange(await reader.ReadMarkersAsync(run.RunId, cancellationToken)
                .ConfigureAwait(false));
        }

        long count = 0;
        long sequence = 0;
        while (true)
        {
            IReadOnlyList<CaptureEvent> page = await reader.ReadAfterAsync(
                sequence,
                ExportReadPageSize,
                cancellationToken).ConfigureAwait(false);
            if (page.Count == 0)
            {
                break;
            }

            count = checked(count + page.Count);
            sequence = page[^1].Sequence;
        }

        DateTimeOffset startedUtc = runs.Count > 0
            ? runs.Min(static run => run.StartedUtc)
            : new DateTimeOffset(File.GetCreationTimeUtc(session.FullPath), TimeSpan.Zero);
        DateTimeOffset? stoppedUtc = runs.Count > 0 && runs.All(static run => run.StoppedUtc is not null)
            ? runs.Max(static run => run.StoppedUtc)
            : null;
        bool statsKnown = AreRunStatisticsTrustworthy(
            runs.Count > 0 && runs.All(static run => run.StatsKnown),
            runs);
        IReadOnlyList<string> codes = schemaVersion < 3
            ? [AiErrorCodes.LegacyIntegrityUnknown]
            : BuildIntegrityCodes(markers, statsKnown);
        AiIntegrityDto integrity = BuildIntegrity(
            schemaVersion,
            statsKnown,
            codes,
            runs,
            markers,
            events: [],
            continuityProven: true);
        string? generation = runs.Count == 0
            ? null
            : runs.Max(static run => run.Generation).ToString(CultureInfo.InvariantCulture);
        return new AiSessionSummaryDto(
            item.SessionId,
            item.DisplayName,
            schemaVersion,
            startedUtc.ToUniversalTime().ToString("O", CultureInfo.InvariantCulture),
            stoppedUtc?.ToUniversalTime().ToString("O", CultureInfo.InvariantCulture),
            count.ToString(CultureInfo.InvariantCulture),
            generation,
            integrity);
    }

    private static AiIntegrityDto BuildIntegrity(
        int schemaVersion,
        bool statsKnown,
        IReadOnlyList<string> codes,
        IReadOnlyList<CaptureRunRecord> runs,
        IReadOnlyList<IntegrityMarker> markers,
        IReadOnlyList<CaptureEvent> events,
        bool continuityProven)
    {
        statsKnown = AreRunStatisticsTrustworthy(statsKnown, runs);
        long driverDropped = SaturatingSum(markers
            .Where(static marker => marker.MarkerType == "DRIVER_DROPPED")
            .Select(static marker => Math.Max(0, marker.CountDelta)));
        long serviceDropped = SaturatingSum(runs
            .Select(static run => Math.Max(0, run.ServiceDropped)));
        bool truncationSeen = events.Any(static item => item.Flags.HasFlag(CaptureFlags.Truncated)) ||
            runs.Any(static run => run.TruncationCount > 0) ||
            markers.Any(static marker => marker.MarkerType == "TRUNCATED");
        bool gapDetected = codes.Contains(AiErrorCodes.DataGap, StringComparer.Ordinal) ||
            markers.Any(static marker => marker.Code == "DATA_GAP") ||
            driverDropped > 0 ||
            serviceDropped > 0 ||
            truncationSeen;
        DateTimeOffset? sampledAt = runs
            .Select(static run => run.EndStats?.SampledAtUtc ?? run.StartStats.SampledAtUtc)
            .Cast<DateTimeOffset?>()
            .Max();
        string? generation = runs.Count == 0
            ? null
            : runs.Max(static run => run.Generation).ToString(CultureInfo.InvariantCulture);
        return new AiIntegrityDto(
            schemaVersion,
            statsKnown,
            statsKnown ? driverDropped.ToString(CultureInfo.InvariantCulture) : null,
            serviceDropped.ToString(CultureInfo.InvariantCulture),
            truncationSeen,
            gapDetected,
            continuityProven,
            continuityProven && statsKnown && !gapDetected,
            sampledAt?.ToUniversalTime().ToString("O", CultureInfo.InvariantCulture),
            generation);
    }

    private static bool AreRunStatisticsTrustworthy(
        bool sourceStatsKnown,
        IReadOnlyList<CaptureRunRecord> runs) =>
        sourceStatsKnown &&
        runs.Count > 0 &&
        runs.All(static run =>
            run.StatsKnown &&
            run.StoppedUtc is not null &&
            run.CleanShutdown &&
            !string.Equals(
                run.EndReason,
                "INTERRUPTED",
                StringComparison.Ordinal) &&
            !string.Equals(
                run.EndReason,
                "SERVICE_RESTART",
                StringComparison.Ordinal));

    private static IReadOnlyList<string> BuildIntegrityCodes(
        IReadOnlyList<IntegrityMarker> markers,
        bool statsKnown)
    {
        var codes = markers
            .OrderBy(static marker => marker.AfterSequence)
            .ThenBy(static marker => marker.MarkerId)
            .Select(static marker => marker.Code)
            .Distinct(StringComparer.Ordinal)
            .ToList();
        if (!statsKnown && !codes.Contains(AiErrorCodes.IntegrityUnknown, StringComparer.Ordinal))
        {
            codes.Add(AiErrorCodes.IntegrityUnknown);
        }

        return codes;
    }

    private static List<AiEventDto> MapEvents(
        IReadOnlyList<CaptureEvent> events,
        NormalizedFilter filter)
    {
        var mapped = new List<AiEventDto>(events.Count);
        foreach (CaptureEvent captureEvent in events)
        {
            AiEventDto item = AiEventMapper.Map(captureEvent, filter.IncludeHex);
            if (filter.IncludeTextPreview)
            {
                int length = Math.Min(
                    captureEvent.Payload.Length,
                    filter.TextPreviewMaxBytes);
                item = item with
                {
                    TextPreview = Encoding.UTF8.GetString(
                        captureEvent.Payload.AsSpan(0, length)),
                };
            }

            mapped.Add(item);
        }

        return mapped;
    }

    private static int CountEventsWithinBudget(IReadOnlyList<AiEventDto> events)
    {
        int budget = AiProtocol.MaximumResponseBytes - ResponseEnvelopeReserve;
        int used = 0;
        int count = 0;
        JsonSerializerOptions options = AiJson.CreateOptions();
        foreach (AiEventDto item in events)
        {
            int encodedLength = JsonSerializer.SerializeToUtf8Bytes(item, options).Length + 1;
            if (encodedLength > budget - used)
            {
                break;
            }

            used += encodedLength;
            count++;
        }

        return count;
    }

    private static NormalizedFilter NormalizeFilter(AiEventFilter? filter)
    {
        filter ??= new AiEventFilter(null, null, null, null);
        if (filter.TextPreviewMaxBytes is < 0 or > MaximumTextPreviewBytes)
        {
            throw new ArgumentOutOfRangeException(
                nameof(filter),
                "TextPreviewMaxBytes must be between 0 and 4096.");
        }

        ulong[]? deviceIds = filter.DeviceIds is null
            ? null
            : filter.DeviceIds.Select(ParseDeviceId).Distinct().Order().ToArray();
        CaptureKind[]? kinds = filter.Kinds is null
            ? null
            : filter.Kinds.Select(ParseKind).Distinct().Order().ToArray();
        DateTimeOffset? fromUtc = ParseUtc(filter.FromUtc, nameof(filter.FromUtc));
        DateTimeOffset? toUtc = ParseUtc(filter.ToUtc, nameof(filter.ToUtc));
        if (fromUtc is not null && toUtc is not null && fromUtc >= toUtc)
        {
            throw new ArgumentException("FromUtc must be earlier than ToUtc.", nameof(filter));
        }

        var canonical = new CanonicalFilter(
            deviceIds?.Select(static value => value.ToString("X16", CultureInfo.InvariantCulture))
                .ToArray(),
            kinds?.Select(static value => value.ToString()).ToArray(),
            fromUtc?.ToString("O", CultureInfo.InvariantCulture),
            toUtc?.ToString("O", CultureInfo.InvariantCulture),
            filter.IncludeHex,
            filter.IncludeTextPreview,
            filter.TextPreviewMaxBytes);
        byte[] bytes = JsonSerializer.SerializeToUtf8Bytes(canonical, AiJson.CreateOptions());
        string hash = "sha256:" + Convert.ToHexString(SHA256.HashData(bytes));
        return new NormalizedFilter(
            deviceIds,
            kinds,
            fromUtc,
            toUtc,
            filter.IncludeHex,
            filter.IncludeTextPreview,
            filter.TextPreviewMaxBytes,
            hash);
    }

    private static ulong ParseDeviceId(string value)
    {
        if (string.IsNullOrWhiteSpace(value) ||
            value.Length != 16 ||
            !ulong.TryParse(
                value,
                NumberStyles.AllowHexSpecifier,
                CultureInfo.InvariantCulture,
                out ulong deviceId))
        {
            throw new ArgumentException(
                "Device IDs must be uppercase-compatible 16-digit hexadecimal values.");
        }

        return deviceId;
    }

    private static CaptureKind ParseKind(string value)
    {
        if (string.IsNullOrWhiteSpace(value) ||
            !Enum.TryParse(value, ignoreCase: false, out CaptureKind kind) ||
            !Enum.IsDefined(kind))
        {
            throw new ArgumentException($"Unknown capture kind: {value}");
        }

        return kind;
    }

    private static DateTimeOffset? ParseUtc(string? value, string parameterName)
    {
        if (value is null)
        {
            return null;
        }

        if (!DateTimeOffset.TryParse(
                value,
                CultureInfo.InvariantCulture,
                DateTimeStyles.RoundtripKind,
                out DateTimeOffset parsed))
        {
            throw new ArgumentException("The timestamp must be ISO-8601.", parameterName);
        }

        return parsed.ToUniversalTime();
    }

    private static long? ParseAfterSequence(string? value)
    {
        if (value is null)
        {
            return null;
        }

        if (!long.TryParse(
                value,
                NumberStyles.None,
                CultureInfo.InvariantCulture,
                out long sequence) ||
            sequence < 0)
        {
            throw new AiCursorException(
                AiErrorCodes.InvalidCursor,
                "AfterSequence must be a non-negative decimal Int64 string.");
        }

        return sequence;
    }

    private static ReadEventsRequest ToReadRequest(WaitEventsRequest request) =>
        new(
            request.SessionId,
            request.Cursor,
            request.ResumeReceipt,
            request.AfterSequence,
            request.AllowUnverifiedSeek,
            request.Limit,
            request.Filter);

    private static bool HasProgress(ReadResult result) =>
        result.Page.Events.Count > 0 ||
        result.Page.HasMore ||
        long.Parse(
            result.Page.ScannedThroughSequence,
            CultureInfo.InvariantCulture) > result.StartSequence;

    private static int NormalizeLimit(int limit)
    {
        if (limit == 0)
        {
            return AiProtocol.DefaultPageSize;
        }

        if (limit is < 1 or > AiProtocol.MaximumPageSize)
        {
            throw new AiSessionException(
                AiErrorCodes.LimitExceeded,
                $"The page limit must be between 1 and {AiProtocol.MaximumPageSize}.");
        }

        return limit;
    }

    private static TimeSpan NormalizeWaitTimeout(int timeoutSeconds)
    {
        if (timeoutSeconds <= 0)
        {
            return TimeSpan.Zero;
        }

        return TimeSpan.FromSeconds(Math.Min(
            timeoutSeconds,
            (int)AiProtocol.MaximumWait.TotalSeconds));
    }

    private static int ResolveListStart(
        string? cursor,
        IReadOnlyList<SessionCatalogItem> sessions)
    {
        if (cursor is null)
        {
            return 0;
        }

        if (!TryUnprotectListCursor(cursor, out string sessionId))
        {
            throw new AiCursorException(
                AiErrorCodes.InvalidCursor,
                "The session-list cursor is malformed.");
        }

        int index = sessions
            .Select(static (item, position) => (item, position))
            .Where(pair => string.Equals(
                pair.item.SessionId,
                sessionId,
                StringComparison.Ordinal))
            .Select(static pair => pair.position)
            .DefaultIfEmpty(-1)
            .Single();
        if (index < 0)
        {
            throw new AiCursorException(
                AiErrorCodes.InvalidCursor,
                "The session-list cursor no longer identifies a managed session.");
        }

        return index + 1;
    }

    private static string ProtectListCursor(string sessionId) =>
        string.Join(
            '.',
            SessionListCursorPrefix,
            Base64UrlEncode(Encoding.UTF8.GetBytes(sessionId)));

    private static bool TryUnprotectListCursor(string cursor, out string sessionId)
    {
        sessionId = string.Empty;
        string[] parts = cursor.Split('.');
        if (parts.Length != 2 ||
            parts[0] != SessionListCursorPrefix ||
            !TryBase64UrlDecode(parts[1], out byte[] bytes))
        {
            return false;
        }

        try
        {
            sessionId = new UTF8Encoding(false, true).GetString(bytes);
            return sessionId.StartsWith("s1.", StringComparison.Ordinal);
        }
        catch (DecoderFallbackException)
        {
            return false;
        }
    }

    private static string NormalizeExportFormat(string format)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(format);
        string normalized = format.Trim().ToLowerInvariant();
        return normalized is "json" or "jsonl" or "csv" or "txt" or "raw"
            ? normalized
            : throw new ArgumentException(
                "Export format must be json, jsonl, csv, txt, or raw.",
                nameof(format));
    }

    private static string NormalizeExportLabel(string? label)
    {
        if (string.IsNullOrWhiteSpace(label))
        {
            return "session";
        }

        string trimmed = label.Trim();
        if (trimmed.Contains("..", StringComparison.Ordinal) ||
            trimmed.IndexOfAny([Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar]) >= 0 ||
            Path.IsPathRooted(trimmed))
        {
            throw new ArgumentException(
                "SuggestedLabel must be a label, not a directory or path.",
                nameof(label));
        }

        var result = new StringBuilder(Math.Min(trimmed.Length, 48));
        bool separator = false;
        foreach (char character in trimmed.Normalize(NormalizationForm.FormC))
        {
            if (result.Length >= 48)
            {
                break;
            }

            if (char.IsLetterOrDigit(character) || character is '-' or '_')
            {
                result.Append(character);
                separator = false;
            }
            else if (!separator)
            {
                result.Append('-');
                separator = true;
            }
        }

        string safe = result.ToString().Trim('-');
        return safe.Length == 0 ? "session" : safe;
    }

    private (string Path, FileStream Stream) CreateUniqueExportFile(
        string label,
        string format,
        DateTimeOffset now)
    {
        string timestamp = now.ToUniversalTime().ToString(
            "yyyyMMdd-HHmmss",
            CultureInfo.InvariantCulture);
        for (int attempt = 0; attempt < 16; attempt++)
        {
            string fileName = string.Create(
                CultureInfo.InvariantCulture,
                $"{label}-{timestamp}-{Guid.NewGuid():N}.{format}");
            string path = Path.Combine(_storageBoundary.ExportRoot, fileName);
            try
            {
                using (var reservation = new FileStream(
                           path,
                           FileMode.CreateNew,
                           FileAccess.ReadWrite,
                           FileShare.Read,
                           bufferSize: 4096,
                           FileOptions.WriteThrough))
                {
                    reservation.Flush(flushToDisk: true);
                }

                _storageBoundary.VerifyExportPath(path);
                return (
                    path,
                    new FileStream(
                        path,
                        FileMode.Open,
                        FileAccess.ReadWrite,
                        FileShare.Read,
                        bufferSize: 64 * 1024,
                        FileOptions.Asynchronous | FileOptions.WriteThrough));
            }
            catch (IOException) when (File.Exists(path))
            {
                // CreateNew collision: generate another service-owned unique name.
            }
        }

        throw new AiSessionException(
            AiErrorCodes.ExportExists,
            "A unique export file could not be created.");
    }

    private static async Task WriteExportAsync(
        Stream stream,
        SqliteSessionExportSnapshot snapshot,
        string format,
        CancellationToken cancellationToken)
    {
        switch (format)
        {
            case "csv":
                await WriteCsvExportAsync(stream, snapshot, cancellationToken)
                    .ConfigureAwait(false);
                return;
            case "txt":
                await WritePagedExportAsync(
                    stream,
                    snapshot,
                    new TextCaptureExporter(),
                    cancellationToken).ConfigureAwait(false);
                return;
            case "raw":
                await WritePagedExportAsync(
                    stream,
                    snapshot,
                    new RawCaptureExporter(),
                    cancellationToken).ConfigureAwait(false);
                return;
            case "json":
                await WriteJsonExportAsync(stream, snapshot, cancellationToken)
                    .ConfigureAwait(false);
                return;
            case "jsonl":
                await WriteJsonLinesExportAsync(stream, snapshot, cancellationToken)
                    .ConfigureAwait(false);
                return;
            default:
                throw new UnreachableException();
        }
    }

    private static async Task WritePagedExportAsync(
        Stream stream,
        SqliteSessionExportSnapshot snapshot,
        ICaptureExporter exporter,
        CancellationToken cancellationToken)
    {
        while (true)
        {
            IReadOnlyList<CaptureEvent> page = await snapshot
                .ReadNextAsync(ExportReadPageSize, cancellationToken)
                .ConfigureAwait(false);
            if (page.Count == 0)
            {
                return;
            }

            await exporter.ExportAsync(stream, page, cancellationToken)
                .ConfigureAwait(false);
        }
    }

    private static async Task WriteCsvExportAsync(
        Stream stream,
        SqliteSessionExportSnapshot snapshot,
        CancellationToken cancellationToken)
    {
        const string header = "Sequence,Timestamp,Port,Direction,Process,Data\r\n";
        await stream.WriteAsync(Encoding.UTF8.GetPreamble(), cancellationToken)
            .ConfigureAwait(false);
        await stream.WriteAsync(Encoding.UTF8.GetBytes(header), cancellationToken)
            .ConfigureAwait(false);
        var options = new CopyOptions(
            CopyFormat.Csv,
            IncludeSequence: true,
            IncludeTimestamp: true,
            IncludePort: true,
            IncludeDirection: true,
            IncludeProcess: true);
        while (true)
        {
            IReadOnlyList<CaptureEvent> page = await snapshot
                .ReadNextAsync(ExportReadPageSize, cancellationToken)
                .ConfigureAwait(false);
            if (page.Count == 0)
            {
                return;
            }

            string formatted = CopyFormatter.Format(page, options, Encoding.UTF8);
            if (!formatted.StartsWith(header, StringComparison.Ordinal))
            {
                throw new InvalidDataException("The CSV formatter returned an unexpected header.");
            }

            await stream.WriteAsync(
                    Encoding.UTF8.GetBytes(formatted[header.Length..]),
                    cancellationToken)
                .ConfigureAwait(false);
        }
    }

    private static async Task WriteJsonExportAsync(
        Stream stream,
        SqliteSessionExportSnapshot snapshot,
        CancellationToken cancellationToken)
    {
        JsonSerializerOptions options = AiJson.CreateOptions();
        await using var writer = new Utf8JsonWriter(stream);
        writer.WriteStartArray();
        while (true)
        {
            IReadOnlyList<CaptureEvent> page = await snapshot
                .ReadNextAsync(ExportReadPageSize, cancellationToken)
                .ConfigureAwait(false);
            if (page.Count == 0)
            {
                break;
            }

            foreach (CaptureEvent captureEvent in page)
            {
                JsonSerializer.Serialize(
                    writer,
                    AiEventMapper.Map(captureEvent, includeHex: true),
                    options);
            }
        }

        writer.WriteEndArray();
        await writer.FlushAsync(cancellationToken).ConfigureAwait(false);
    }

    private static async Task WriteJsonLinesExportAsync(
        Stream stream,
        SqliteSessionExportSnapshot snapshot,
        CancellationToken cancellationToken)
    {
        JsonSerializerOptions options = AiJson.CreateOptions();
        while (true)
        {
            IReadOnlyList<CaptureEvent> page = await snapshot
                .ReadNextAsync(ExportReadPageSize, cancellationToken)
                .ConfigureAwait(false);
            if (page.Count == 0)
            {
                return;
            }

            foreach (CaptureEvent captureEvent in page)
            {
                byte[] line = JsonSerializer.SerializeToUtf8Bytes(
                    AiEventMapper.Map(captureEvent, includeHex: true),
                    options);
                await stream.WriteAsync(line, cancellationToken).ConfigureAwait(false);
                await stream.WriteAsync("\n"u8.ToArray(), cancellationToken)
                    .ConfigureAwait(false);
            }
        }
    }

    private static void TryDeleteExport(string path)
    {
        try
        {
            File.Delete(path);
        }
        catch (Exception exception) when (
            exception is IOException or UnauthorizedAccessException)
        {
            // A partial service-owned export is non-authoritative and can be cleaned later.
        }
    }

    private static long SaturatingSum(IEnumerable<long> values)
    {
        long total = 0;
        foreach (long value in values)
        {
            if (value > long.MaxValue - total)
            {
                return long.MaxValue;
            }

            total += value;
        }

        return total;
    }

    private static bool TryBase64UrlDecode(string value, out byte[] bytes)
    {
        bytes = [];
        if (value.Length == 0 || value.Length % 4 == 1)
        {
            return false;
        }

        try
        {
            string base64 = value.Replace('-', '+').Replace('_', '/');
            base64 = base64.PadRight(
                base64.Length + ((4 - base64.Length % 4) % 4),
                '=');
            bytes = Convert.FromBase64String(base64);
            return string.Equals(Base64UrlEncode(bytes), value, StringComparison.Ordinal);
        }
        catch (FormatException)
        {
            return false;
        }
    }

    private static string Base64UrlEncode(ReadOnlySpan<byte> bytes) =>
        Convert.ToBase64String(bytes)
            .TrimEnd('=')
            .Replace('+', '-')
            .Replace('/', '_');

    private sealed record ReadResult(AiEventPage Page, long StartSequence);

    private sealed record NormalizedFilter(
        IReadOnlyList<ulong>? DeviceIds,
        IReadOnlyList<CaptureKind>? Kinds,
        DateTimeOffset? FromUtc,
        DateTimeOffset? ToUtc,
        bool IncludeHex,
        bool IncludeTextPreview,
        int TextPreviewMaxBytes,
        string Hash);

    private sealed record CanonicalFilter(
        IReadOnlyList<string>? DeviceIds,
        IReadOnlyList<string>? Kinds,
        string? FromUtc,
        string? ToUtc,
        bool IncludeHex,
        bool IncludeTextPreview,
        int TextPreviewMaxBytes);
}
