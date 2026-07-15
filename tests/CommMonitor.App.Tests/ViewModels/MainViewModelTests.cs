using System.Collections.Immutable;
using CommMonitor.App.Services;
using CommMonitor.App.ViewModels;
using CommMonitor.Core.Copying;
using CommMonitor.Core.Models;

namespace CommMonitor.App.Tests.ViewModels;

public sealed class MainViewModelTests
{
    [Fact]
    public void Public_command_surface_has_no_unimplemented_open_or_save_placeholders()
    {
        Assert.Null(typeof(MainViewModel).GetProperty("OpenCommand"));
        Assert.Null(typeof(MainViewModel).GetProperty("SaveCommand"));
    }

    [Fact]
    public void CopyCommand_copies_selected_rows_using_the_selected_format()
    {
        var clipboard = new FakeClipboardService();
        MainViewModel viewModel = CreateViewModel(new FakeServiceClient(), clipboard);
        viewModel.CopyOptions = new CopyOptions(
            CopyFormat.Json,
            IncludeSequence: true,
            IncludeTimestamp: false,
            IncludePort: true,
            IncludeDirection: false,
            IncludeProcess: false);
        viewModel.SelectedEvents.Add(CreateEvent(7, "COM7", [0x01, 0xFF]));

        viewModel.CopyCommand.Execute(parameter: null);

        Assert.Equal(
            "[{\"sequence\":7,\"port\":\"COM7\",\"data\":\"01 FF\"}]",
            clipboard.Text);
    }

    [Fact]
    public void CopyRawCommand_emits_only_spaced_HEX()
    {
        var clipboard = new FakeClipboardService();
        MainViewModel viewModel = CreateViewModel(new FakeServiceClient(), clipboard);
        viewModel.CopyOptions = new CopyOptions(
            CopyFormat.Csv,
            IncludeSequence: true,
            IncludeTimestamp: true,
            IncludePort: true,
            IncludeDirection: true,
            IncludeProcess: true);
        viewModel.SelectedEvents.Add(CreateEvent(1, "COM7", [0x01, 0x03]));
        viewModel.SelectedEvents.Add(CreateEvent(2, "COM8", [0x00, 0xFF]));

        viewModel.CopyRawCommand.Execute(parameter: null);

        Assert.Equal("01 03 00 FF", clipboard.Text);
    }

    [Fact]
    public void CopyCommand_falls_back_to_the_current_Dump_event()
    {
        var clipboard = new FakeClipboardService();
        MainViewModel viewModel = CreateViewModel(new FakeServiceClient(), clipboard);
        CaptureEvent current = CreateEvent(9, "COM9", [0xAA, 0x55]);
        viewModel.CurrentEvent = current;

        viewModel.CopyRawCommand.Execute(parameter: null);

        Assert.Equal("AA 55", clipboard.Text);
    }

    [Fact]
    public void Selecting_a_Terminal_segment_updates_the_copy_source()
    {
        var clipboard = new FakeClipboardService();
        MainViewModel viewModel = CreateViewModel(new FakeServiceClient(), clipboard);
        CaptureEvent first = CreateEvent(1, "COM7", [(byte)'A']);
        CaptureEvent second = CreateEvent(2, "COM7", [(byte)'B']);
        viewModel.TerminalViewModel.Append(first);
        viewModel.TerminalViewModel.Append(second);

        viewModel.SelectedTerminalSegment = viewModel.TerminalViewModel.Segments[1];
        viewModel.CopyRawCommand.Execute(parameter: null);

        Assert.Same(second, viewModel.CurrentEvent);
        Assert.Equal("42", clipboard.Text);
    }

    [Fact]
    public void CopyCommand_surfaces_clipboard_failures_in_the_error_property()
    {
        MainViewModel viewModel = CreateViewModel(
            new FakeServiceClient(),
            new ThrowingClipboardService());
        viewModel.SelectedEvents.Add(CreateEvent(1, "COM7", [0x01]));

        viewModel.CopyCommand.Execute(parameter: null);

        Assert.Equal("clipboard unavailable", viewModel.Error);
    }

