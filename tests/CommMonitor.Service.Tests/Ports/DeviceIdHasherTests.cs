using CommMonitor.Service.Ports;

namespace CommMonitor.Service.Tests.Ports;

public sealed class DeviceIdHasherTests
{
    [Theory]
    [InlineData("USB\\VID_1A86&PID_7523\\5&1234&0&2")]
    [InlineData("usb\\vid_1a86&pid_7523\\5&1234&0&2")]
    public void Compute_matches_native_uppercase_utf16le_golden(string deviceInstanceId)
    {
        const ulong expected = 0x01D944A5154C9461UL;

        Assert.Equal(expected, DeviceIdHasher.Compute(deviceInstanceId));
    }
}
