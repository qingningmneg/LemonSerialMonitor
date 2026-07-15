using System.Globalization;
using System.Text;
using CommMonitor.Core.Formatting;
using CommMonitor.Core.Models;

namespace CommMonitor.Core.Export;

public sealed class TextCaptureExporter : ICaptureExporter
{
    public async Task ExportAsync(
        Stream destination,
        IReadOnlyList<CaptureEvent> events,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(destination);
        ArgumentNullException.ThrowIfNull(events);

        var text = new StringBuilder();
        foreach (CaptureEvent captureEvent in events)
        {
            ArgumentNullException.ThrowIfNull(captureEvent);
            text.Append('[');
            text.Append(captureEvent.Timestamp.ToString(
                "yyyy-MM-dd HH:mm:ss.fffffff",
                CultureInfo.InvariantCulture));
            text.Append("] ");
            text.Append(captureEvent.PortName);
            text.Append(' ');
            text.Append(FormatDirection(captureEvent.Kind));
            text.Append(' ');
            text.Append(ByteFormatter.Format(captureEvent.Payload.AsSpan(), ByteFormat.HexSpaced));
            text.Append("\r\n");
        }

        byte[] content = new UTF8Encoding(encoderShouldEmitUTF8Identifier: false).GetBytes(text.ToString());
        await destination.WriteAsync(content, cancellationToken);
    }

    private static string FormatDirection(CaptureKind kind) => kind switch
    {
        CaptureKind.Read => "RX",
        CaptureKind.Write => "TX",
        _ => kind.ToString(),
    };
}
