using System.Diagnostics;

namespace CommMonitor.Service.Driver;

internal interface IQpcClock
{
    long GetTimestamp();
    DateTimeOffset UtcNow { get; }
    long Frequency { get; }
}

internal interface ICaptureDelay
{
    ValueTask DelayAsync(TimeSpan delay, CancellationToken cancellationToken);
}

internal sealed class SystemQpcClock : IQpcClock
{
    public long GetTimestamp() => Stopwatch.GetTimestamp();

    public DateTimeOffset UtcNow => DateTimeOffset.UtcNow;

    public long Frequency => Stopwatch.Frequency;
}

internal sealed class SystemCaptureDelay : ICaptureDelay
{
    public async ValueTask DelayAsync(TimeSpan delay, CancellationToken cancellationToken) =>
        await Task.Delay(delay, cancellationToken).ConfigureAwait(false);
}

internal sealed class DriverUnavailableException : IOException
{
    public DriverUnavailableException(string message)
        : base(message)
    {
    }

    public DriverUnavailableException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
}
