using CommMonitor.Core.Ai;
using CommMonitor.Service.Capture;
using CommMonitor.Service.Hosting;
using Microsoft.Extensions.Logging.Abstractions;

namespace CommMonitor.Service.Tests.Hosting;

public sealed class CaptureServiceStartupTests
{
    [Fact]
    public async Task Driver_unavailable_does_not_abort_service_startup()
    {
        await CaptureServiceStartup.InitializeAsync(
            _ => throw new CaptureLeaseException(
                AiErrorCodes.DriverUnavailable,
                "Scripted missing driver control device."),
            NullLogger.Instance,
            CancellationToken.None);
    }

    [Fact]
    public async Task Other_capture_errors_are_not_swallowed()
    {
        CaptureLeaseException error = await Assert.ThrowsAsync<CaptureLeaseException>(() =>
            CaptureServiceStartup.InitializeAsync(
                _ => throw new CaptureLeaseException("OTHER", "Scripted failure."),
                NullLogger.Instance,
                CancellationToken.None));

        Assert.Equal("OTHER", error.Code);
    }

    [Fact]
    public async Task Cancellation_is_not_swallowed()
    {
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            CaptureServiceStartup.InitializeAsync(
                token => Task.FromCanceled(token),
                NullLogger.Instance,
                cancellation.Token));
    }
}
