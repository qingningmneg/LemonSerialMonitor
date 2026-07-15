using System.Collections.Immutable;
using System.Globalization;
using CommMonitor.Core.Ai;
using CommMonitor.Core.Models;

namespace CommMonitor.Core.Tests.Ai;

public sealed class AiEventMapperTests
{
    [Fact]
    public void Map_uses_lossless_and_stable_wire_formats()
    {
        DateTimeOffset timestamp = new DateTimeOffset(
            2026,
            7,
            13,
            12,
            34,
            56,
            789,
            TimeSpan.FromHours(8)).AddTicks(1234);
        CaptureEvent source = TestEvents.Create(
            sequence: long.MaxValue,
            wireSequence: long.MaxValue - 1,
            qpcTicks: long.MinValue,
            deviceId: ulong.MaxValue,
            payload: [0x00, 0x80, 0xFF],
            kind: CaptureKind.Ioctl,
            ioctlCode: 0x89ABCDEF,
            ntStatus: unchecked((int)0xC0000005),
            requestedLength: 5,
            completedLength: 4,
            flags: CaptureFlags.Truncated | CaptureFlags.InputPayload,
            timestamp: timestamp);

        AiEventDto dto = AiEventMapper.Map(source, includeHex: true);

        Assert.Equal(AiProtocol.Version, dto.SchemaVersion);
        Assert.Equal(long.MaxValue.ToString(CultureInfo.InvariantCulture), dto.Sequence);
        Assert.Equal((long.MaxValue - 1).ToString(CultureInfo.InvariantCulture), dto.WireSequence);
        Assert.Equal(long.MinValue.ToString(CultureInfo.InvariantCulture), dto.QpcTicks);
        Assert.Equal("2026-07-13T04:34:56.7891234Z", dto.TimestampUtc);
        Assert.Equal("FFFFFFFFFFFFFFFF", dto.DeviceId);
        Assert.Equal("COM3", dto.PortName);
        Assert.Equal(4, dto.ProcessId);
        Assert.Equal("terminal.exe", dto.ProcessName);
        Assert.Equal("available", dto.ProcessNameStatus);
        Assert.Equal("Ioctl", dto.Kind);
        Assert.Equal("0x89ABCDEF", dto.IoctlCodeHex);
        Assert.Equal("0xC0000005", dto.NtStatusHex);
        Assert.Equal(5, dto.RequestedLength);
        Assert.Equal(4, dto.CompletedLength);
        Assert.Equal(3, dto.CapturedLength);
        Assert.Equal(["Truncated", "InputPayload"], dto.Flags);
        Assert.Equal("AID/", dto.PayloadBase64);
        Assert.Equal("00 80 FF", dto.PayloadHex);
        Assert.Null(dto.TextPreview);
        Assert.True(dto.Truncated);
    }

    [Fact]
    public void Map_omits_optional_hex_and_marks_an_unresolved_process_name()
    {
        CaptureEvent source = TestEvents.Create(
            payload: [0x01, 0xAB],
            processName: string.Empty);

        AiEventDto dto = AiEventMapper.Map(source, includeHex: false);

        Assert.Equal("Aas=", dto.PayloadBase64);
        Assert.Null(dto.PayloadHex);
        Assert.Equal(string.Empty, dto.ProcessName);
        Assert.Equal("unavailable", dto.ProcessNameStatus);
        Assert.False(dto.Truncated);
    }

    [Fact]
    public void Map_emits_every_flag_name_in_stable_order_and_omits_None()
    {
        CaptureFlags allFlags =
            CaptureFlags.Truncated |
            CaptureFlags.InputPayload |
            CaptureFlags.OutputPayload |
            CaptureFlags.Synthetic;

        AiEventDto allFlagsDto = AiEventMapper.Map(
            TestEvents.Create(flags: allFlags),
            includeHex: false);
        AiEventDto noFlagsDto = AiEventMapper.Map(
            TestEvents.Create(flags: CaptureFlags.None),
            includeHex: false);

        Assert.Equal(
            ["Truncated", "InputPayload", "OutputPayload", "Synthetic"],
            allFlagsDto.Flags);
        Assert.Empty(noFlagsDto.Flags);
    }
}

internal static class TestEvents
{
    public static CaptureEvent Create(
        long sequence = 1,
        long? wireSequence = null,
        long qpcTicks = 2,
        ulong deviceId = 3,
        byte[]? payload = null,
        int processId = 4,
        string processName = "terminal.exe",
        CaptureKind kind = CaptureKind.Read,
        uint ioctlCode = 0,
        int ntStatus = 0,
        int? requestedLength = null,
        int? completedLength = null,
        CaptureFlags flags = CaptureFlags.None,
        DateTimeOffset? timestamp = null) =>
        new(
            sequence,
            qpcTicks,
            deviceId,
            processId,
            kind,
            ioctlCode,
            ntStatus,
            requestedLength ?? payload?.Length ?? 0,
            completedLength ?? payload?.Length ?? 0,
            flags,
            ImmutableArray.CreateRange(payload ?? []))
        {
            WireSequence = wireSequence ?? sequence,
            PortName = "COM3",
            ProcessName = processName,
            Timestamp = timestamp ?? DateTimeOffset.UnixEpoch,
        };
}
