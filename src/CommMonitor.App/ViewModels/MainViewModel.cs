using System.Collections;
using System.Collections.Immutable;
using System.Collections.ObjectModel;
using System.Collections.Specialized;
using System.ComponentModel;
using System.IO;
using System.Text;
using CommMonitor.App.Infrastructure;
using CommMonitor.App.Services;
using CommMonitor.Core.Copying;
using CommMonitor.Core.Models;
using CommMonitor.Core.Search;

namespace CommMonitor.App.ViewModels;

public enum SearchType
{
    Hex,
    Text,
}

public sealed class PortViewModel : ObservableObject
{
    private bool _isSelected;

    public PortViewModel(ulong deviceId, string name)
    {
        DeviceId = deviceId;
        Name = name ?? throw new ArgumentNullException(nameof(name));
    }

    public ulong DeviceId { get; }
    public string Name { get; }

    public bool IsSelected
    {
        get => _isSelected;
        set => SetProperty(ref _isSelected, value);
    }
}

public sealed class MainViewModel : ObservableObject, IAsyncDisposable
{
    public const int MaximumPendingEvents = 10_000;

    private readonly IServiceClient _serviceClient;
    private readonly IClipboardService _clipboardService;
    private readonly IConfirmationService _confirmationService;
    private readonly HashSet<PortViewModel> _trackedPorts = [];
    private readonly SynchronizationContext _uiContext;
    private readonly object _ingressLock = new();
    private readonly Queue<CaptureEvent> _pendingEvents = new(MaximumPendingEvents);
    private CopyOptions _copyOptions = new(
        CopyFormat.HexSpaced,
        IncludeSequence: true,
        IncludeTimestamp: true,
        IncludePort: true,
        IncludeDirection: true,
        IncludeProcess: true);
    private CaptureState _state = CaptureState.Stopped;
    private string? _error;
    private string? _operationStatus;
    private string _serviceState = "\u672A\u8FDE\u63A5";
    private string _driverState = "\u672A\u77E5";
    private string _sessionPath = "capture.db";
    private string _searchText = string.Empty;
    private SearchType _searchType;
    private CaptureEvent? _currentEvent;
    private string _exportPath = "capture.csv";
    private string _exportFormat = "csv";
    private long _pendingDroppedCount;
    private long _ingressGeneration;
    private bool _drainScheduled;
    private bool _disposed;

    public MainViewModel(IServiceClient serviceClient, IClipboardService clipboardService)
        : this(
            serviceClient,
            clipboardService,
            SynchronizationContext.Current ?? throw new InvalidOperationException(
                "A UI synchronization context is required."),
            new WpfConfirmationService())
    {
    }

    internal MainViewModel(
        IServiceClient serviceClient,
        IClipboardService clipboardService,
        SynchronizationContext uiContext)
        : this(
            serviceClient,
            clipboardService,
            uiContext,
            AlwaysConfirmService.Instance)
    {
    }

    internal MainViewModel(
        IServiceClient serviceClient,
        IClipboardService clipboardService,
        SynchronizationContext uiContext,
        IConfirmationService confirmationService)
    {
        _serviceClient = serviceClient ?? throw new ArgumentNullException(nameof(serviceClient));
        _clipboardService = clipboardService ?? throw new ArgumentNullException(nameof(clipboardService));
        _uiContext = uiContext ?? throw new ArgumentNullException(nameof(uiContext));
        _confirmationService = confirmationService ??
            throw new ArgumentNullException(nameof(confirmationService));

        CopyCommand = new RelayCommand(CopySelected, CanCopySelected);
        CopyRawCommand = new RelayCommand(CopySelectedRaw, CanCopySelected);
        RefreshPortsCommand = new AsyncRelayCommand(RefreshPortsAsync, onException: SetError);
        StartCommand = new AsyncRelayCommand(
            StartAsync,
            () => State == CaptureState.Stopped && SelectedPorts.Count > 0,
            SetError);
        PauseCommand = new AsyncRelayCommand(
            PauseAsync,
            () => State == CaptureState.Running,
            SetError);
        ResumeCommand = new AsyncRelayCommand(
            ResumeAsync,
            () => State == CaptureState.Paused,
            SetError);
        StopCommand = new AsyncRelayCommand(
            StopAsync,
            () => State != CaptureState.Stopped,
            SetError);
        ClearCommand = new AsyncRelayCommand(
            ClearAsync,
            () => State == CaptureState.Stopped,
            SetError);
        ExportCommand = new AsyncRelayCommand(
            ExportAsync,
            () => State == CaptureState.Stopped &&
                !string.IsNullOrWhiteSpace(ExportPath) &&
                !string.IsNullOrWhiteSpace(ExportFormat),
            SetError);
        PreviousSearchCommand = new RelayCommand(
            () => FindMatch(-1),
            CanSearch);
        NextSearchCommand = new RelayCommand(
            () => FindMatch(1),
            CanSearch);

        SelectedEvents.CollectionChanged += SelectedEventsOnCollectionChanged;
        SelectedPorts.CollectionChanged += SelectedPortsOnCollectionChanged;
        Ports.CollectionChanged += PortsOnCollectionChanged;
        ListViewModel.Events.CollectionChanged += EventsOnCollectionChanged;
        _serviceClient.EventsReceived += ServiceClientOnEventsReceived;
        _serviceClient.ConnectionLost += ServiceClientOnConnectionLost;
    }

