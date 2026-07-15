using CommMonitor.Core.Models;

namespace CommMonitor.Core.Export;

public interface ICaptureExporter
{
    Task ExportAsync(
        Stream destination,
        IReadOnlyList<CaptureEvent> events,
        CancellationToken cancellationToken = default);
}
