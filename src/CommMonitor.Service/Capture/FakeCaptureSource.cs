using System.Runtime.CompilerServices;
using System.Threading.Channels;
using CommMonitor.Core.Models;

namespace CommMonitor.Service.Capture;

internal sealed class FakeCaptureSource :
    ICaptureSource,
    ICaptureSourceStatusProvider,
    ICaptureSourceStatisticsProvider
{
    internal const string StatusMessage =
        "FAKE/DEVELOPMENT capture source active; the driver-backed source is not installed.";

    private readonly Channel<CaptureEvent> _events = Channel.CreateUnbounded<CaptureEvent>(
        new UnboundedChannelOptions
        {
            AllowSynchronousContinuations = false,
            SingleReader = true,
            SingleWriter = false,
        });
    private readonly bool _reportKnownStatistics;

    private bool _disposed;
    private CaptureState _state;
    private long _lastWireSequence;

    public FakeCaptureSource(bool reportKnownStatistics = false)
    {
        _reportKnownStatistics = reportKnownStatistics;
    }

    public ValueTask ConfigureAsync(
        CaptureState state,
        IReadOnlySet<ulong> deviceIds,
        CancellationToken cancellationToken)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        ArgumentNullException.ThrowIfNull(deviceIds);
        cancellationToken.ThrowIfCancellationRequested();
        _state = state;
        return ValueTask.CompletedTask;
    }

    public async IAsyncEnumerable<CaptureEvent> ReadAllAsync(
        [EnumeratorCancellation] CancellationToken cancellationToken)
    {
        await foreach (CaptureEvent captureEvent in
            _events.Reader.ReadAllAsync(cancellationToken).ConfigureAwait(false))
        {
            yield return captureEvent;
        }
    }

    internal ValueTask EmitAsync(
        CaptureEvent captureEvent,
        CancellationToken cancellationToken = default)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        ArgumentNullException.ThrowIfNull(captureEvent);
        Interlocked.Exchange(ref _lastWireSequence, captureEvent.WireSequence);
        return _events.Writer.WriteAsync(captureEvent, cancellationToken);
    }

    public ValueTask<CaptureSourceStatus> GetStatusAsync(CancellationToken cancellationToken)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        cancellationToken.ThrowIfCancellationRequested();
        return ValueTask.FromResult(new CaptureSourceStatus(
            CaptureSourceStatusKind.DevelopmentFake,
            StatusMessage));
    }

    public ValueTask<CaptureSourceStatistics> GetStatisticsAsync(
        CancellationToken cancellationToken)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        cancellationToken.ThrowIfCancellationRequested();
        if (_reportKnownStatistics)
        {
            return ValueTask.FromResult(new CaptureSourceStatistics(
                true,
                0,
                _state,
                0,
                unchecked((ulong)Interlocked.Read(ref _lastWireSequence)),
                DateTimeOffset.UtcNow,
                null));
        }

        return ValueTask.FromResult(CaptureSourceStatistics.Unknown(
            "Driver statistics are unavailable for the development fake capture source.",
            DateTimeOffset.UtcNow));
    }

    public ValueTask DisposeAsync()
    {
        if (!_disposed)
        {
            _disposed = true;
            _events.Writer.TryComplete();
        }

        return ValueTask.CompletedTask;
    }
}
