using System.Collections.Immutable;
using CommMonitor.App.ViewModels;
using CommMonitor.Core.Models;

namespace CommMonitor.App.Tests.ViewModels;

public sealed class TerminalViewModelTests
{
    [Fact]
    public void Append_waits_for_a_complete_split_UTF8_character()
    {
        var viewModel = new TerminalViewModel();

        viewModel.Append(CreateEvent(1, 17, CaptureKind.Read, [0xE4, 0xBD]));

        Assert.Empty(viewModel.Segments);

        CaptureEvent completingEvent = CreateEvent(2, 17, CaptureKind.Read, [0xA0]);
        viewModel.Append(completingEvent);

        TerminalSegment segment = Assert.Single(viewModel.Segments);
        Assert.Equal("你", segment.Text);
        Assert.Same(completingEvent, segment.CaptureEvent);
        Assert.Equal("[00:00:00.002] ", segment.TimestampPrefix);
        Assert.Equal("[COM17] ", segment.PortPrefix);
        Assert.Equal("[Read] ", segment.DirectionPrefix);
    }

    [Fact]
    public void Append_keeps_Read_and_Write_decoder_state_and_colors_separate()
    {
        var viewModel = new TerminalViewModel();
        viewModel.Append(CreateEvent(1, 17, CaptureKind.Read, [0xE4, 0xBD]));
        viewModel.Append(CreateEvent(2, 17, CaptureKind.Write, [0xE5, 0x86]));

        viewModel.Append(CreateEvent(3, 17, CaptureKind.Read, [0xA0]));
        viewModel.Append(CreateEvent(4, 17, CaptureKind.Write, [0x99]));

        Assert.Collection(
            viewModel.Segments,
            readSegment =>
            {
                Assert.Equal("你", readSegment.Text);
                Assert.Equal(CaptureKind.Read, readSegment.Kind);
                Assert.Equal(TerminalViewModel.ReadColor, readSegment.Color);
            },
            writeSegment =>
            {
                Assert.Equal("写", writeSegment.Text);
                Assert.Equal(CaptureKind.Write, writeSegment.Kind);
                Assert.Equal(TerminalViewModel.WriteColor, writeSegment.Color);
            });
        Assert.NotEqual(viewModel.Segments[0].Color, viewModel.Segments[1].Color);
    }

    [Fact]
    public void Append_keeps_device_decoder_state_separate()
    {
        var viewModel = new TerminalViewModel();
        viewModel.Append(CreateEvent(1, 17, CaptureKind.Read, [0xE4, 0xBD]));
        viewModel.Append(CreateEvent(2, 18, CaptureKind.Read, [0xE5, 0x86]));

        viewModel.Append(CreateEvent(3, 17, CaptureKind.Read, [0xA0]));
        viewModel.Append(CreateEvent(4, 18, CaptureKind.Read, [0x99]));

        Assert.Equal(["你", "写"], viewModel.Segments.Select(segment => segment.Text));
        Assert.Equal([17UL, 18UL], viewModel.Segments.Select(segment => segment.DeviceId));
    }

    [Fact]
    public void Append_keeps_decoder_state_separate_when_encoding_changes()
    {
        var viewModel = new TerminalViewModel();
        viewModel.Append(CreateEvent(1, 17, CaptureKind.Read, [0xE4, 0xBD]));
        viewModel.SelectedEncoding = "UTF-16LE";
        viewModel.Append(CreateEvent(2, 17, CaptureKind.Read, [0x41, 0x00]));
        viewModel.SelectedEncoding = "UTF-8";

        viewModel.Append(CreateEvent(3, 17, CaptureKind.Read, [0xA0]));

        Assert.Equal(["A", "你"], viewModel.Segments.Select(segment => segment.Text));
    }

    [Fact]
    public void Append_ignores_non_data_events()
    {
        var viewModel = new TerminalViewModel();

        viewModel.Append(CreateEvent(1, 17, CaptureKind.Ioctl, [0x41]));

        Assert.Empty(viewModel.Segments);
    }

    [Fact]
    public void Encoding_and_display_options_expose_the_terminal_controls()
    {
        var viewModel = new TerminalViewModel();

        Assert.Equal(
            ["ANSI", "UTF-7", "UTF-8", "UTF-16LE", "UTF-16BE"],
            viewModel.EncodingChoices);
        Assert.Equal("UTF-8", viewModel.SelectedEncoding);
        Assert.True(viewModel.ShowTimestamp);
        Assert.True(viewModel.ShowPort);
        Assert.True(viewModel.ShowDirection);
        Assert.True(viewModel.Wrap);
        Assert.True(viewModel.AutoScroll);
    }

    [Fact]
    public void Append_caps_visible_content_by_removing_complete_oldest_segments()
    {
        var viewModel = new TerminalViewModel();
        byte[] maximumSegment = Enumerable
            .Repeat((byte)'A', TerminalViewModel.MaximumVisibleTextLength)
            .ToArray();
        viewModel.Append(CreateEvent(1, 17, CaptureKind.Read, maximumSegment));

        viewModel.Append(CreateEvent(2, 17, CaptureKind.Read, [(byte)'B']));

        TerminalSegment retained = Assert.Single(viewModel.Segments);
        Assert.Equal("B", retained.Text);
        Assert.Equal(GetRenderedContentLength(retained), viewModel.VisibleTextLength);
    }

