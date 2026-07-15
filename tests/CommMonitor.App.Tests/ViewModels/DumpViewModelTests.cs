using System.Collections.Immutable;
using CommMonitor.App.ViewModels;
using CommMonitor.Core.Models;

namespace CommMonitor.App.Tests.ViewModels;

public sealed class DumpViewModelTests
{
    [Fact]
    public void SelectEvent_formats_sixteen_byte_rows_without_mutating_the_payload()
    {
        byte[] bytes =
        [
            0x00, 0x20, 0x41, 0x7E, 0x7F, 0x31, 0x0A, 0xFF,
            0x42, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49,
            0x4A, 0x4B, 0x00, 0x5A,
        ];
        ImmutableArray<byte> payload = ImmutableArray.CreateRange(bytes);
        CaptureEvent captureEvent = CreateEvent(payload);
        var viewModel = new DumpViewModel();

        viewModel.SelectEvent(captureEvent);

        Assert.Collection(
            viewModel.Rows,
            row =>
            {
                Assert.Equal("00000000", row.Offset);
                Assert.Equal(
                    "00 20 41 7E 7F 31 0A FF 42 43 44 45 46 47 48 49",
                    row.Hex);
                Assert.Equal(". A~.1..BCDEFGHI", row.Ascii);
            },
            row =>
            {
                Assert.Equal("00000010", row.Offset);
                Assert.Equal("4A 4B 00 5A", row.Hex);
                Assert.Equal("JK.Z", row.Ascii);
            });
        Assert.Equal(payload, captureEvent.Payload);
        Assert.Equal(bytes, captureEvent.Payload);
    }

    [Fact]
    public void SelectEvent_replaces_rows_and_null_selection_clears_them()
    {
        var viewModel = new DumpViewModel();
        viewModel.SelectEvent(CreateEvent(ImmutableArray.Create((byte)0x41)));

        viewModel.SelectEvent(CreateEvent(ImmutableArray.Create((byte)0x42)));

        DumpRow row = Assert.Single(viewModel.Rows);
        Assert.Equal("42", row.Hex);

        viewModel.SelectEvent(null);

        Assert.Empty(viewModel.Rows);
    }

    private static CaptureEvent CreateEvent(ImmutableArray<byte> payload) =>
        new(
            1,
            10,
            17,
            42,
            CaptureKind.Read,
            0,
            0,
            payload.Length,
            payload.Length,
            CaptureFlags.None,
            payload);
}