    [Fact]
    public void StartCommand_is_disabled_without_a_selected_port()
    {
        MainViewModel viewModel = CreateViewModel();

        Assert.False(viewModel.StartCommand.CanExecute(parameter: null));
    }

    [Fact]
    public async Task Selecting_a_refreshed_port_enables_StartCommand()
    {
        var serviceClient = new FakeServiceClient
        {
            Status = new ServiceStatus(
                [new ServicePort(17, "COM7")],
                CaptureState.Stopped,
                "development fake capture source"),
        };
        MainViewModel viewModel = CreateViewModel(serviceClient);
        await viewModel.RefreshPortsCommand.ExecuteAsync();

        PortViewModel port = Assert.Single(viewModel.Ports);
        port.IsSelected = true;

        Assert.Same(port, Assert.Single(viewModel.SelectedPorts));
        Assert.True(viewModel.StartCommand.CanExecute(parameter: null));
    }

    [Fact]
    public async Task StartCommand_surfaces_service_errors_and_keeps_the_stopped_state()
    {
        var serviceClient = new FakeServiceClient
        {
            StartException = new IOException("service unavailable"),
        };
        MainViewModel viewModel = CreateViewModel(serviceClient);
        viewModel.SelectedPorts.Add(new PortViewModel(17, "COM7"));

        await viewModel.StartCommand.ExecuteAsync();

        Assert.Equal("service unavailable", viewModel.Error);
        Assert.Equal(CaptureState.Stopped, viewModel.State);
    }

    [Fact]
    public async Task StopCommand_leaves_existing_rows_intact()
    {
        var serviceClient = new FakeServiceClient();
        MainViewModel viewModel = CreateViewModel(serviceClient);
        viewModel.SelectedPorts.Add(new PortViewModel(17, "COM7"));
        await viewModel.StartCommand.ExecuteAsync();
        CaptureEvent captureEvent = CreateEvent(1, "COM7", [0x41]);
        viewModel.ListViewModel.AddEvents(ImmutableArray.Create(captureEvent));

        await viewModel.StopCommand.ExecuteAsync();

        Assert.Equal(1, serviceClient.StopCallCount);
        Assert.Same(captureEvent, Assert.Single(viewModel.ListViewModel.Events));
    }

    [Fact]
    public async Task ClearCommand_invalidates_queued_drain_and_pending_drop_state()
    {
        var context = new RecordingSynchronizationContext();
        var serviceClient = new FakeServiceClient();
        var viewModel = new MainViewModel(
            serviceClient,
            new FakeClipboardService(),
            context);
        ImmutableArray<CaptureEvent> preClearEvents = Enumerable
            .Range(1, MainViewModel.MaximumPendingEvents + 1)
            .Select(sequence => CreateEvent(sequence, "COM7", [(byte)sequence]))
            .ToImmutableArray();
        serviceClient.Publish(preClearEvents);

        await viewModel.ClearCommand.ExecuteAsync();
        CaptureEvent postClearEvent = CreateEvent(20_000, "COM7", [0x42]);
        serviceClient.Publish(ImmutableArray.Create(postClearEvent));

        Assert.Equal(2, context.PostCount);
        context.RunPostedCallback();
        Assert.Empty(viewModel.ListViewModel.Events);
        Assert.Equal(0, viewModel.ListViewModel.DropCount);
        context.RunPostedCallback();
        Assert.Same(postClearEvent, Assert.Single(viewModel.ListViewModel.Events));
        Assert.Equal(0, viewModel.ListViewModel.DropCount);
    }

    [Fact]
    public async Task ClearCommand_clears_Dump_Terminal_and_shared_selection()
    {
        var serviceClient = new FakeServiceClient();
        MainViewModel viewModel = CreateViewModel(serviceClient);
        CaptureEvent captureEvent = CreateEvent(1, "COM7", [0x41]);
        serviceClient.Publish(ImmutableArray.Create(captureEvent));
        viewModel.CurrentEvent = captureEvent;

        await viewModel.ClearCommand.ExecuteAsync();

        Assert.Null(viewModel.CurrentEvent);
        Assert.Empty(viewModel.DumpViewModel.Rows);
        Assert.Empty(viewModel.TerminalViewModel.Segments);
        Assert.Null(viewModel.TerminalViewModel.SelectedSegment);
    }

