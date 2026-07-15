using System.Collections.ObjectModel;
using System.Globalization;
using System.Text;
using CommMonitor.App.Infrastructure;
using CommMonitor.Core.Formatting;
using CommMonitor.Core.Models;

namespace CommMonitor.App.ViewModels;

public sealed class TerminalViewModel : ObservableObject
{
    public const int MaximumVisibleTextLength = 2 * 1024 * 1024;
    public const string ReadColor = "#FF1565C0";
    public const string WriteColor = "#FFC62828";

    private const int TrimHeadroom = 64 * 1024;

    private static readonly IReadOnlyList<string> SupportedEncodings = Array.AsReadOnly(
        ["ANSI", "UTF-7", "UTF-8", "UTF-16LE", "UTF-16BE"]);

    private readonly Dictionary<DecoderKey, StreamingTextDecoder> _decoders = [];
    private readonly Dictionary<long, TerminalSegment> _segmentsBySequence = [];
    private readonly ResettableObservableCollection<TerminalSegment> _segments = [];
    private string _selectedEncoding = "UTF-8";
    private bool _showTimestamp = true;
    private bool _showPort = true;
    private bool _showDirection = true;
    private bool _wrap = true;
    private bool _autoScroll = true;
    private TerminalSegment? _selectedSegment;
    private int _visibleTextLength;

    static TerminalViewModel() =>
        Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);

    public ObservableCollection<TerminalSegment> Segments => _segments;
    public IReadOnlyList<string> EncodingChoices => SupportedEncodings;

    public string SelectedEncoding
    {
        get => _selectedEncoding;
        set
        {
            if (!SupportedEncodings.Contains(value, StringComparer.Ordinal))
            {
                throw new ArgumentOutOfRangeException(
                    nameof(value),
                    value,
                    "The terminal encoding is not supported.");
            }

            SetProperty(ref _selectedEncoding, value);
        }
    }

    public bool ShowTimestamp
    {
        get => _showTimestamp;
        set
        {
            if (SetProperty(ref _showTimestamp, value))
            {
                RecalculateVisibleContentLength();
            }
        }
    }

    public bool ShowPort
    {
        get => _showPort;
        set
        {
            if (SetProperty(ref _showPort, value))
            {
                RecalculateVisibleContentLength();
            }
        }
    }

    public bool ShowDirection
    {
        get => _showDirection;
        set
        {
            if (SetProperty(ref _showDirection, value))
            {
                RecalculateVisibleContentLength();
            }
        }
    }

    public bool Wrap
    {
        get => _wrap;
        set => SetProperty(ref _wrap, value);
    }

    public bool AutoScroll
    {
        get => _autoScroll;
        set => SetProperty(ref _autoScroll, value);
    }

    public TerminalSegment? SelectedSegment
    {
        get => _selectedSegment;
        set
        {
            if (ReferenceEquals(value, _selectedSegment))
            {
                return;
            }

            if (_selectedSegment is not null)
            {
                _selectedSegment.IsSelected = false;
            }

            if (SetProperty(ref _selectedSegment, value) && value is not null)
            {
                value.IsSelected = true;
            }
        }
    }

    public int VisibleTextLength
    {
        get => _visibleTextLength;
        private set => SetProperty(ref _visibleTextLength, value);
    }

    public void Append(CaptureEvent captureEvent)
    {
        ArgumentNullException.ThrowIfNull(captureEvent);
        if (captureEvent.Kind is not (CaptureKind.Read or CaptureKind.Write))
        {
            return;
        }

        var key = new DecoderKey(
            captureEvent.DeviceId,
            captureEvent.Kind,
            SelectedEncoding);
        if (!_decoders.TryGetValue(key, out StreamingTextDecoder? decoder))
        {
            decoder = new StreamingTextDecoder(CreateEncoding(SelectedEncoding));
            _decoders.Add(key, decoder);
        }

        string text = decoder.Decode(captureEvent.Payload.AsSpan());
        if (text.Length == 0)
        {
            return;
        }

        var segment = new TerminalSegment(
            captureEvent,
            text,
            captureEvent.Kind == CaptureKind.Read ? ReadColor : WriteColor);
        _segments.Add(segment);
        _segmentsBySequence[captureEvent.Sequence] = segment;
        VisibleTextLength = checked(
            VisibleTextLength + GetRenderedContentLength(segment));
        TrimToVisibleLimit();
    }

    public void SelectEvent(CaptureEvent? captureEvent)
    {
        TerminalSegment? next = null;
        if (captureEvent is not null)
        {
            _segmentsBySequence.TryGetValue(captureEvent.Sequence, out next);
        }

        SelectedSegment = next;
    }

    public void Clear()
    {
        SelectedSegment = null;
        _decoders.Clear();
        _segmentsBySequence.Clear();
        _segments.Clear();
        VisibleTextLength = 0;
    }

    private void TrimToVisibleLimit()
    {
        if (VisibleTextLength <= MaximumVisibleTextLength)
        {
            return;
        }

        int removalCount = 0;
        int removedLength = 0;
        int targetLength = MaximumVisibleTextLength - TrimHeadroom;
        while (VisibleTextLength - removedLength > targetLength &&
            removalCount < _segments.Count)
        {
            TerminalSegment removed = _segments[removalCount];
            removedLength = checked(
                removedLength + GetRenderedContentLength(removed));
            _segmentsBySequence.Remove(removed.Sequence);
            removalCount++;
        }

        if (SelectedSegment is not null &&
            _segments.Take(removalCount).Contains(SelectedSegment))
        {
            SelectedSegment = null;
        }

        TerminalSegment[] retained = _segments.Skip(removalCount).ToArray();
        _segments.ReplaceAll(retained);
        VisibleTextLength -= removedLength;
    }

    private void RecalculateVisibleContentLength()
    {
        int renderedLength = 0;
        foreach (TerminalSegment segment in _segments)
        {
            renderedLength = checked(
                renderedLength + GetRenderedContentLength(segment));
        }

        VisibleTextLength = renderedLength;
        TrimToVisibleLimit();
    }

    private int GetRenderedContentLength(TerminalSegment segment) =>
        segment.GetRenderedContentLength(
            ShowTimestamp,
            ShowPort,
            ShowDirection);

    private static Encoding CreateEncoding(string name) => name switch
    {
        "ANSI" => Encoding.GetEncoding(CultureInfo.CurrentCulture.TextInfo.ANSICodePage),
        "UTF-7" => Encoding.GetEncoding(65000),
        "UTF-8" => new UTF8Encoding(encoderShouldEmitUTF8Identifier: false),
        "UTF-16LE" => new UnicodeEncoding(bigEndian: false, byteOrderMark: false),
        "UTF-16BE" => new UnicodeEncoding(bigEndian: true, byteOrderMark: false),
        _ => throw new ArgumentOutOfRangeException(nameof(name), name, "Unknown encoding."),
    };

    private readonly record struct DecoderKey(
        ulong DeviceId,
        CaptureKind Kind,
        string EncodingName);
}
