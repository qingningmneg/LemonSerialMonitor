using System.Collections.Immutable;
using CommMonitor.Core.Models;
using CommMonitor.Core.Search;

namespace CommMonitor.Core.Tests.Search;

public sealed class CaptureSearchMatcherTests
{
    [Fact]
    public void IsMatch_finds_a_contiguous_HEX_pattern_with_wildcards()
    {
        CaptureEvent captureEvent = CreateEvent([0x01, 0x03, 0x00, 0xFF]);

        bool matched = CaptureSearchMatcher.IsMatch(captureEvent, "03 ?? FF", out string? error);

        Assert.True(matched);
        Assert.Null(error);
    }

    [Fact]
    public void IsMatch_returns_false_when_the_HEX_pattern_is_absent()
    {
        bool matched = CaptureSearchMatcher.IsMatch(
            new byte[] { 0x01, 0x03, 0x00, 0xFF },
            "03 FF",
            out string? error);

        Assert.False(matched);
        Assert.Null(error);
    }

    [Theory]
    [InlineData("")]
    [InlineData("0")]
    [InlineData("GG")]
    [InlineData("???")]
    [InlineData("01 100")]
    public void IsMatch_reports_invalid_HEX_patterns(string pattern)
    {
        bool matched = CaptureSearchMatcher.IsMatch(new byte[] { 0x01 }, pattern, out string? error);

        Assert.False(matched);
        Assert.False(string.IsNullOrWhiteSpace(error));
    }

    private static CaptureEvent CreateEvent(byte[] payload) => new(
        1,
        0,
        1,
        42,
        CaptureKind.Write,
        0,
        0,
        payload.Length,
        payload.Length,
        CaptureFlags.None,
        ImmutableArray.CreateRange(payload));
}