    public ListViewModel ListViewModel { get; } = new();
    public DumpViewModel DumpViewModel { get; } = new();
    public TerminalViewModel TerminalViewModel { get; } = new();
    public ObservableCollection<PortViewModel> Ports { get; } = [];
    public ObservableCollection<PortViewModel> SelectedPorts { get; } = [];
    public ObservableCollection<CaptureEvent> SelectedEvents { get; } = [];

    public RelayCommand CopyCommand { get; }
    public RelayCommand CopyRawCommand { get; }
    public AsyncRelayCommand RefreshPortsCommand { get; }
    public AsyncRelayCommand StartCommand { get; }
    public AsyncRelayCommand PauseCommand { get; }
    public AsyncRelayCommand ResumeCommand { get; }
    public AsyncRelayCommand StopCommand { get; }
    public AsyncRelayCommand ClearCommand { get; }
    public AsyncRelayCommand ExportCommand { get; }
    public RelayCommand PreviousSearchCommand { get; }
    public RelayCommand NextSearchCommand { get; }

    public IReadOnlyList<CopyFormat> CopyFormats { get; } = Enum.GetValues<CopyFormat>();

    public CopyOptions CopyOptions
    {
        get => _copyOptions;
        set
        {
            if (SetProperty(ref _copyOptions, value ?? throw new ArgumentNullException(nameof(value))))
            {
                OnPropertyChanged(nameof(SelectedCopyFormat));
            }
        }
    }

    public CopyFormat SelectedCopyFormat
    {
        get => CopyOptions.Format;
        set
        {
            if (value != CopyOptions.Format)
            {
                CopyOptions = CopyOptions with { Format = value };
            }
        }
    }

    public CaptureState State
    {
        get => _state;
        private set
        {
            if (SetProperty(ref _state, value))
            {
                RaiseCaptureCanExecuteChanged();
            }
        }
    }

    public string? Error
    {
        get => _error;
        private set => SetProperty(ref _error, value);
    }

    public string? OperationStatus
    {
        get => _operationStatus;
        private set => SetProperty(ref _operationStatus, value);
    }

    public string ServiceState
    {
        get => _serviceState;
        private set => SetProperty(ref _serviceState, value);
    }

    public string DriverState
    {
        get => _driverState;
        private set => SetProperty(ref _driverState, value);
    }

    public string SessionPath
    {
        get => _sessionPath;
        set => SetProperty(
            ref _sessionPath,
            string.IsNullOrWhiteSpace(value) ? "capture.db" : value);
    }

    public string SearchText
    {
        get => _searchText;
        set
        {
            if (SetProperty(ref _searchText, value ?? string.Empty))
            {
                RaiseSearchCanExecuteChanged();
            }
        }
    }

    public SearchType SearchType
    {
        get => _searchType;
        set => SetProperty(ref _searchType, value);
    }

    public CaptureEvent? CurrentEvent
    {
        get => _currentEvent;
        set
        {
            if (SetProperty(ref _currentEvent, value))
            {
                DumpViewModel.SelectEvent(value);
                TerminalViewModel.SelectEvent(value);
                OnPropertyChanged(nameof(SelectedTerminalSegment));
                CopyCommand.RaiseCanExecuteChanged();
                CopyRawCommand.RaiseCanExecuteChanged();
            }
        }
    }

