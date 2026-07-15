using CommMonitor.Core.Formatting;

namespace CommMonitor.Core.Tests.Formatting;

public sealed class ByteFormatterTests
{
    private static readonly byte[] Data = [0x01, 0x03, 0x00, 0xFF];

    [Theory]
    [InlineData(ByteFormat.HexSpaced, "01 03 00 FF")]
    [InlineData(ByteFormat.HexCompact, "010300FF")]
    [InlineData(ByteFormat.Decimal, "1 3 0 255")]
    [InlineData(ByteFormat.Octal, "001 003 000 377")]
    [InlineData(ByteFormat.Binary, "00000001 00000011 00000000 11111111")]
    [InlineData(ByteFormat.CArray, "new byte[] { 0x01, 0x03, 0x00, 0xFF }")]
    [InlineData(ByteFormat.PythonBytes, "b'\\x01\\x03\\x00\\xff'")]
    public void Format_returns_the_requested_byte_representation(ByteFormat format, string expected)
    {
        Assert.Equal(expected, ByteFormatter.Format(Data, format));
    }

    [Theory]
    [InlineData(ByteFormat.HexSpaced)]
    [InlineData(ByteFormat.HexCompact)]
    [InlineData(ByteFormat.Decimal)]
    [InlineData(ByteFormat.Octal)]
    [InlineData(ByteFormat.Binary)]
    [InlineData(ByteFormat.CArray)]
    [InlineData(ByteFormat.PythonBytes)]
    public void Format_returns_empty_for_empty_input(ByteFormat format)
    {
        Assert.Equal(string.Empty, ByteFormatter.Format(ReadOnlySpan<byte>.Empty, format));
    }
}
