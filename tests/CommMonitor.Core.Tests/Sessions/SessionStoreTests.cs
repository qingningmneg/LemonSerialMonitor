using System.Collections.Immutable;
using System.Reflection;
using CommMonitor.Core.Models;
using CommMonitor.Core.Sessions;
using Microsoft.Data.Sqlite;

namespace CommMonitor.Core.Tests.Sessions;

public sealed class SessionStoreTests
{
    [Fact]
    public async Task AppendAsync_round_trips_every_capture_event_field_after_reopening()
    {
        string directory = CreateTemporaryDirectory();
        string path = Path.Combine(directory, $"{Guid.NewGuid():N}.cmsession");

        try
        {
            CaptureEvent[] expected =
            [
                CreateEvent(
                    sequence: 1,
                    qpcTicks: 10_001,
                    deviceId: 0xFEDCBA9876543210UL,
                    processId: 42,
                    kind: CaptureKind.Write,
                    ioctlCode: 0xAABBCCDDU,
                    ntStatus: unchecked((int)0xC0000001U),
                    requestedLength: 4,
                    completedLength: 3,
                    flags: CaptureFlags.Truncated | CaptureFlags.InputPayload,
                    payload: [0x01, 0x02, 0xFF],
                    portName: "COM7",
                    processName: "terminal.exe",
                    timestamp: new DateTimeOffset(2026, 7, 10, 1, 2, 3, 456, TimeSpan.Zero).AddTicks(7890)),
                CreateEvent(
                    sequence: 2,
                    qpcTicks: 10_002,
                    deviceId: 0x0123456789ABCDEFUL,
                    processId: 99,
                    kind: CaptureKind.Read,
                    ioctlCode: 0x11223344U,
                    ntStatus: 0,
                    requestedLength: 2,
                    completedLength: 2,
                    flags: CaptureFlags.OutputPayload,
                    payload: [0x00, 0x80],
                    portName: "COM12",
                    processName: "reader.exe",
                    timestamp: new DateTimeOffset(2026, 7, 10, 1, 2, 4, 567, TimeSpan.Zero).AddTicks(1234)),
            ];

            var writer = new SessionStore(path);
            await writer.InitializeAsync(CancellationToken.None);
            await writer.AppendAsync(expected, CancellationToken.None);

            var reader = new SessionStore(path);
            await reader.InitializeAsync(CancellationToken.None);
            IReadOnlyList<CaptureEvent> actual = await reader.ReadAfterAsync(
                0,
                100,
                CancellationToken.None);

            Assert.Equal(expected.Length, actual.Count);
            for (int index = 0; index < expected.Length; index++)
            {
                AssertEventEqual(expected[index], actual[index]);
            }

            CaptureEvent afterCursor = Assert.Single(
                await reader.ReadAfterAsync(1, 1, CancellationToken.None));
            AssertEventEqual(expected[1], afterCursor);
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public async Task Every_connection_uses_normal_synchronous_mode()
    {
        string directory = CreateTemporaryDirectory();
        string path = Path.Combine(directory, $"{Guid.NewGuid():N}.cmsession");

        try
        {
            var store = new SessionStore(path);
            await store.InitializeAsync(CancellationToken.None);
            MethodInfo openConnection = typeof(SessionStore).GetMethod(
                "OpenConnectionAsync",
                BindingFlags.Instance | BindingFlags.NonPublic)!;
            var connectionTask = (Task<SqliteConnection>)openConnection.Invoke(
                store,
                [CancellationToken.None])!;
            await using SqliteConnection connection = await connectionTask;
            await using SqliteCommand command = connection.CreateCommand();
            command.CommandText = "PRAGMA synchronous;";

            long synchronous = (long)(await command.ExecuteScalarAsync(CancellationToken.None))!;

            Assert.Equal(1, synchronous);
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public async Task ClearAsync_removes_all_events()
    {
        string directory = CreateTemporaryDirectory();
        string path = Path.Combine(directory, $"{Guid.NewGuid():N}.cmsession");

        try
        {
            var store = new SessionStore(path);
            await store.InitializeAsync(CancellationToken.None);
            await store.AppendAsync(
                [CreateEvent(sequence: 1, payload: [0x01])],
                CancellationToken.None);

            await store.ClearAsync(CancellationToken.None);

            Assert.Empty(await store.ReadAfterAsync(0, 100, CancellationToken.None));
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public async Task AppendAsync_assigns_monotonic_session_sequences_when_wire_sequence_restarts()
    {
        string directory = CreateTemporaryDirectory();
        string path = Path.Combine(directory, $"{Guid.NewGuid():N}.cmsession");

        try
        {
            var firstStore = new SessionStore(path);
            await firstStore.InitializeAsync(CancellationToken.None);
            IReadOnlyList<CaptureEvent> firstPersisted = await firstStore.AppendAsync(
                [CreateEvent(sequence: 1, payload: [0xA1])],
                CancellationToken.None);

            var reopenedStore = new SessionStore(path);
            await reopenedStore.InitializeAsync(CancellationToken.None);
            IReadOnlyList<CaptureEvent> secondPersisted = await reopenedStore.AppendAsync(
                [CreateEvent(sequence: 1, payload: [0xB2])],
                CancellationToken.None);

            CaptureEvent first = Assert.Single(firstPersisted);
            Assert.Equal(1, first.Sequence);
            Assert.Equal(1, first.WireSequence);
            CaptureEvent second = Assert.Single(secondPersisted);
            Assert.Equal(2, second.Sequence);
            Assert.Equal(1, second.WireSequence);

            IReadOnlyList<CaptureEvent> all = await reopenedStore.ReadAfterAsync(
                0,
                10,
                CancellationToken.None);
            Assert.Equal([1L, 2L], all.Select(captureEvent => captureEvent.Sequence));
            Assert.Equal([1L, 1L], all.Select(captureEvent => captureEvent.WireSequence));
            Assert.Equal(
                [new byte[] { 0xA1 }, new byte[] { 0xB2 }],
                all.Select(captureEvent => captureEvent.Payload.AsSpan().ToArray()));
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public async Task AppendAsync_preserves_arrival_order_instead_of_sorting_wire_sequence()
    {
        string directory = CreateTemporaryDirectory();
        string path = Path.Combine(directory, $"{Guid.NewGuid():N}.cmsession");

        try
        {
            var store = new SessionStore(path);
            await store.InitializeAsync(CancellationToken.None);

            IReadOnlyList<CaptureEvent> persisted = await store.AppendAsync(
                [
                    CreateEvent(sequence: 2, payload: [0xA2]),
                    CreateEvent(sequence: 1, payload: [0xA1]),
                ],
                CancellationToken.None);

            Assert.Equal([1L, 2L], persisted.Select(captureEvent => captureEvent.Sequence));
            Assert.Equal([2L, 1L], persisted.Select(captureEvent => captureEvent.WireSequence));
            Assert.Equal(
                [new byte[] { 0xA2 }, new byte[] { 0xA1 }],
                persisted.Select(captureEvent => captureEvent.Payload.AsSpan().ToArray()));
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public async Task InitializeAsync_migrates_v1_idempotently_and_preserves_existing_sequence()
    {
        string directory = CreateTemporaryDirectory();
        string path = Path.Combine(directory, $"{Guid.NewGuid():N}.cmsession");

        try
        {
            await CreateVersionOneSessionAsync(path);

            var store = new SessionStore(path);
            await store.InitializeAsync(CancellationToken.None);
            await store.InitializeAsync(CancellationToken.None);
            IReadOnlyList<CaptureEvent> appended = await store.AppendAsync(
                [CreateEvent(sequence: 1, payload: [0xB2])],
                CancellationToken.None);

            CaptureEvent newEvent = Assert.Single(appended);
            Assert.Equal(43, newEvent.Sequence);
            Assert.Equal(1, newEvent.WireSequence);

            IReadOnlyList<CaptureEvent> all = await store.ReadAfterAsync(
                0,
                10,
                CancellationToken.None);
            Assert.Equal([42L, 43L], all.Select(captureEvent => captureEvent.Sequence));
            Assert.Equal([42L, 1L], all.Select(captureEvent => captureEvent.WireSequence));

            await using var connection = new SqliteConnection($"Data Source={path};Pooling=False");
            await connection.OpenAsync(CancellationToken.None);
            await using SqliteCommand command = connection.CreateCommand();
            command.CommandText = "SELECT value FROM metadata WHERE key = 'schema_version';";
            Assert.Equal("3", await command.ExecuteScalarAsync(CancellationToken.None));
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Theory]
    [InlineData(0)]
    [InlineData(10_001)]
    public async Task ReadAfterAsync_rejects_limits_outside_supported_range(int limit)
    {
        string directory = CreateTemporaryDirectory();
        string path = Path.Combine(directory, $"{Guid.NewGuid():N}.cmsession");

        try
        {
            var store = new SessionStore(path);
            await store.InitializeAsync(CancellationToken.None);

            await Assert.ThrowsAsync<ArgumentOutOfRangeException>(
                () => store.ReadAfterAsync(0, limit, CancellationToken.None));
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    private static string CreateTemporaryDirectory()
    {
        string path = Path.Combine(Path.GetTempPath(), $"CommMonitor-{Guid.NewGuid():N}");
        Directory.CreateDirectory(path);
        return path;
    }

    private static async Task CreateVersionOneSessionAsync(string path)
    {
        await using var connection = new SqliteConnection($"Data Source={path};Pooling=False");
        await connection.OpenAsync(CancellationToken.None);
        await using SqliteCommand command = connection.CreateCommand();
        command.CommandText = """
            CREATE TABLE metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL);
            INSERT INTO metadata(key, value) VALUES('schema_version', '1');
            CREATE TABLE events(
             sequence INTEGER PRIMARY KEY,
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
             sequence, qpc_ticks, timestamp_utc, device_id, port_name,
             process_id, process_name, kind, ioctl_code, nt_status,
             requested_length, completed_length, flags, payload)
            VALUES(
             42, 420, '2026-07-10T00:00:00.0000000+00:00', 1, 'COM1',
             42, 'legacy.exe', 2, 0, 0, 1, 1, 0, X'A1');
            """;
        await command.ExecuteNonQueryAsync(CancellationToken.None);
    }

    private static CaptureEvent CreateEvent(
        long sequence,
        long qpcTicks = 0,
        ulong deviceId = 1,
        int processId = 42,
        CaptureKind kind = CaptureKind.Write,
        uint ioctlCode = 0,
        int ntStatus = 0,
        int requestedLength = 0,
        int completedLength = 0,
        CaptureFlags flags = CaptureFlags.None,
        byte[]? payload = null,
        string portName = "COM1",
        string processName = "process.exe",
        DateTimeOffset timestamp = default) => new(
            sequence,
            qpcTicks,
            deviceId,
            processId,
            kind,
            ioctlCode,
            ntStatus,
            requestedLength,
            completedLength,
            flags,
            ImmutableArray.CreateRange(payload ?? []))
        {
            PortName = portName,
            ProcessName = processName,
            Timestamp = timestamp,
        };

    private static void AssertEventEqual(CaptureEvent expected, CaptureEvent actual)
    {
        Assert.Equal(expected.Sequence, actual.Sequence);
        Assert.Equal(expected.QpcTicks, actual.QpcTicks);
        Assert.Equal(expected.Timestamp, actual.Timestamp);
        Assert.Equal(expected.DeviceId, actual.DeviceId);
        Assert.Equal(expected.PortName, actual.PortName);
        Assert.Equal(expected.ProcessId, actual.ProcessId);
        Assert.Equal(expected.ProcessName, actual.ProcessName);
        Assert.Equal(expected.Kind, actual.Kind);
        Assert.Equal(expected.IoctlCode, actual.IoctlCode);
        Assert.Equal(expected.NtStatus, actual.NtStatus);
        Assert.Equal(expected.RequestedLength, actual.RequestedLength);
        Assert.Equal(expected.CompletedLength, actual.CompletedLength);
        Assert.Equal(expected.Flags, actual.Flags);
        Assert.Equal(expected.Payload.AsSpan().ToArray(), actual.Payload.AsSpan().ToArray());
    }
}
