using System.Collections.Immutable;
using System.Text;
using CommMonitor.Core.Copying;
using CommMonitor.Core.Models;

namespace CommMonitor.Core.Tests.Copying;

public sealed class CopyFormatterTests
{
    [Theory]
    [InlineData(CopyFormat.HexSpaced, "01 03 00 FF")]
    [InlineData(CopyFormat.HexCompact, "010300FF")]
    [InlineData(CopyFormat.Text, "\u0001\u0003\0�")]
    [InlineData(CopyFormat.CArray, "new byte[] { 0x01, 0x03, 0x00, 0xFF }")]
    [InlineData(CopyFormat.PythonBytes, "b'\\x01\\x03\\x00\\xff'")]
    public void Format_returns_every_raw_phase_one_copy_format(CopyFormat format, string expected)
    {
        CaptureEvent captureEvent = CreateEvent(1, [0x01, 0x03, 0x00, 0xFF]);
        var options = new CopyOptions(format, false, false, false, false, false);

        Assert.Equal(expected, CopyFormatter.Format([captureEvent], options, Encoding.UTF8));
    }

    [Fact]
    public void Format_Tsv_writes_one_header_and_two_CRLF_terminated_rows()
    {
        CaptureEvent first = CreateEvent(1, [0x01, 0x03]);
        CaptureEvent second = CreateEvent(2, [0x00, 0xFF]);
        var options = new CopyOptions(CopyFormat.Tsv, true, false, false, false, false);

        string result = CopyFormatter.Format([first, second], options, Encoding.UTF8);

        Assert.Equal("Sequence\tData\r\n1\t01 03\r\n2\t00 FF\r\n", result);
    }

    [Fact]
    public void Format_Csv_uses_RFC4180_quoting_and_CRLF()
    {
        CaptureEvent captureEvent = CreateEvent(1, [0x41]) with { PortName = "COM,\"7\"" };
        var options = new CopyOptions(CopyFormat.Csv, false, false, true, false, false);

        string result = CopyFormatter.Format([captureEvent], options, Encoding.UTF8);

        Assert.Equal("Port,Data\r\n\"COM,\"\"7\"\"\",41\r\n", result);
    }

    [Fact]
    public void Format_Json_uses_lower_camel_case_keys_for_selected_metadata_and_payload()
    {
        CaptureEvent captureEvent = CreateEvent(7, [0x01, 0xFF]) with
        {
            PortName = "COM7",
            ProcessName = "terminal.exe",
        };
        var options = new CopyOptions(CopyFormat.Json, true, false, true, true, true);

        string result = CopyFormatter.Format([captureEvent], options, Encoding.UTF8);

        Assert.Equal(
            "[{\"sequence\":7,\"port\":\"COM7\",\"direction\":\"TX\",\"process\":\"terminal.exe (42)\",\"data\":\"01 FF\"}]",
            result);
    }

    [Theory]
    [InlineData(CopyFormat.Tsv)]
    [InlineData(CopyFormat.Csv)]
    [InlineData(CopyFormat.Json)]
    public void Format_table_formats_include_every_selected_metadata_column(CopyFormat format)
    {
        CaptureEvent captureEvent = CreateEvent(7, [0x41]) with
        {
            Timestamp = new DateTimeOffset(2026, 7, 10, 1, 2, 3, TimeSpan.Zero),
            PortName = "COM7",
            ProcessName = "terminal.exe",
        };
        var options = new CopyOptions(format, true, true, true, true, true);

        string result = CopyFormatter.Format([captureEvent], options, Encoding.UTF8);

        string[] expectedNames = format == CopyFormat.Json
            ? ["sequence", "timestamp", "port", "direction", "process", "data"]
            : ["Sequence", "Timestamp", "Port", "Direction", "Process", "Data"];
        foreach (string expectedName in expectedNames)
        {
            Assert.Contains(expectedName, result);
        }
    }

    private static CaptureEvent CreateEvent(long sequence, byte[] payload) => new(
        sequence,
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