    [Fact]
    public void Append_creates_trim_headroom_for_subsequent_small_segments()
    {
        const int expectedHeadroom = 64 * 1024;
        var viewModel = new TerminalViewModel();
        viewModel.ShowTimestamp = false;
        viewModel.ShowPort = false;
        viewModel.ShowDirection = false;
        viewModel.Append(CreateEvent(1, 17, CaptureKind.Read, [(byte)'A']));
        byte[] almostMaximumSegment = Enumerable
            .Repeat((byte)'B', TerminalViewModel.MaximumVisibleTextLength - 3)
            .ToArray();
        viewModel.Append(CreateEvent(2, 17, CaptureKind.Read, almostMaximumSegment));
        Assert.Equal(
            TerminalViewModel.MaximumVisibleTextLength,
            viewModel.VisibleTextLength);

        viewModel.Append(CreateEvent(3, 17, CaptureKind.Read, [(byte)'C']));

        Assert.True(
            viewModel.VisibleTextLength <=
                TerminalViewModel.MaximumVisibleTextLength - expectedHeadroom);
        Assert.Equal("C", Assert.Single(viewModel.Segments).Text);
    }

    [Fact]
    public void Append_counts_rendered_prefixes_and_row_separators_for_many_small_segments()
    {
        const int eventCount = 70_000;
        var viewModel = new TerminalViewModel();

        for (int sequence = 1; sequence <= eventCount; sequence++)
        {
            viewModel.Append(
                CreateEvent(sequence, 17, CaptureKind.Read, [(byte)'A']));
        }

        int retainedRenderedLength = viewModel.Segments.Sum(
            segment => GetRenderedContentLength(segment));
        Assert.Equal(retainedRenderedLength, viewModel.VisibleTextLength);
        Assert.InRange(
            viewModel.VisibleTextLength,
            0,
            TerminalViewModel.MaximumVisibleTextLength);
        Assert.True(viewModel.Segments.Count < eventCount);
    }

    [Fact]
    public void Enabling_a_prefix_recomputes_content_and_retrims_selected_segments()
    {
        var viewModel = new TerminalViewModel
        {
            ShowTimestamp = false,
            ShowPort = false,
            ShowDirection = false,
        };
        int payloadLength = (TerminalViewModel.MaximumVisibleTextLength / 2) - 1;
        byte[] payload = Enumerable.Repeat((byte)'A', payloadLength).ToArray();
        CaptureEvent first = CreateEvent(1, 17, CaptureKind.Read, payload);
        CaptureEvent second = CreateEvent(2, 17, CaptureKind.Read, payload);
        viewModel.Append(first);
        viewModel.Append(second);
        viewModel.SelectEvent(first);
        TerminalSegment selected = viewModel.Segments[0];

        viewModel.ShowTimestamp = true;

        TerminalSegment retained = Assert.Single(viewModel.Segments);
        Assert.Same(second, retained.CaptureEvent);
        Assert.Null(viewModel.SelectedSegment);
        Assert.False(selected.IsSelected);
        Assert.Equal(
            GetRenderedContentLength(
                retained,
                showTimestamp: true,
                showPort: false,
                showDirection: false),
            viewModel.VisibleTextLength);
    }

    [Fact]
    public void SelectEvent_highlights_the_associated_retained_segment()
    {
        var viewModel = new TerminalViewModel();
        CaptureEvent first = CreateEvent(1, 17, CaptureKind.Read, [(byte)'A']);
        CaptureEvent second = CreateEvent(2, 17, CaptureKind.Write, [(byte)'B']);
        viewModel.Append(first);
        viewModel.Append(second);

        viewModel.SelectEvent(second);

        Assert.False(viewModel.Segments[0].IsSelected);
        Assert.True(viewModel.Segments[1].IsSelected);
        Assert.Same(viewModel.Segments[1], viewModel.SelectedSegment);

        viewModel.SelectEvent(null);

        Assert.Null(viewModel.SelectedSegment);
        Assert.All(viewModel.Segments, segment => Assert.False(segment.IsSelected));
    }

    [Fact]
    public void Clear_removes_segments_selection_and_decoder_state()
    {
        var viewModel = new TerminalViewModel();
        CaptureEvent visible = CreateEvent(1, 17, CaptureKind.Read, [(byte)'A']);
        viewModel.Append(visible);
        viewModel.SelectEvent(visible);
        viewModel.Append(CreateEvent(2, 18, CaptureKind.Read, [0xE4, 0xBD]));

        viewModel.Clear();
        viewModel.Append(CreateEvent(3, 18, CaptureKind.Read, [0xA0]));

        Assert.Null(viewModel.SelectedSegment);
        TerminalSegment retained = Assert.Single(viewModel.Segments);
        Assert.Equal(GetRenderedContentLength(retained), viewModel.VisibleTextLength);
        Assert.Equal("�", retained.Text);
    }

    private static int GetRenderedContentLength(
        TerminalSegment segment,
        bool showTimestamp = true,
        bool showPort = true,
        bool showDirection = true) =>
        segment.Text.Length +
        (showTimestamp ? segment.TimestampPrefix.Length : 0) +
        (showPort ? segment.PortPrefix.Length : 0) +
        (showDirection ? segment.DirectionPrefix.Length : 0) +
        1; // Each ListBox item contributes one visible row boundary.

    private static CaptureEvent CreateEvent(
        long sequence,
        ulong deviceId,
        CaptureKind kind,
        byte[] payload) =>
        new(
            sequence,
            sequence * 10,
            deviceId,
            42,
            kind,
            0,
            0,
            payload.Length,
            payload.Length,
            CaptureFlags.None,
            ImmutableArray.CreateRange(payload))
        {
            PortName = $"COM{deviceId}",
            Timestamp = DateTimeOffset.UnixEpoch.AddMilliseconds(sequence),
        };
}