    public TerminalSegment? SelectedTerminalSegment
    {
        get => TerminalViewModel.SelectedSegment;
        set
        {
            if (ReferenceEquals(value, TerminalViewModel.SelectedSegment))
            {
                return;
            }

            TerminalViewModel.SelectedSegment = value;
            if (value is not null)
            {
                SelectedEvents.Clear();
                CurrentEvent = value.CaptureEvent;
            }
            else
            {
                OnPropertyChanged();
            }
        }
    }

    public string ExportPath
    {
        get => _exportPath;
        set
        {
            if (SetProperty(ref _exportPath, value ?? string.Empty))
            {
                ExportCommand.RaiseCanExecuteChanged();
            }
        }
    }

    public string ExportFormat
    {
        get => _exportFormat;
        set
        {
            if (SetProperty(ref _exportFormat, value ?? string.Empty))
            {
                string? extension = _exportFormat.ToLowerInvariant() switch
                {
                    "csv" => ".csv",
                    "txt" => ".txt",
                    "raw" => ".raw",
                    _ => null,
                };
                if (extension is not null &&
                    !string.IsNullOrWhiteSpace(ExportPath) &&
                    string.Equals(
                        ExportPath,
                        Path.GetFileName(ExportPath),
                        StringComparison.Ordinal))
                {
                    ExportPath = Path.ChangeExtension(ExportPath, extension);
                }

                ExportCommand.RaiseCanExecuteChanged();
            }
        }
    }

    public async ValueTask DisposeAsync()
    {
        lock (_ingressLock)
        {
            if (_disposed)
            {
                return;
            }

            _disposed = true;
            _pendingEvents.Clear();
            _pendingDroppedCount = 0;
            _drainScheduled = false;
        }

        _serviceClient.EventsReceived -= ServiceClientOnEventsReceived;
        _serviceClient.ConnectionLost -= ServiceClientOnConnectionLost;
        ListViewModel.Events.CollectionChanged -= EventsOnCollectionChanged;
        foreach (PortViewModel port in _trackedPorts)
        {
            port.PropertyChanged -= PortOnPropertyChanged;
        }

        _trackedPorts.Clear();
        await _serviceClient.DisposeAsync();
    }

    private void CopySelected(object? parameter) => Copy(parameter, CopyOptions);

    private void CopySelectedRaw(object? parameter) =>
        Copy(
            parameter,
            new CopyOptions(
                CopyFormat.HexSpaced,
                IncludeSequence: false,
                IncludeTimestamp: false,
                IncludePort: false,
                IncludeDirection: false,
                IncludeProcess: false));

    private void Copy(object? parameter, CopyOptions options)
    {
        Error = null;
        try
        {
            ImmutableArray<CaptureEvent> selectedEvents = GetSelectedEvents(parameter);
            string text = CopyFormatter.Format(selectedEvents, options, Encoding.UTF8);
            _clipboardService.SetText(text);
        }
        catch (Exception exception)
        {
            SetError(exception);
        }
    }

    private bool CanCopySelected(object? parameter) => GetSelectedEvents(parameter).Length > 0;

    private ImmutableArray<CaptureEvent> GetSelectedEvents(object? parameter)
    {
        if (parameter is IEnumerable<CaptureEvent> typedEvents)
        {
            return typedEvents.ToImmutableArray();
        }

        if (parameter is IEnumerable items)
        {
            return items.Cast<object?>().OfType<CaptureEvent>().ToImmutableArray();
        }

        ImmutableArray<CaptureEvent> selectedEvents = SelectedEvents.ToImmutableArray();
        if (!selectedEvents.IsEmpty)
        {
            return selectedEvents;
        }

        return CurrentEvent is null
            ? []
            : ImmutableArray.Create(CurrentEvent);
    }

    private async Task RefreshPortsAsync()
    {
        Error = null;
        ServiceStatus status = await _serviceClient.GetStatusAsync();
        Ports.Clear();
        SelectedPorts.Clear();
        foreach (ServicePort port in status.Ports)
        {
            Ports.Add(new PortViewModel(port.DeviceId, port.Name));
        }

        State = status.State;
        DriverState = status.DriverState;
        ServiceState = _serviceClient.IsConnected ? "\u5DF2\u8FDE\u63A5" : "\u672A\u8FDE\u63A5";
    }

