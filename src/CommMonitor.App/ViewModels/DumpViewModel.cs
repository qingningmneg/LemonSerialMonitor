using System.Collections.ObjectModel;
using System.Globalization;
using CommMonitor.Core.Formatting;
using CommMonitor.Core.Models;

namespace CommMonitor.App.ViewModels;

public sealed class DumpViewModel
{
    private const int BytesPerRow = 16;

    public ObservableCollection<DumpRow> Rows { get; } = [];

    public void SelectEvent(CaptureEvent? captureEvent)
    {
        Rows.Clear();
        if (captureEvent is null)
        {
            return;
        }

        ReadOnlySpan<byte> payload = captureEvent.Payload.AsSpan();
        for (int offset = 0; offset < payload.Length; offset += BytesPerRow)
        {
            ReadOnlySpan<byte> rowBytes = payload.Slice(
                offset,
                Math.Min(BytesPerRow, payload.Length - offset));
            Rows.Add(
                new DumpRow(
                    offset.ToString("X8", CultureInfo.InvariantCulture),
                    ByteFormatter.Format(rowBytes, ByteFormat.HexSpaced),
                    FormatAscii(rowBytes)));
        }
    }

    private static string FormatAscii(ReadOnlySpan<byte> bytes)
    {
        char[] characters = new char[bytes.Length];
        for (int index = 0; index < bytes.Length; index++)
        {
            byte value = bytes[index];
            characters[index] = value is >= 0x20 and <= 0x7E ? (char)value : '.';
        }

        return new string(characters);
    }
}
