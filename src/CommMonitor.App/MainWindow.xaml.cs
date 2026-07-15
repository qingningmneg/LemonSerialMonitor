using System.Collections.Specialized;
using System.Windows;
using System.Windows.Threading;
using CommMonitor.App.Services;
using CommMonitor.App.ViewModels;

namespace CommMonitor.App;

public partial class MainWindow : Window
{
    private readonly MainViewModel _viewModel;
    private bool _terminalScrollScheduled;

    public MainWindow()
        : this(
            new MainViewModel(
                new ServiceClient(),
                new WpfClipboardService(),
                new DispatcherSynchronizationContext(Dispatcher.CurrentDispatcher),
                new WpfConfirmationService()))
    {
    }

    internal MainWindow(MainViewModel viewModel)
    {
        InitializeComponent();
        _viewModel = viewModel ?? throw new ArgumentNullException(nameof(viewModel));
        DataContext = _viewModel;
        _viewModel.TerminalViewModel.Segments.CollectionChanged +=
            TerminalSegmentsOnCollectionChanged;
        Closed += MainWindowOnClosed;
    }

    private void TerminalSegmentsOnCollectionChanged(
        object? sender,
        NotifyCollectionChangedEventArgs eventArgs)
    {
        if (!_viewModel.TerminalViewModel.AutoScroll || TerminalSegmentsList.Items.Count == 0)
        {
            return;
        }

        if (_terminalScrollScheduled)
        {
            return;
        }

        _terminalScrollScheduled = true;
        Dispatcher.BeginInvoke(
            DispatcherPriority.DataBind,
            new Action(ScrollTerminalToNewest));
    }

    private void ScrollTerminalToNewest()
    {
        _terminalScrollScheduled = false;
        if (_viewModel.TerminalViewModel.AutoScroll && TerminalSegmentsList.Items.Count > 0)
        {
            TerminalSegmentsList.ScrollIntoView(TerminalSegmentsList.Items[^1]);
        }
    }

    private void MainWindowOnClosed(object? sender, EventArgs eventArgs)
    {
        _viewModel.TerminalViewModel.Segments.CollectionChanged -=
            TerminalSegmentsOnCollectionChanged;
        _ = DisposeViewModelSafelyAsync(_viewModel);
    }

    private static async Task DisposeViewModelSafelyAsync(MainViewModel viewModel)
    {
        try
        {
            await viewModel.DisposeAsync();
        }
        catch (Exception)
        {
            // Window shutdown must not surface transport cleanup failures as async-void faults.
        }
    }
}
