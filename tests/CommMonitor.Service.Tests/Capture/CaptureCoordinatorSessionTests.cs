using System.Collections.Immutable;
using System.Threading.Channels;
using CommMonitor.Core.Models;
using CommMonitor.Core.Sessions;
using CommMonitor.Service.Capture;

namespace CommMonitor.Service.Tests.Capture;

public sealed class CaptureCoordinatorSessionTests
{
    private static readonly TimeSpan TestTimeout = TimeSpan.FromSeconds(2);

    [Fact]
    public async Task StartAsync_persists_each_run_to_the_requested_session_path()
    {
        await using var directory = new TemporarySessionDirectory();
        string firstPath = directory.GetPath("first.cmsession");
        string secondPath = directory.GetPath("second.cmsession");
        var source = new FakeCaptureSource();
        await using var coordinator = new CaptureCoordinator(source, new SessionStoreFactory());
        Channel<ImmutableArray<CaptureEvent>> published = ObservePublished(coordinator);

        await coordinator.StartAsync(Selection(firstPath));
        await source.EmitAsync(CreateEvent(11, 0xA1));
        await published.Reader.ReadAsync().AsTask().WaitAsync(TestTimeout);
        await coordinator.StopAsync();

        await coordinator.StartAsync(Selection(secondPath));
        await source.EmitAsync(CreateEvent(22, 0xB2));
        await published.Reader.ReadAsync().AsTask().WaitAsync(TestTimeout);
        await coordinator.StopAsync();

        CaptureEvent first = Assert.Single(await ReadAllAsync(firstPath));
        CaptureEvent second = Assert.Single(await ReadAllAsync(secondPath));
        Assert.Equal(11, first.WireSequence);
        Assert.Equal(new byte[] { 0xA1 }, first.Payload.AsSpan().ToArray());
        Assert.Equal(22, second.WireSequence);
        Assert.Equal(new byte[] { 0xB2 }, second.Payload.AsSpan().ToArray());

        CaptureRunRecord firstRun = Assert.Single(await ReadRunsAsync(firstPath));
        CaptureRunRecord secondRun = Assert.Single(await ReadRunsAsync(secondPath));
        Assert.Equal("WPF", firstRun.OwnerType);
        Assert.Equal("S-1-5-21-test", firstRun.OwnerSid);
        Assert.Equal(Path.GetFileName(firstPath), firstRun.SessionId);
        Assert.Equal(Path.GetFileName(secondPath), secondRun.SessionId);
    }

    [Fact]
    public async Task Reopened_session_resequences_reset_wire_values_before_publish_and_persist()
    {
        await using var directory = new TemporarySessionDirectory();
        string path = directory.GetPath("reopened.cmsession");
        var source = new FakeCaptureSource();
        await using var coordinator = new CaptureCoordinator(source, new SessionStoreFactory());
        Channel<ImmutableArray<CaptureEvent>> published = ObservePublished(coordinator);

        await coordinator.StartAsync(Selection(path));
        await source.EmitAsync(CreateEvent(1, 0xA1));
        CaptureEvent firstPublished = Assert.Single(
            await published.Reader.ReadAsync().AsTask().WaitAsync(TestTimeout));
        await coordinator.StopAsync();

        await coordinator.StartAsync(Selection(path));
        await source.EmitAsync(CreateEvent(1, 0xB2));
        CaptureEvent secondPublished = Assert.Single(
            await published.Reader.ReadAsync().AsTask().WaitAsync(TestTimeout));
        await coordinator.StopAsync();

        Assert.Equal(1, firstPublished.Sequence);
        Assert.Equal(1, firstPublished.WireSequence);
        Assert.Equal(2, secondPublished.Sequence);
        Assert.Equal(1, secondPublished.WireSequence);

        IReadOnlyList<CaptureEvent> stored = await ReadAllAsync(path);
        Assert.Equal([1L, 2L], stored.Select(captureEvent => captureEvent.Sequence));
        Assert.Equal([1L, 1L], stored.Select(captureEvent => captureEvent.WireSequence));
    }

    [Fact]
    public async Task ClearAsync_clears_only_the_last_explicitly_started_session()
    {
        await using var directory = new TemporarySessionDirectory();
        string firstPath = directory.GetPath("keep.cmsession");
        string secondPath = directory.GetPath("clear.cmsession");
        var source = new FakeCaptureSource();
        await using var coordinator = new CaptureCoordinator(source, new SessionStoreFactory());
        Channel<ImmutableArray<CaptureEvent>> published = ObservePublished(coordinator);

        await coordinator.StartAsync(Selection(firstPath));
        await source.EmitAsync(CreateEvent(1, 0xA1));
        await published.Reader.ReadAsync().AsTask().WaitAsync(TestTimeout);
        await coordinator.StopAsync();

        await coordinator.StartAsync(Selection(secondPath));
        await source.EmitAsync(CreateEvent(2, 0xB2));
        await published.Reader.ReadAsync().AsTask().WaitAsync(TestTimeout);
        await coordinator.StopAsync();
        await coordinator.ClearAsync();

        Assert.Single(await ReadAllAsync(firstPath));
        Assert.Empty(await ReadAllAsync(secondPath));
    }

