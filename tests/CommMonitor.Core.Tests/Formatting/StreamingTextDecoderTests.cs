using System.Text;
using CommMonitor.Core.Formatting;

namespace CommMonitor.Core.Tests.Formatting;

public sealed class StreamingTextDecoderTests
{
    [Fact]
    public void Decode_preserves_a_UTF8_character_split_between_packets()
    {
        byte[] bytes = Encoding.UTF8.GetBytes("串");
        var decoder = new StreamingTextDecoder(Encoding.UTF8);

        Assert.Equal(string.Empty, decoder.Decode(bytes.AsSpan(0, 2)));
        Assert.Equal("串", decoder.Decode(bytes.AsSpan(2)));
    }

    [Fact]
    public void Reset_discards_an_incomplete_character()
    {
        byte[] bytes = Encoding.UTF8.GetBytes("串");
        var decoder = new StreamingTextDecoder(Encoding.UTF8);
        Assert.Equal(string.Empty, decoder.Decode(bytes.AsSpan(0, 2)));

        decoder.Reset();

        Assert.Equal("\uFFFD", decoder.Decode(bytes.AsSpan(2)));
    }
}
