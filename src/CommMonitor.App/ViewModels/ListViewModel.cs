using System.Collections.Immutable;
using System.Collections.ObjectModel;
using System.Collections.Specialized;
using System.ComponentModel;
using CommMonitor.App.Infrastructure;
using CommMonitor.Core.Models;

namespace CommMonitor.App.ViewModels;

public sealed class ListViewModel : ObservableObject
{
    public const int MaximumLiveRows = 100_000;

    private long _eventCount;
    private long _dropCount;
    private readonly ResettableObservableCollection<CaptureEvent> _events = [];

    public ObservableCollection<CaptureEvent> Events => _events;

    public long EventCount
    {
        get => _eventCount;
        private set => SetProperty(ref _eventCount, value);
    }

    public long DropCount
    {
        get => _dropCount;
        private set => SetProperty(ref _dropCount, value);
    }

    public void AddEvents(ImmutableArray<CaptureEvent> events)
    {
        if (events.IsDefault)
        {
            throw new ArgumentException("The event batch must be initialized.", nameof(events));
        }

        EventCount = checked(EventCount + events.Length);
        DropCount = checked(
            DropCount + events.Count(captureEvent => captureEvent.Kind == CaptureKind.DropNotice));
        if (events.IsEmpty)
        {
            return;
        }

        int overflow = Math.Max(0, Events.Count + events.Length - MaximumLiveRows);
        if (overflow == 0)
        {
            foreach (CaptureEvent captureEvent in events)
            {
                Events.Add(captureEvent);
            }

            return;
        }

        var retained = new List<CaptureEvent>(MaximumLiveRows);
        if (events.Length < MaximumLiveRows)
        {
            int retainedExistingCount = MaximumLiveRows - events.Length;
            int existingStart = Math.Max(0, Events.Count - retainedExistingCount);
            for (int index = existingStart; index < Events.Count; index++)
            {
                retained.Add(Events[index]);
            }
        }

        int eventStart = Math.Max(0, events.Length - MaximumLiveRows);
        for (int index = eventStart; index < events.Length; index++)
        {
            retained.Add(events[index]);
        }

        _events.ReplaceAll(retained);
    }

    public void Clear()
    {
        Events.Clear();
        EventCount = 0;
        DropCount = 0;
    }

    public void RecordDroppedEvents(long count)
    {
        if (count < 0)
        {
            throw new ArgumentOutOfRangeException(nameof(count));
        }

        DropCount = checked(DropCount + count);
    }
}

internal sealed class ResettableObservableCollection<T> : ObservableCollection<T>
{
    public void ReplaceAll(IEnumerable<T> items)
    {
        ArgumentNullException.ThrowIfNull(items);

        Items.Clear();
        foreach (T item in items)
        {
            Items.Add(item);
        }

        OnPropertyChanged(new PropertyChangedEventArgs(nameof(Count)));
        OnPropertyChanged(new PropertyChangedEventArgs("Item[]"));
        OnCollectionChanged(
            new NotifyCollectionChangedEventArgs(NotifyCollectionChangedAction.Reset));
    }
}
