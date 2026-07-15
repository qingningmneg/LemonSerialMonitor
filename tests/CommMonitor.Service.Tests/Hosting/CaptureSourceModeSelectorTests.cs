using CommMonitor.Service.Hosting;

namespace CommMonitor.Service.Tests.Hosting;

public sealed class CaptureSourceModeSelectorTests
{
    [Fact]
    public void Driver_is_the_default_source() =>
        Assert.Equal(
            CaptureSourceMode.Driver,
            CaptureSourceModeSelector.Determine([], windowsServiceMode: false));

    [Fact]
    public void Fake_requires_explicit_console_development_flags() =>
        Assert.Equal(
            CaptureSourceMode.Fake,
            CaptureSourceModeSelector.Determine(
                ["--console", "--fake-source"],
                windowsServiceMode: false));

    [Theory]
    [InlineData(false, "--fake-source")]
    [InlineData(true, "--fake-source")]
    [InlineData(true, "--console", "--fake-source")]
    public void Fake_is_rejected_outside_non_service_console(
        bool windowsServiceMode,
        params string[] arguments) =>
        Assert.Throws<InvalidOperationException>(() =>
            CaptureSourceModeSelector.Determine(arguments, windowsServiceMode));
}
