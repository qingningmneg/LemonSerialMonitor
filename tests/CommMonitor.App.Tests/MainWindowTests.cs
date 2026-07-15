using System.Collections.Immutable;
using System.Runtime.ExceptionServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using CommMonitor.App.Services;
using CommMonitor.App.ViewModels;
using CommMonitor.Core.Models;

namespace CommMonitor.App.Tests;

public sealed class MainWindowTests
{
    private static readonly TimeSpan StaWorkerWatchdog = TimeSpan.FromSeconds(30);
    private static readonly TimeSpan StaFinalJoinWatchdog = TimeSpan.FromSeconds(5);

    [Fact]
    public void Shell_contains_the_virtualized_Chinese_list_workflow_and_copy_gestures()
    {
        RunOnStaThread(() =>
        {
            var viewModel = new MainViewModel(
                new FakeServiceClient(),
                new FakeClipboardService(),
                new DispatcherSynchronizationContext(Dispatcher.CurrentDispatcher));
            var window = new MainWindow(viewModel);
            window.Show();

            Assert.Equal("Lemon\u4E32\u53E3\u76D1\u63A7", window.Title);
            var captureGrid = Assert.IsType<DataGrid>(window.FindName("CaptureGrid"));
            Assert.True(captureGrid.EnableRowVirtualization);
            Assert.True(VirtualizingPanel.GetIsVirtualizing(captureGrid));
            Assert.Equal(
                VirtualizationMode.Recycling,
                VirtualizingPanel.GetVirtualizationMode(captureGrid));
            Assert.Contains(
                "标志",
                captureGrid.Columns.Select(column => column.Header?.ToString()));

            CaptureEvent selectedEvent = CreateEvent(1);
            viewModel.ListViewModel.AddEvents(ImmutableArray.Create(selectedEvent));
            viewModel.TerminalViewModel.Append(selectedEvent);
            captureGrid.SelectedItem = selectedEvent;
            Assert.Same(selectedEvent, Assert.Single(viewModel.SelectedEvents));
            Assert.Same(selectedEvent, viewModel.CurrentEvent);

            var dumpGrid = Assert.IsType<DataGrid>(window.FindName("DumpGrid"));
            Assert.Equal("01", Assert.IsType<DumpRow>(Assert.Single(dumpGrid.Items)).Hex);
            var terminalSegments = Assert.IsType<ListBox>(window.FindName("TerminalSegmentsList"));
            Assert.Same(
                Assert.Single(viewModel.TerminalViewModel.Segments),
                terminalSegments.SelectedItem);
            Assert.Equal(
                ScrollBarVisibility.Disabled,
                ScrollViewer.GetHorizontalScrollBarVisibility(terminalSegments));
            viewModel.TerminalViewModel.Wrap = false;
            Assert.Equal(
                ScrollBarVisibility.Auto,
                ScrollViewer.GetHorizontalScrollBarVisibility(terminalSegments));

            KeyBinding[] bindings = window.InputBindings.OfType<KeyBinding>().ToArray();
            Assert.Contains(
                bindings,
                binding => binding.Gesture is KeyGesture
                {
                    Key: Key.C,
                    Modifiers: ModifierKeys.Control,
                });
            Assert.Contains(
                bindings,
                binding => binding.Gesture is KeyGesture
                {
                    Key: Key.C,
                    Modifiers: ModifierKeys.Control | ModifierKeys.Shift,
                });

            var tabs = Assert.IsType<TabControl>(window.FindName("ViewTabs"));
            Assert.Equal(
                ["\u5217\u8868", "Dump", "\u7EC8\u7AEF"],
                tabs.Items.Cast<TabItem>().Select(tab => tab.Header?.ToString()));
            var copyButton = Assert.IsType<Button>(window.FindName("CopyButton"));
            Assert.Equal("\u590D\u5236\u6570\u636E", copyButton.Content);
            Assert.NotNull(window.FindName("PortChecklist"));
            Assert.IsType<TextBox>(window.FindName("SessionPathBox"));
            Assert.IsType<TextBox>(window.FindName("ExportPathBox"));
            Assert.IsType<ComboBox>(window.FindName("ExportFormatSelector"));
            Assert.NotNull(window.FindName("ServiceStateText"));
            Assert.NotNull(window.FindName("DriverStateText"));
            Assert.NotNull(window.FindName("EventCountText"));
            Assert.NotNull(window.FindName("DropCountText"));
            Assert.NotNull(window.FindName("OperationStatusText"));
            Assert.IsType<ComboBox>(window.FindName("TerminalEncodingSelector"));
            Assert.IsType<CheckBox>(window.FindName("TerminalTimestampToggle"));
            Assert.IsType<CheckBox>(window.FindName("TerminalPortToggle"));
            Assert.IsType<CheckBox>(window.FindName("TerminalDirectionToggle"));
            Assert.IsType<CheckBox>(window.FindName("TerminalWrapToggle"));
            Assert.IsType<CheckBox>(window.FindName("TerminalAutoScrollToggle"));
            window.Close();
        });
    }

