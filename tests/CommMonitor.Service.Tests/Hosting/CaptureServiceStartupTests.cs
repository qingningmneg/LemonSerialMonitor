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

    [Theory]
    [InlineData(CaptureSourceStatusKind.Ready)]
    [InlineData(CaptureSourceStatusKind.DevelopmentFake)]
    [InlineData(CaptureSourceStatusKind.DriverUnavailable)]
    public void Allowed_source_statuses_can_start_the_host(CaptureSourceStatusKind kind) =>
        CaptureServiceStartup.EnsureSourceStatusAllowsStartup(
            new CaptureSourceStatus(kind, "scripted"),
            NullLogger.Instance);

    [Theory]
    [InlineData(CaptureSourceStatusKind.ProtocolMismatch)]
    [InlineData(CaptureSourceStatusKind.Faulted)]
    [InlineData((CaptureSourceStatusKind)999)]
    public void Fatal_source_statuses_abort_host_startup(CaptureSourceStatusKind kind) =>
        Assert.Throws<InvalidOperationException>(() =>
            CaptureServiceStartup.EnsureSourceStatusAllowsStartup(
                new CaptureSourceStatus(kind, "scripted"),
                NullLogger.Instance));
}