    [Fact]
    public async Task ClearAsync_before_any_start_does_not_create_or_clear_a_session()
    {
        var factory = new RecordingSessionStoreFactory();
        await using var coordinator = new CaptureCoordinator(new FakeCaptureSource(), factory);

        await coordinator.ClearAsync();

        Assert.Empty(factory.CreatedPaths);
    }

    [Fact]
    public async Task StartAsync_creates_the_session_directory_on_first_use()
    {
        await using var directory = new TemporarySessionDirectory();
        string missingDirectory = directory.GetPath("not-created-yet");
        string path = Path.Combine(missingDirectory, "first.cmsession");
        var source = new FakeCaptureSource();
        await using var coordinator = new CaptureCoordinator(source, new SessionStoreFactory());

        await coordinator.StartAsync(Selection(path));
        await coordinator.StopAsync();

        Assert.True(Directory.Exists(missingDirectory));
        Assert.True(File.Exists(path));
    }

    [Fact]
    public async Task ExportAsync_after_stop_exports_the_exact_persisted_session()
    {
        await using var directory = new TemporarySessionDirectory();
        string path = directory.GetPath("export.cmsession");
        var source = new FakeCaptureSource();
        await using var coordinator = new CaptureCoordinator(source, new SessionStoreFactory());
        Channel<ImmutableArray<CaptureEvent>> published = ObservePublished(coordinator);
        await coordinator.StartAsync(Selection(path));
        await source.EmitAsync(CreateEvent(3, 0xA1));
        await source.EmitAsync(CreateEvent(4, 0xB2));
        await published.Reader.ReadAsync().AsTask().WaitAsync(TestTimeout);
        await coordinator.StopAsync();
        await using var destination = new MemoryStream();

        await coordinator.ExportAsync(destination, "raw", CancellationToken.None);

        Assert.Equal(new byte[] { 0xA1, 0xB2 }, destination.ToArray());
    }

    [Fact]
    public async Task ExportAsync_rejects_running_or_missing_sessions()
    {
        await using var directory = new TemporarySessionDirectory();
        var source = new FakeCaptureSource();
        await using var coordinator = new CaptureCoordinator(source, new SessionStoreFactory());
        await using var destination = new MemoryStream();

        await Assert.ThrowsAsync<InvalidOperationException>(() =>
            coordinator.ExportAsync(destination, "csv", CancellationToken.None));

        await coordinator.StartAsync(Selection(directory.GetPath("running.cmsession")));
        await Assert.ThrowsAsync<InvalidOperationException>(() =>
            coordinator.ExportAsync(destination, "csv", CancellationToken.None));
        await coordinator.StopAsync();
    }

    private static CaptureSelection Selection(string path) =>
        new(
            new HashSet<ulong> { 0x1234 },
            path,
            $"run-{Guid.NewGuid():N}",
            Path.GetFileName(path),
            "WPF",
            "S-1-5-21-test");

    private static Channel<ImmutableArray<CaptureEvent>> ObservePublished(
        CaptureCoordinator coordinator)
    {
        Channel<ImmutableArray<CaptureEvent>> channel =
            Channel.CreateUnbounded<ImmutableArray<CaptureEvent>>();
        coordinator.EventsPublished += (_, batch) => channel.Writer.TryWrite(batch);
        return channel;
    }

    private static async Task<IReadOnlyList<CaptureEvent>> ReadAllAsync(string path)
    {
        var store = new SessionStore(path);
        await store.InitializeAsync(CancellationToken.None);
        return await store.ReadAfterAsync(0, 100, CancellationToken.None);
    }

    private static async Task<IReadOnlyList<CaptureRunRecord>> ReadRunsAsync(string path)
    {
        var store = new SessionStore(path);
        await store.InitializeAsync(CancellationToken.None);
        return await store.ReadRunsAsync(CancellationToken.None);
    }

    private static CaptureEvent CreateEvent(long wireSequence, byte payload) =>
        new(
            wireSequence,
            wireSequence * 10,
            0x1234,
            42,
            CaptureKind.Read,
            0,
            0,
            1,
            1,
            CaptureFlags.None,
            ImmutableArray.Create(payload))
        {
            PortName = "COM1",
            ProcessName = "test.exe",
            Timestamp = DateTimeOffset.UnixEpoch.AddTicks(wireSequence),
        };

    private sealed class RecordingSessionStoreFactory : ISessionStoreFactory
    {
        public List<string> CreatedPaths { get; } = [];

        public ISessionStore Create(string path)
        {
            CreatedPaths.Add(path);
            throw new InvalidOperationException("No session should have been created.");
        }
    }

    private sealed class TemporarySessionDirectory : IAsyncDisposable
    {
        private readonly string _path = Path.Combine(
            Path.GetTempPath(),
            $"commmonitor-session-tests-{Guid.NewGuid():N}");

        public TemporarySessionDirectory()
        {
            Directory.CreateDirectory(_path);
        }

        public string GetPath(string fileName) => Path.Combine(_path, fileName);

        public ValueTask DisposeAsync()
        {
            Directory.Delete(_path, recursive: true);
            return ValueTask.CompletedTask;
        }
    }
}