    [Fact]
    public void Close_observes_view_model_disposal_failures_without_dispatcher_escape()
    {
        RunOnStaThread(() =>
        {
            Dispatcher dispatcher = Dispatcher.CurrentDispatcher;
            Exception? unhandledException = null;
            dispatcher.UnhandledException += (_, eventArgs) =>
            {
                unhandledException = eventArgs.Exception;
                eventArgs.Handled = true;
            };
            var serviceClient = new FakeServiceClient
            {
                DisposeException = new InvalidOperationException("dispose failed"),
            };
            var viewModel = new MainViewModel(
                serviceClient,
                new FakeClipboardService(),
                new DispatcherSynchronizationContext(dispatcher));
            var window = new MainWindow(viewModel);
            window.Show();

            window.Close();
            var frame = new DispatcherFrame();
            dispatcher.BeginInvoke(
                DispatcherPriority.ApplicationIdle,
                new Action(() => frame.Continue = false));
            Dispatcher.PushFrame(frame);

            Assert.Equal(1, serviceClient.DisposeCallCount);
            Assert.Null(unhandledException);
        });
    }

    [Fact]
    public void Terminal_auto_scroll_toggle_controls_whether_the_newest_segment_is_revealed()
    {
        RunOnStaThread(() =>
        {
            Dispatcher dispatcher = Dispatcher.CurrentDispatcher;
            var viewModel = new MainViewModel(
                new FakeServiceClient(),
                new FakeClipboardService(),
                new DispatcherSynchronizationContext(dispatcher));
            var window = new MainWindow(viewModel);
            window.Show();
            var tabs = Assert.IsType<TabControl>(window.FindName("ViewTabs"));
            tabs.SelectedIndex = 2;
            window.UpdateLayout();
            var terminalSegments = Assert.IsType<ListBox>(
                window.FindName("TerminalSegmentsList"));

            for (int sequence = 1; sequence <= 300; sequence++)
            {
                viewModel.TerminalViewModel.Append(CreateTextEvent(sequence));
            }

            window.UpdateLayout();
            dispatcher.Invoke(DispatcherPriority.ApplicationIdle, new Action(() => { }));
            ScrollViewer scrollViewer = Assert.IsType<ScrollViewer>(
                FindVisualChild<ScrollViewer>(terminalSegments));
            Assert.True(scrollViewer.VerticalOffset > 0);

            viewModel.TerminalViewModel.Clear();
            viewModel.TerminalViewModel.AutoScroll = false;
            viewModel.TerminalViewModel.Append(CreateTextEvent(301));
            scrollViewer.ScrollToTop();
            window.UpdateLayout();
            dispatcher.Invoke(DispatcherPriority.ApplicationIdle, new Action(() => { }));
            Assert.Equal(0, scrollViewer.VerticalOffset);
            for (int sequence = 302; sequence <= 600; sequence++)
            {
                viewModel.TerminalViewModel.Append(CreateTextEvent(sequence));
            }

            window.UpdateLayout();
            dispatcher.Invoke(DispatcherPriority.ApplicationIdle, new Action(() => { }));
            Assert.Equal(0, scrollViewer.VerticalOffset);
            window.Close();
        });
    }

    [Fact]
    public void Sta_worker_rethrows_the_original_failure_after_cleanup()
    {
        var original = new InvalidOperationException("worker assertion failed");

        InvalidOperationException failure = Assert.Throws<InvalidOperationException>(() =>
            RunOnStaThread(() => throw original));

        Assert.Same(original, failure);
    }