    [Fact]
    public async Task ClearCommand_does_nothing_when_destructive_confirmation_is_rejected()
    {
        var serviceClient = new FakeServiceClient();
        var viewModel = new MainViewModel(
            serviceClient,
            new FakeClipboardService(),
            new InlineSynchronizationContext(),
            new FixedConfirmationService(result: false));
        CaptureEvent retained = CreateEvent(1, "COM7", [0x42]);
        viewModel.ListViewModel.AddEvents(ImmutableArray.Create(retained));
        viewModel.CurrentEvent = retained;

        await viewModel.ClearCommand.ExecuteAsync();

        Assert.Equal(0, serviceClient.ClearCallCount);
        Assert.Same(retained, Assert.Single(viewModel.ListViewModel.Events));
        Assert.Same(retained, viewModel.CurrentEvent);
    }

    [Fact]
    public void Published_events_are_marshaled_through_the_captured_UI_context()
    {
        var context = new RecordingSynchronizationContext();
        var serviceClient = new FakeServiceClient();
        var viewModel = new MainViewModel(
            serviceClient,
            new FakeClipboardService(),
            context);
        CaptureEvent captureEvent = CreateEvent(1, "COM7", [0x41]);

        serviceClient.Publish(ImmutableArray.Create(captureEvent));

        Assert.Empty(viewModel.ListViewModel.Events);
        Assert.Empty(viewModel.TerminalViewModel.Segments);
        context.RunPostedCallback();
        Assert.Same(captureEvent, Assert.Single(viewModel.ListViewModel.Events));
        Assert.Same(
            captureEvent,
            Assert.Single(viewModel.TerminalViewModel.Segments).CaptureEvent);
    }

    [Fact]
    public void CurrentEvent_updates_Dump_and_highlights_the_terminal_segment()
    {
        var serviceClient = new FakeServiceClient();
        MainViewModel viewModel = CreateViewModel(serviceClient);
        CaptureEvent captureEvent = CreateEvent(1, "COM7", [0x41]);
        serviceClient.Publish(ImmutableArray.Create(captureEvent));

        viewModel.CurrentEvent = captureEvent;

        Assert.Equal("41", Assert.Single(viewModel.DumpViewModel.Rows).Hex);
        TerminalSegment segment = Assert.Single(viewModel.TerminalViewModel.Segments);
        Assert.Same(segment, viewModel.TerminalViewModel.SelectedSegment);
        Assert.True(segment.IsSelected);
    }

    [Fact]
    public void Published_batches_are_coalesced_into_one_scheduled_UI_drain()
    {
        var context = new RecordingSynchronizationContext();
        var serviceClient = new FakeServiceClient();
        var viewModel = new MainViewModel(
            serviceClient,
            new FakeClipboardService(),
            context);

        serviceClient.Publish(ImmutableArray.Create(CreateEvent(1, "COM7", [0x01])));
        serviceClient.Publish(ImmutableArray.Create(CreateEvent(2, "COM7", [0x02])));
        serviceClient.Publish(ImmutableArray.Create(CreateEvent(3, "COM7", [0x03])));

        Assert.Equal(1, context.PostCount);
        Assert.Empty(viewModel.ListViewModel.Events);
        context.RunPostedCallback();
        Assert.Equal(new long[] { 1, 2, 3 }, viewModel.ListViewModel.Events.Select(e => e.Sequence));
    }

