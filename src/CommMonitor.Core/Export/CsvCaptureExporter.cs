using System.Text;
using CommMonitor.Core.Copying;
using CommMonitor.Core.Models;

namespace CommMonitor.Core.Export;

public sealed class CsvCaptureExporter : ICaptureExporter
{
    private static readonly CopyOptions Options = new(
        CopyFormat.Csv,
        IncludeSequence: true,
        IncludeTimestamp: true,
        IncludePort: true,
        IncludeDirection: true,
        IncludeProcess: true);

    public async Task ExportAsync(
        Stream destination,
        IReadOnlyList<CaptureEvent> events,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(destination);
        ArgumentNullException.ThrowIfNull(events);

        byte[] preamble = Encoding.UTF8.GetPreamble();
        await destination.WriteAsync(preamble, cancellationToken);

        string csv = CopyFormatter.Format(events, Options, Encoding.UTF8);
        byte[] content = Encoding.UTF8.GetBytes(csv);
        await destination.WriteAsync(content, cancellationToken);
    }
}
