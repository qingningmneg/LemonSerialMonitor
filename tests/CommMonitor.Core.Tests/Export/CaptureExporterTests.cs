using System.Collections.Immutable;
using System.Text;
using CommMonitor.Core.Export;
using CommMonitor.Core.Models;

namespace CommMonitor.Core.Tests.Export;

public sealed class CaptureExporterTests
{
    [Fact]
    public async Task CsvCaptureExporter_writes_UTF8_BOM_fixed_header_and_invariant_spaced_hex_row()
    {
        CaptureEvent captureEvent = CreateEvent(
            sequence: 7,
            kind: CaptureKind.Write,
            payload: [0x01, 0xA2],
            timestamp: new DateTimeOffset(2026, 7, 10, 1, 2, 3, TimeSpan.Zero).AddTicks(4_567_890));
        await using var destination = new MemoryStream();
        ICaptureExporter exporter = new CsvCaptureExporter();

        await exporter.ExportAsync(destination, [captureEvent], CancellationToken.None);

        byte[] preamble = Encoding.UTF8.GetPreamble();
        Assert.True(destination.ToArray().AsSpan().StartsWith(preamble));
        Assert.Equal(
            "Sequence,Timestamp,Port,Direction,Process,Data\r\n" +
            "7,2026-07-10T01:02:03.4567890+00:00,COM7,TX,terminal.exe (42),01 A2\r\n",
            Encoding.UTF8.GetString(destination.ToArray().AsSpan(preamble.Length)));
    }

    [Fact]
    public async Task TextCaptureExporter_writes_readable_CRLF_terminated_lines()
    {
        CaptureEvent first = CreateEvent(
            sequence: 1,
            kind: CaptureKind.Write,
            payload: [0x01, 0x02],
            timestamp: new DateTimeOffset(2026, 7, 10, 1, 2, 3, TimeSpan.Zero).AddTicks(4_567_890));
        CaptureEvent second = CreateEvent(
            sequence: 2,
            kind: CaptureKind.Read,
            payload: [0xA0],
            timestamp: new DateTimeOffset(2026, 7, 10, 1, 2, 4, TimeSpan.Zero));
        await using var destination = new MemoryStream();
        ICaptureExporter exporter = new TextCaptureExporter();

        await exporter.ExportAsync(destination, [first, second], CancellationToken.None);

        Assert.Equal(
            "[2026-07-10 01:02:03.4567890] COM7 TX 01 02\r\n" +
            "[2026-07-10 01:02:04.0000000] COM7 RX A0\r\n",
            Encoding.UTF8.GetString(destination.ToArray()));
    }

    [Fact]
    public async Task RawCaptureExporter_concatenates_only_read_and_write_payloads_in_sequence_order()
    {
        CaptureEvent ioctl = CreateEvent(sequence: 3, kind: CaptureKind.Ioctl, payload: [0x99]);
        CaptureEvent write = CreateEvent(sequence: 2, kind: CaptureKind.Write, payload: [0xBB, 0xCC]);
        CaptureEvent read = CreateEvent(sequence: 1, kind: CaptureKind.Read, payload: [0xAA]);
        await using var destination = new MemoryStream();
        ICaptureExporter exporter = new RawCaptureExporter();

        await exporter.ExportAsync(destination, [ioctl, write, read], CancellationToken.None);

        Assert.Equal(new byte[] { 0xAA, 0xBB, 0xCC }, destination.ToArray());
    }

    private static CaptureEvent CreateEvent(
        long sequence,
        CaptureKind kind,
        byte[] payload,
        DateTimeOffset timestamp = default) => new(
            sequence,
            0,
            1,
            42,
            kind,
            0,
            0,
            payload.Length,
            payload.Length,
            CaptureFlags.None,
            ImmutableArray.CreateRange(payload))
        {
            PortName = "COM7",
            ProcessName = "terminal.exe",
            Timestamp = timestamp,
        };
}
