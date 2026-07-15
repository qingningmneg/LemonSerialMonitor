namespace CommMonitor.Service.Capture;

internal interface IWpfCaptureController
{
    Task StartWpfAsync(
        CaptureSelection selection,
        CancellationToken cancellationToken = default);
    Task PauseWpfAsync(CancellationToken cancellationToken = default);
    Task ResumeWpfAsync(CancellationToken cancellationToken = default);
    Task StopWpfAsync(CancellationToken cancellationToken = default);
}