    [Fact]
    public void Pending_event_overflow_keeps_the_newest_ten_thousand_and_counts_drops()
    {
        const int pendingCapacity = 10_000;
        const int overflow = 137;
        var context = new RecordingSynchronizationContext();
        var serviceClient = new FakeServiceClient();
        var viewModel = new MainViewModel(
            serviceClient,
            new FakeClipboardService(),
            context);
        CaptureEvent[] events = Enumerable
            .Range(1, pendingCapacity + overflow)
            .Select(sequence => CreateEvent(sequence, "COM7", [(byte)sequence]))
            .ToArray();

        foreach (CaptureEvent[] batch in events.Chunk(64))
        {
            serviceClient.Publish(ImmutableArray.CreateRange(batch));
        }

        Assert.Equal(1, context.PostCount);
        context.RunPostedCallback();
        Assert.Equal(pendingCapacity, viewModel.ListViewModel.Events.Count);
        Assert.Equal(overflow + 1, viewModel.ListViewModel.Events[0].Sequence);
        Assert.Equal(pendingCapacity + overflow, viewModel.ListViewModel.Events[^1].Sequence);
        Assert.Equal(overflow, viewModel.ListViewModel.DropCount);
    }

    [Fact]
    public void Constructor_rejects_a_null_UI_context()
    {
        Assert.Throws<ArgumentNullException>(
            () => new MainViewModel(
                new FakeServiceClient(),
                new FakeClipboardService(),
                uiContext: null!));
    }

    [Fact]
    public void Connection_loss_is_exposed_in_the_view_model_state()
    {
        var context = new RecordingSynchronizationContext();
        var serviceClient = new FakeServiceClient();
        var viewModel = new MainViewModel(serviceClient, new FakeClipboardService(), context);

        serviceClient.PublishConnectionLost(new IOException("subscription disconnected"));

        Assert.Null(viewModel.Error);
        context.RunPostedCallback();
        Assert.Equal("subscription disconnected", viewModel.Error);
        Assert.Equal("\u5DF2\u65AD\u5F00", viewModel.ServiceState);
    }

    [Fact]
    public async Task Connection_callback_queued_before_disposal_is_ignored()
    {
        var context = new RecordingSynchronizationContext();
        var serviceClient = new FakeServiceClient();
        var viewModel = new MainViewModel(
            serviceClient,
            new FakeClipboardService(),
            context);
        serviceClient.PublishConnectionLost(new IOException("subscription disconnected"));

        await viewModel.DisposeAsync();
        context.RunPostedCallback();

        Assert.Null(viewModel.Error);
        Assert.Equal("\u672A\u8FDE\u63A5", viewModel.ServiceState);
    }

    [Fact]
    public void NextSearchCommand_selects_the_next_matching_HEX_row()
    {
        MainViewModel viewModel = CreateViewModel();
        CaptureEvent first = CreateEvent(1, "COM7", [0x01]);
        CaptureEvent match = CreateEvent(2, "COM7", [0x03, 0xFF]);
        viewModel.ListViewModel.AddEvents(ImmutableArray.Create(first, match));
        viewModel.SearchType = SearchType.Hex;
        viewModel.SearchText = "03 FF";

        viewModel.NextSearchCommand.Execute(parameter: null);

        Assert.Same(match, viewModel.CurrentEvent);
        Assert.Null(viewModel.Error);
    }

    [Fact]
    public async Task ExportCommand_forwards_the_selected_path_and_format()
    {
        var serviceClient = new FakeServiceClient();
        MainViewModel viewModel = CreateViewModel(serviceClient);
        viewModel.ExportPath = "capture.csv";
        viewModel.ExportFormat = "csv";

        await viewModel.ExportCommand.ExecuteAsync();

        Assert.Equal("capture.csv", serviceClient.LastExportPath);
        Assert.Equal("csv", serviceClient.LastExportFormat);
        Assert.EndsWith(
            Path.Combine("CommMonitor", "Exports", "capture.csv"),
            viewModel.OperationStatus!,
            StringComparison.OrdinalIgnoreCase);
    }

    [Theory]
    [InlineData("txt", "capture.txt")]
    [InlineData("raw", "capture.raw")]
    public void Selecting_an_export_format_keeps_the_file_extension_consistent(
        string format,
        string expectedPath)
    {
        MainViewModel viewModel = CreateViewModel();

        viewModel.ExportFormat = format;

        Assert.Equal(expectedPath, viewModel.ExportPath);
    }

