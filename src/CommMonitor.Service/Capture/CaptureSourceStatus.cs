namespace CommMonitor.Service.Capture;

public enum CaptureSourceStatusKind
{
    Ready,
    DriverUnavailable,
    ProtocolMismatch,
    DevelopmentFake,
    Faulted,
}

public sealed record CaptureSourceStatus(
    CaptureSourceStatusKind Kind,
    string Message);

public interface ICaptureSourceStatusProvider
{
    ValueTask<CaptureSourceStatus> GetStatusAsync(CancellationToken cancellationToken);
}
