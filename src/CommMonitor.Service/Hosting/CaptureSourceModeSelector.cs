namespace CommMonitor.Service.Hosting;

public enum CaptureSourceMode
{
    Driver,
    Fake,
}

public static class CaptureSourceModeSelector
{
    public static CaptureSourceMode Determine(
        IEnumerable<string> arguments,
        bool windowsServiceMode)
    {
        ArgumentNullException.ThrowIfNull(arguments);

        bool consoleMode = arguments.Contains(
            "--console",
            StringComparer.OrdinalIgnoreCase);
        bool fakeSource = arguments.Contains(
            "--fake-source",
            StringComparer.OrdinalIgnoreCase);

        if (!fakeSource)
        {
            return CaptureSourceMode.Driver;
        }

        if (!consoleMode || windowsServiceMode)
        {
            throw new InvalidOperationException(
                "The fake capture source requires explicit --console --fake-source flags " +
                "and cannot run as a Windows service.");
        }

        return CaptureSourceMode.Fake;
    }
}