    private async Task StartAsync()
    {
        Error = null;
        ulong[] deviceIds = SelectedPorts.Select(port => port.DeviceId).Distinct().ToArray();
        await _serviceClient.StartAsync(deviceIds, SessionPath);
        State = CaptureState.Running;
        ServiceState = "\u5DF2\u8FDE\u63A5";
    }

    private async Task PauseAsync()
    {
        Error = null;
        await _serviceClient.PauseAsync();
        State = CaptureState.Paused;
    }

    private async Task ResumeAsync()
    {
        Error = null;
        await _serviceClient.ResumeAsync();
        State = CaptureState.Running;
    }

    private async Task StopAsync()
    {
        Error = null;
        await _serviceClient.StopAsync();
        State = CaptureState.Stopped;
    }

    private async Task ClearAsync()
    {
        Error = null;
        if (!_confirmationService.ConfirmClearSession())
        {
            return;
        }

        await _serviceClient.ClearAsync();
        InvalidatePendingEvents();
        ListViewModel.Clear();
        SelectedEvents.Clear();
        CurrentEvent = null;
        DumpViewModel.SelectEvent(null);
        TerminalViewModel.Clear();
    }

    private async Task ExportAsync()
    {
        Error = null;
        await _serviceClient.ExportAsync(ExportPath, ExportFormat);
        OperationStatus = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
            "CommMonitor",
            "Exports",
            ExportPath);
    }

    private void ServiceClientOnEventsReceived(
        object? sender,
        ImmutableArray<CaptureEvent> events)
    {
        bool scheduleDrain = false;
        long drainGeneration = 0;
        lock (_ingressLock)
        {
            if (_disposed)
            {
                return;
            }

            foreach (CaptureEvent captureEvent in events)
            {
                if (_pendingEvents.Count == MaximumPendingEvents)
                {
                    _pendingEvents.Dequeue();
                    _pendingDroppedCount = checked(_pendingDroppedCount + 1);
                }

                _pendingEvents.Enqueue(captureEvent);
            }

            if (!_drainScheduled)
            {
                _drainScheduled = true;
                scheduleDrain = true;
                drainGeneration = _ingressGeneration;
            }
        }

        if (scheduleDrain)
        {
            try
            {
                _uiContext.Post(
                    static state =>
                    {
                        var request = (DrainRequest)state!;
                        request.ViewModel.DrainPendingEvents(request.Generation);
                    },
                    new DrainRequest(this, drainGeneration));
            }
            catch
            {
                lock (_ingressLock)
                {
                    if (_ingressGeneration == drainGeneration)
                    {
                        _drainScheduled = false;
                    }
                }

                throw;
            }
        }
    }

    private void ServiceClientOnConnectionLost(object? sender, Exception exception)
    {
        lock (_ingressLock)
        {
            if (_disposed)
            {
                return;
            }
        }

        _uiContext.Post(
            static state =>
            {
                var update = (ConnectionUpdate)state!;
                update.ViewModel.SetConnectionLost(update.Exception);
            },
            new ConnectionUpdate(this, exception));
    }

    private void DrainPendingEvents(long generation)
    {
        ImmutableArray<CaptureEvent> events;
        long droppedCount;
        lock (_ingressLock)
        {
            if (_disposed || generation != _ingressGeneration)
            {
                return;
            }

            events = ImmutableArray.CreateRange(_pendingEvents);
            _pendingEvents.Clear();
            droppedCount = _pendingDroppedCount;
            _pendingDroppedCount = 0;
            _drainScheduled = false;
        }

        if (droppedCount > 0)
        {
            ListViewModel.RecordDroppedEvents(droppedCount);
        }

        if (!events.IsEmpty)
        {
            foreach (CaptureEvent captureEvent in events)
            {
                TerminalViewModel.Append(captureEvent);
            }

            ListViewModel.AddEvents(events);
        }
    }

    private void InvalidatePendingEvents()
    {
        lock (_ingressLock)
        {
            _pendingEvents.Clear();
            _pendingDroppedCount = 0;
            _drainScheduled = false;
            _ingressGeneration = checked(_ingressGeneration + 1);
        }
    }

    private void SetConnectionLost(Exception exception)
    {
        lock (_ingressLock)
        {
            if (_disposed)
            {
                return;
            }

            ServiceState = "\u5DF2\u65AD\u5F00";
            Error = exception.Message;
        }
    }

    private void SelectedEventsOnCollectionChanged(
        object? sender,
        NotifyCollectionChangedEventArgs eventArgs)
    {
        CopyCommand.RaiseCanExecuteChanged();
        CopyRawCommand.RaiseCanExecuteChanged();
    }

    private void SelectedPortsOnCollectionChanged(
        object? sender,
        NotifyCollectionChangedEventArgs eventArgs) => StartCommand.RaiseCanExecuteChanged();

    private void EventsOnCollectionChanged(
        object? sender,
        NotifyCollectionChangedEventArgs eventArgs) => RaiseSearchCanExecuteChanged();

    private void PortsOnCollectionChanged(
        object? sender,
        NotifyCollectionChangedEventArgs eventArgs)
    {
        foreach (PortViewModel removed in _trackedPorts.Where(port => !Ports.Contains(port)).ToArray())
        {
            removed.PropertyChanged -= PortOnPropertyChanged;
            _trackedPorts.Remove(removed);
            SelectedPorts.Remove(removed);
        }

        foreach (PortViewModel added in Ports.Where(port => _trackedPorts.Add(port)))
        {
            added.PropertyChanged += PortOnPropertyChanged;
            UpdateSelectedPort(added);
        }
    }

    private void PortOnPropertyChanged(object? sender, PropertyChangedEventArgs eventArgs)
    {
        if (eventArgs.PropertyName == nameof(PortViewModel.IsSelected) &&
            sender is PortViewModel port)
        {
            UpdateSelectedPort(port);
        }
    }

    private void UpdateSelectedPort(PortViewModel port)
    {
        if (port.IsSelected)
        {
            if (!SelectedPorts.Contains(port))
            {
                SelectedPorts.Add(port);
            }
        }
        else
        {
            SelectedPorts.Remove(port);
        }
    }

    private void SetError(Exception exception)
    {
        OperationStatus = null;
        Error = exception.Message;
    }

    private bool CanSearch() =>
        !string.IsNullOrWhiteSpace(SearchText) && ListViewModel.Events.Count > 0;

    private void FindMatch(int step)
    {
        int count = ListViewModel.Events.Count;
        int currentIndex = CurrentEvent is null
            ? (step > 0 ? -1 : 0)
            : ListViewModel.Events.IndexOf(CurrentEvent);
        for (int offset = 1; offset <= count; offset++)
        {
            int index = (currentIndex + (step * offset)) % count;
            if (index < 0)
            {
                index += count;
            }

            CaptureEvent candidate = ListViewModel.Events[index];
            if (IsSearchMatch(candidate, out string? validationError))
            {
                CurrentEvent = candidate;
                Error = null;
                return;
            }

            if (validationError is not null)
            {
                Error = validationError;
                return;
            }
        }

        Error = "\u672A\u627E\u5230\u5339\u914D\u9879\u3002";
    }

    private bool IsSearchMatch(CaptureEvent captureEvent, out string? validationError)
    {
        if (SearchType == SearchType.Hex)
        {
            return CaptureSearchMatcher.IsMatch(captureEvent, SearchText, out validationError);
        }

        validationError = null;
        return Encoding.UTF8
            .GetString(captureEvent.Payload.AsSpan())
            .Contains(SearchText, StringComparison.OrdinalIgnoreCase);
    }

    private void RaiseSearchCanExecuteChanged()
    {
        PreviousSearchCommand.RaiseCanExecuteChanged();
        NextSearchCommand.RaiseCanExecuteChanged();
    }

    private void RaiseCaptureCanExecuteChanged()
    {
        StartCommand.RaiseCanExecuteChanged();
        PauseCommand.RaiseCanExecuteChanged();
        ResumeCommand.RaiseCanExecuteChanged();
        StopCommand.RaiseCanExecuteChanged();
        ClearCommand.RaiseCanExecuteChanged();
        ExportCommand.RaiseCanExecuteChanged();
    }

    private sealed record ConnectionUpdate(
        MainViewModel ViewModel,
        Exception Exception);

    private sealed record DrainRequest(MainViewModel ViewModel, long Generation);
}
