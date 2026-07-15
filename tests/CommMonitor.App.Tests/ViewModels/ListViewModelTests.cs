using System.Collections.Immutable;
using System.Collections.Specialized;
using CommMonitor.App.ViewModels;
using CommMonitor.Core.Models;

namespace CommMonitor.App.Tests.ViewModels;

public sealed class ListViewModelTests
{
    [Fact]
    public void AddEvents_retains_only_the_newest_one_hundred_thousand_live_rows()
    {
        var viewModel = new ListViewModel();
        ImmutableArray<CaptureEvent> events = Enumerable
            .Range(1, ListViewModel.MaximumLiveRows + 5)
            .Select(sequence => CreateEvent(sequence, CaptureKind.Read))
            .ToImmutableArray();
        var notifications = new List<NotifyCollectionChangedEventArgs>();
        viewModel.Events.CollectionChanged += (_, eventArgs) => notifications.Add(eventArgs);

        viewModel.AddEvents(events);

        NotifyCollectionChangedEventArgs notification = Assert.Single(notifications);
        Assert.Equal(NotifyCollectionChangedAction.Reset, notification.Action);
        Assert.Equal(ListViewModel.MaximumLiveRows, viewModel.Events.Count);
        Assert.Equal(6, viewModel.Events[0].Sequence);
        Assert.Equal(ListViewModel.MaximumLiveRows + 5, viewModel.Events[^1].Sequence);
        Assert.Equal(ListViewModel.MaximumLiveRows + 5, viewModel.EventCount);
        Assert.Equal(0, viewModel.DropCount);
    }

    [Fact]
    public void AddEvents_trims_a_full_live_view_with_one_reset_notification()
    {
        var viewModel = new ListViewModel();
        viewModel.AddEvents(
            Enumerable
                .Range(1, ListViewModel.MaximumLiveRows)
                .Select(sequence => CreateEvent(sequence, CaptureKind.Read))
                .ToImmutableArray());
        var notifications = new List<NotifyCollectionChangedEventArgs>();
        viewModel.Events.CollectionChanged += (_, eventArgs) => notifications.Add(eventArgs);

        viewModel.AddEvents(
            ImmutableArray.Create(
                CreateEvent(ListViewModel.MaximumLiveRows + 1, CaptureKind.Read),
                CreateEvent(ListViewModel.MaximumLiveRows + 2, CaptureKind.Read)));

        NotifyCollectionChangedEventArgs notification = Assert.Single(notifications);
        Assert.Equal(NotifyCollectionChangedAction.Reset, notification.Action);
        Assert.Equal(3, viewModel.Events[0].Sequence);
        Assert.Equal(ListViewModel.MaximumLiveRows + 2, viewModel.Events[^1].Sequence);
        Assert.Equal(ListViewModel.MaximumLiveRows + 2, viewModel.EventCount);
    }

    [Fact]
    public void AddEvents_counts_drop_notices_for_the_status_bar()
    {
        var viewModel = new ListViewModel();

        viewModel.AddEvents(
            ImmutableArray.Create(
                CreateEvent(1, CaptureKind.DropNotice),
                CreateEvent(2, CaptureKind.Read),
                CreateEvent(3, CaptureKind.DropNotice)));

        Assert.Equal(2, viewModel.DropCount);
    }

    private static CaptureEvent CreateEvent(long sequence, CaptureKind kind) =>
        new(
            sequence,
            sequence * 10,
            17,
            42,
            kind,
            0,
            0,
            1,
            1,
            CaptureFlags.None,
            ImmutableArray.Create((byte)sequence));
}
