using System.Collections.Immutable;
using System.Globalization;
using CommMonitor.App.Infrastructure;

namespace CommMonitor.App.Tests.Infrastructure;

public sealed class CaptureEventConverterTests
{
    [Fact]
    public void PayloadHexConverter_formats_an_immutable_payload_as_spaced_HEX()
    {
        var converter = new PayloadHexConverter();

        object result = converter.Convert(
            ImmutableArray.Create<byte>(0x01, 0x03, 0xFF),
            typeof(string),
            parameter: string.Empty,
            CultureInfo.InvariantCulture);

        Assert.Equal("01 03 FF", result);
    }

    [Fact]
    public void PayloadTextConverter_decodes_an_immutable_payload_as_UTF8()
    {
        var converter = new PayloadTextConverter();

        object result = converter.Convert(
            ImmutableArray.Create<byte>(0xE4, 0xB8, 0xB2, 0xE5, 0x8F, 0xA3),
            typeof(string),
            parameter: string.Empty,
            CultureInfo.InvariantCulture);

        Assert.Equal("\u4E32\u53E3", result);
    }
}