    private static void RunOnStaThread(Action testBody)
    {
        ArgumentNullException.ThrowIfNull(testBody);
        Dispatcher? dispatcher = null;
        ExceptionDispatchInfo? workerFailure = null;
        var completion = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var thread = new Thread(() =>
        {
            Dispatcher currentDispatcher = Dispatcher.CurrentDispatcher;
            Volatile.Write(ref dispatcher, currentDispatcher);
            try
            {
                testBody();
            }
            catch (Exception exception)
            {
                workerFailure = ExceptionDispatchInfo.Capture(exception);
            }
            finally
            {
                try
                {
                    currentDispatcher.BeginInvokeShutdown(DispatcherPriority.Send);
                }
                catch (Exception exception)
                {
                    workerFailure ??= ExceptionDispatchInfo.Capture(exception);
                }
                finally
                {
                    completion.TrySetResult();
                }
            }
        })
        {
            IsBackground = true,
            Name = "MainWindowTests STA worker",
        };
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();

        bool completedWithinWatchdog = completion.Task.Wait(StaWorkerWatchdog);
        Exception? forcedShutdownFailure = null;
        if (!completedWithinWatchdog)
        {
            Dispatcher? currentDispatcher = Volatile.Read(ref dispatcher);
            if (currentDispatcher is not null)
            {
                try
                {
                    currentDispatcher.BeginInvokeShutdown(DispatcherPriority.Send);
                }
                catch (Exception exception)
                {
                    forcedShutdownFailure = exception;
                }
            }
        }

        bool joined = thread.Join(StaFinalJoinWatchdog);
        Assert.True(
            joined && !thread.IsAlive,
            "The MainWindowTests STA worker leaked after the final dispatcher-shutdown join.");

        workerFailure?.Throw();
        if (!completedWithinWatchdog)
        {
            throw new TimeoutException(
                "The MainWindowTests STA worker exceeded its named execution watchdog.",
                forcedShutdownFailure);
        }
    }

    private static CaptureEvent CreateEvent(long sequence) =>
        new(
            sequence,
            sequence * 10,
            17,
            42,
            CaptureKind.Read,
            0,
            0,
            1,
            1,
            CaptureFlags.None,
            ImmutableArray.Create((byte)sequence));

    private static CaptureEvent CreateTextEvent(long sequence) =>
        new(
            sequence,
            sequence * 10,
            17,
            42,
            CaptureKind.Read,
            0,
            0,
            1,
            1,
            CaptureFlags.None,
            ImmutableArray.Create((byte)'A'));

    private static T? FindVisualChild<T>(DependencyObject parent)
        where T : DependencyObject
    {
        for (int index = 0; index < VisualTreeHelper.GetChildrenCount(parent); index++)
        {
            DependencyObject child = VisualTreeHelper.GetChild(parent, index);
            if (child is T match)
            {
                return match;
            }

            T? descendant = FindVisualChild<T>(child);
            if (descendant is not null)
            {
                return descendant;
            }
        }

        return null;
    }

    private sealed class FakeClipboardService : IClipboardService
    {
        public void SetText(string text)
        {
        }
    }

    private sealed class FakeServiceClient : IServiceClient
    {
        public event EventHandler<ImmutableArray<CaptureEvent>>? EventsReceived;
        public event EventHandler<Exception>? ConnectionLost
        {
            add { }
            remove { }
        }

        public bool IsConnected => false;
        public Exception? DisposeException { get; init; }
        public int DisposeCallCount { get; private set; }

        public Task<ServiceStatus> GetStatusAsync(CancellationToken cancellationToken = default) =>
            Task.FromResult(
                new ServiceStatus([], CaptureState.Stopped, "development fake capture source"));

        public Task StartAsync(
            IReadOnlyCollection<ulong> deviceIds,
            string sessionPath,
            CancellationToken cancellationToken = default) => Task.CompletedTask;

        public Task PauseAsync(CancellationToken cancellationToken = default) => Task.CompletedTask;

        public Task ResumeAsync(CancellationToken cancellationToken = default) => Task.CompletedTask;

        public Task StopAsync(CancellationToken cancellationToken = default) => Task.CompletedTask;

        public Task ClearAsync(CancellationToken cancellationToken = default) => Task.CompletedTask;

        public Task ExportAsync(
            string exportPath,
            string exportFormat,
            CancellationToken cancellationToken = default) => Task.CompletedTask;

        public ValueTask DisposeAsync()
        {
            DisposeCallCount++;
            return DisposeException is null
                ? ValueTask.CompletedTask
                : ValueTask.FromException(DisposeException);
        }

        public void Publish(ImmutableArray<CaptureEvent> events) =>
            EventsReceived?.Invoke(this, events);
    }
}
