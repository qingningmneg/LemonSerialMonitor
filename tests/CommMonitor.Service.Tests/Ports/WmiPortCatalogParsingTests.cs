using System.Management;
using System.Runtime.Versioning;
using CommMonitor.Service.Ports;

namespace CommMonitor.Service.Tests.Ports;

public sealed class WmiPortCatalogParsingTests
{
    [Fact]
    public void ParseRows_accepts_final_suffix_sorts_naturally_and_deduplicates()
    {
        WmiPortRow duplicate = new("USB Serial Device (COM10)", "USB\\VID_1A86&PID_7523\\A");
        IReadOnlyList<PortInfo> ports = WmiPortCatalog.ParseRows([
            duplicate,
            new WmiPortRow("Bluetooth link (COM2)", "BTHENUM\\DEV_2"),
            duplicate,
            new WmiPortRow("Ignored (COM3) trailing", "USB\\BAD"),
            new WmiPortRow("Ignored COM4", "USB\\BAD2"),
            new WmiPortRow("Missing id (COM5)", null),
        ]);

        Assert.Equal(["COM2", "COM10"], ports.Select(port => port.Name));
        Assert.Equal("Bluetooth link (COM2)", ports[0].FriendlyName);
        Assert.Equal(DeviceIdHasher.Compute("BTHENUM\\DEV_2"), ports[0].DeviceIdHash);
        Assert.Equal("USB\\VID_1A86&PID_7523\\A", ports[1].PnpDeviceId);
    }

    [Theory]
    [InlineData("Device (com7)", "COM7")]
    [InlineData("Device (COM001)", "COM001")]
    public void TryParseRow_is_case_insensitive_for_final_COM_suffix(
        string friendlyName,
        string expectedName)
    {
        Assert.True(WmiPortCatalog.TryParseRow(
            new WmiPortRow(friendlyName, "USB\\ID"),
            out PortInfo? port));
        Assert.Equal(expectedName, port!.Name);
    }

    [Fact]
    public void ParseRows_canonicalizes_identity_and_folds_exact_duplicates()
    {
        IReadOnlyList<PortInfo> ports = WmiPortCatalog.ParseRows([
            new WmiPortRow("Zulu (COM6)", "usb\\id"),
            new WmiPortRow("Alpha (com6)", "USB\\ID"),
        ]);

        PortInfo port = Assert.Single(ports);
        Assert.Equal("COM6", port.Name);
        Assert.Equal("USB\\ID", port.PnpDeviceId);
        Assert.Equal("Alpha (com6)", port.FriendlyName);
    }

    [Fact]
    public void ParseRows_rejects_conflicting_COM_ownership()
    {
        Assert.Throws<PortCatalogIntegrityException>(() => WmiPortCatalog.ParseRows([
            new WmiPortRow("First (COM6)", "USB\\A"),
            new WmiPortRow("Second (COM6)", "USB\\B"),
        ]));
    }

    [Fact]
    public void ParseRows_rejects_one_instance_claiming_two_COM_names()
    {
        Assert.Throws<PortCatalogIntegrityException>(() => WmiPortCatalog.ParseRows([
            new WmiPortRow("First (COM6)", "USB\\A"),
            new WmiPortRow("Second (COM7)", "USB\\A"),
        ]));
    }

    [Theory]
    [InlineData(" USB\\ID")]
    [InlineData("USB\\ID ")]
    [InlineData("USB\0ID")]
    public void ParseRows_preserves_invalid_identity_filtering(string identity)
    {
        Assert.Empty(WmiPortCatalog.ParseRows([
            new WmiPortRow("Device (COM6)", identity),
        ]));
    }

    [Fact]
    [SupportedOSPlatform("windows")]
    public async Task GetPortsAsync_wraps_Wmi_query_failures_as_IOException()
    {
        var catalog = new WmiPortCatalog(
            _ => throw new ManagementException("WMI unavailable"));

        IOException error = await Assert.ThrowsAsync<IOException>(() =>
            catalog.GetPortsAsync(CancellationToken.None).AsTask());

        Assert.IsType<ManagementException>(error.InnerException);
    }

    [Fact]
    public async Task GetPortsAsync_preserves_query_cancellation()
    {
        var catalog = new WmiPortCatalog(
            _ => throw new OperationCanceledException("cancelled"));

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            catalog.GetPortsAsync(CancellationToken.None).AsTask());
    }
}
