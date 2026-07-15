using CommMonitor.Core.Models;

namespace CommMonitor.Core.Export;

public sealed class RawCaptureExporter : ICaptureExporter
{
    public async Task ExportAsync(
        Stream destination,
        IReadOnlyList<CaptureEvent> events,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(destination);
        ArgumentNullException.ThrowIfNull(events);

        foreach (CaptureEvent captureEvent in events.OrderBy(static item => item.Sequence))
        {
            ArgumentNullException.ThrowIfNull(captureEvent);
            if (captureEvent.Kind is not (CaptureKind.Read or CaptureKind.Write))
            {
                continue;
            }

            byte[] payload = captureEvent.Payload.AsSpan().ToArray();
            await destination.WriteAsync(payload, cancellationToken);
        }
    }
}
