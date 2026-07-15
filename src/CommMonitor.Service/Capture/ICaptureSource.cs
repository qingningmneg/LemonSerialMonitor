using CommMonitor.Core.Models;

namespace CommMonitor.Service.Capture;

public interface ICaptureSource : IAsyncDisposable
{
    ValueTask ConfigureAsync(
        CaptureState state,
        IReadOnlySet<ulong> deviceIds,
        CancellationToken cancellationToken);

    IAsyncEnumerable<CaptureEvent> ReadAllAsync(CancellationToken cancellationToken);
}
