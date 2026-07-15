using CommMonitor.Core.Ai;
using CommMonitor.Service.Capture;

namespace CommMonitor.Service.Hosting;

internal static class CaptureServiceStartup
{
    public static async Task InitializeAsync(
        Func<CancellationToken, Task> initializeCaptureAuthorityAsync,
        ILogger logger,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(initializeCaptureAuthorityAsync);
        ArgumentNullException.ThrowIfNull(logger);

        try
        {
            await initializeCaptureAuthorityAsync(cancellationToken)
                .ConfigureAwait(false);
        }
        catch (CaptureLeaseException exception) when (
            exception.Code == AiErrorCodes.DriverUnavailable)
        {
            logger.LogWarning(
                exception,
                "The capture driver is temporarily unavailable during service startup. " +
                "The service will remain running and retry when requested.");
        }
    }
}