    private static MainViewModel CreateViewModel(
        IServiceClient? serviceClient = null,
        IClipboardService? clipboardService = null) =>
        new(
            serviceClient ?? new FakeServiceClient(),
            clipboardService ?? new FakeClipboardService(),
            new InlineSynchronizationContext());

    private static CaptureEvent CreateEvent(long sequence, string portName, byte[] payload) =>
        new(
            sequence,
            sequence * 10,
            17,
            42,
            CaptureKind.Write,
            0,
            0,
            payload.Length,
            payload.Length,
            CaptureFlags.None,
            ImmutableArray.CreateRange(payload))
        {
            PortName = portName,
            ProcessName = "terminal.exe",
            Timestamp = DateTimeOffset.UnixEpoch.AddTicks(sequence),
        };

    private sealed class FakeClipboardService : IClipboardService
    {
        public string? Text { get; private set; }

        public void SetText(string text) => Text = text;
    }

    private sealed class ThrowingClipboardService : IClipboardService
    {
        public void SetText(string text) => throw new InvalidOperationException("clipboard unavailable");
    }

    private sealed class FixedConfirmationService(bool result) : IConfirmationService
    {
        public bool ConfirmClearSession() => result;
    }

    private sealed class FakeServiceClient : IServiceClient
    {
        public event EventHandler<ImmutableArray<CaptureEvent>>? EventsReceived;
        public event EventHandler<Exception>? ConnectionLost;

        public bool IsConnected => true;
        public int StopCallCount { get; private set; }
        public int ClearCallCount { get; private set; }
        public string? LastExportPath { get; private set; }
        public string? LastExportFormat { get; private set; }
        public Exception? StartException { get; init; }
        public ServiceStatus Status { get; init; } =
            new([], CaptureState.Stopped, "development fake capture source");

        public Task<ServiceStatus> GetStatusAsync(CancellationToken cancellationToken = default) =>
            Task.FromResult(Status);

        public Task StartAsync(
            IReadOnlyCollection<ulong> deviceIds,
            string sessionPath,
            CancellationToken cancellationToken = default) => StartException is null
                ? Task.CompletedTask
                : Task.FromException(StartException);

        public Task PauseAsync(CancellationToken cancellationToken = default) => Task.CompletedTask;

        public Task ResumeAsync(CancellationToken cancellationToken = default) => Task.CompletedTask;

        public Task StopAsync(CancellationToken cancellationToken = default)
        {
            StopCallCount++;
            return Task.CompletedTask;
        }

        public Task ClearAsync(CancellationToken cancellationToken = default)
        {
            ClearCallCount++;
            return Task.CompletedTask;
        }

        public Task ExportAsync(
            string exportPath,
            string exportFormat,
            CancellationToken cancellationToken = default)
        {
            LastExportPath = exportPath;
            LastExportFormat = exportFormat;
            return Task.CompletedTask;
        }

        public ValueTask DisposeAsync() => ValueTask.CompletedTask;

        public void Publish(ImmutableArray<CaptureEvent> events) =>
            EventsReceived?.Invoke(this, events);

        public void PublishConnectionLost(Exception exception) =>
            ConnectionLost?.Invoke(this, exception);
    }

    private sealed class RecordingSynchronizationContext : SynchronizationContext
    {
        private readonly Queue<(SendOrPostCallback Callback, object? State)> _callbacks = [];

        public int PostCount { get; private set; }

        public override void Post(SendOrPostCallback callback, object? state)
        {
            PostCount++;
            _callbacks.Enqueue((callback, state));
        }

        public void RunPostedCallback()
        {
            Assert.NotEmpty(_callbacks);
            (SendOrPostCallback callback, object? state) = _callbacks.Dequeue();
            callback(state);
        }
    }

    private sealed class InlineSynchronizationContext : SynchronizationContext
    {
        public override void Post(SendOrPostCallback callback, object? state) => callback(state);
    }
}
