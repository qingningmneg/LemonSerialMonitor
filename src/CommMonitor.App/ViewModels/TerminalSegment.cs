using System.Globalization;
using CommMonitor.App.Infrastructure;
using CommMonitor.Core.Models;

namespace CommMonitor.App.ViewModels;

public sealed class TerminalSegment : ObservableObject
{
    private const int RowSeparatorLength = 1;

    private bool _isSelected;

    internal TerminalSegment(CaptureEvent captureEvent, string text, string color)
    {
        CaptureEvent = captureEvent ?? throw new ArgumentNullException(nameof(captureEvent));
        Text = text ?? throw new ArgumentNullException(nameof(text));
        Color = color ?? throw new ArgumentNullException(nameof(color));
        TimestampPrefix = $"[{captureEvent.Timestamp.ToString("HH:mm:ss.fff", CultureInfo.InvariantCulture)}] ";
        PortPrefix = $"[{captureEvent.PortName}] ";
        DirectionPrefix = $"[{captureEvent.Kind}] ";
    }

    public CaptureEvent CaptureEvent { get; }
    public long Sequence => CaptureEvent.Sequence;
    public ulong DeviceId => CaptureEvent.DeviceId;
    public CaptureKind Kind => CaptureEvent.Kind;
    public string Text { get; }
    public string Color { get; }
    public string TimestampPrefix { get; }
    public string PortPrefix { get; }
    public string DirectionPrefix { get; }

    public bool IsSelected
    {
        get => _isSelected;
        internal set => SetProperty(ref _isSelected, value);
    }

    internal int GetRenderedContentLength(
        bool showTimestamp,
        bool showPort,
        bool showDirection) =>
        checked(
            Text.Length +
            (showTimestamp ? TimestampPrefix.Length : 0) +
            (showPort ? PortPrefix.Length : 0) +
            (showDirection ? DirectionPrefix.Length : 0) +
            RowSeparatorLength);
}
