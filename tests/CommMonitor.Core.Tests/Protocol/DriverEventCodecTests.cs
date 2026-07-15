using System.Buffers.Binary;
using System.Collections.Immutable;
using CommMonitor.Core.Models;
using CommMonitor.Core.Protocol;

namespace CommMonitor.Core.Tests.Protocol;

public sealed class DriverEventCodecTests
{
    [Fact]
    public void DecodeBatch_decodes_one_little_endian_event()
    {
        byte[] bytes = new byte[DriverProtocol.HeaderSize + 3];
        BinaryPrimitives.WriteUInt32LittleEndian(bytes, DriverProtocol.Magic);
        BinaryPrimitives.WriteUInt16LittleEndian(bytes.AsSpan(4), DriverProtocol.Version);
        BinaryPrimitives.WriteUInt16LittleEndian(bytes.AsSpan(6), DriverProtocol.HeaderSize);
        BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(8), (uint)bytes.Length);
        BinaryPrimitives.WriteUInt64LittleEndian(bytes.AsSpan(12), 7);
        BinaryPrimitives.WriteInt64LittleEndian(bytes.AsSpan(20), 1234);
        BinaryPrimitives.WriteUInt64LittleEndian(bytes.AsSpan(28), 99);
        BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(36), 42);
        BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(40), (uint)CaptureKind.Write);
        BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(44), 0);
        BinaryPrimitives.WriteInt32LittleEndian(bytes.AsSpan(48), 0);
        BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(52), 3);
        BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(56), 3);
        BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(60), 3);
        BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(64), 0);
        bytes[68] = 0x01; bytes[69] = 0x02; bytes[70] = 0x03;

        CaptureEvent item = Assert.Single(DriverEventCodec.DecodeBatch(bytes));

        Assert.Equal(7L, item.Sequence);
        Assert.Equal(CaptureKind.Write, item.Kind);
        Assert.True(item.Payload.AsSpan().SequenceEqual(new byte[] { 1, 2, 3 }));
    }

    [Fact]
    public void DecodeBatch_rejects_invalid_total_size()
    {
        byte[] bytes = new byte[DriverProtocol.HeaderSize];
        BinaryPrimitives.WriteUInt32LittleEndian(bytes, DriverProtocol.Magic);
        BinaryPrimitives.WriteUInt16LittleEndian(bytes.AsSpan(4), DriverProtocol.Version);
        BinaryPrimitives.WriteUInt16LittleEndian(bytes.AsSpan(6), DriverProtocol.HeaderSize);
        BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(8), 9999);

        Assert.Throws<InvalidDataException>(() => DriverEventCodec.DecodeBatch(bytes));
    }

    [Fact]
    public void DecodeBatch_rejects_bad_magic()
    {
        byte[] bytes = CreateEvent();
        BinaryPrimitives.WriteUInt32LittleEndian(bytes, 0);

        Assert.Throws<InvalidDataException>(() => DriverEventCodec.DecodeBatch(bytes));
    }

    [Fact]
    public void DecodeBatch_rejects_bad_version()
    {
        byte[] bytes = CreateEvent();
        BinaryPrimitives.WriteUInt16LittleEndian(bytes.AsSpan(4), DriverProtocol.Version + 1);

        Assert.Throws<InvalidDataException>(() => DriverEventCodec.DecodeBatch(bytes));
    }

    [Fact]
    public void DecodeBatch_rejects_bad_header_size()
    {
        byte[] bytes = CreateEvent();
        BinaryPrimitives.WriteUInt16LittleEndian(bytes.AsSpan(6), DriverProtocol.HeaderSize - 1);

        Assert.Throws<InvalidDataException>(() => DriverEventCodec.DecodeBatch(bytes));
    }

    [Fact]
    public void DecodeBatch_rejects_oversized_payload()
    {
        byte[] bytes = CreateEvent(payload: new byte[DriverProtocol.MaxPayload + 1]);

        Assert.Throws<InvalidDataException>(() => DriverEventCodec.DecodeBatch(bytes));
    }

    [Fact]
    public void DecodeBatch_rejects_oversized_batch()
    {
        byte[] bytes = new byte[DriverProtocol.MaxBatchBytes + 1];

        Assert.Throws<InvalidDataException>(() => DriverEventCodec.DecodeBatch(bytes));
    }

    [Fact]
    public void DecodeBatch_rejects_trailing_bytes()
    {
        byte[] bytes = [.. CreateEvent(), 0xFF];

        Assert.Throws<InvalidDataException>(() => DriverEventCodec.DecodeBatch(bytes));
    }

    [Fact]
    public void DecodeBatch_advances_by_each_event_total_size()
    {
        byte[] first = CreateEvent(sequence: 7, payload: [0x01]);
        byte[] second = CreateEvent(sequence: 8, payload: [0x02, 0x03]);
        byte[] bytes = [.. first, .. second];

        IReadOnlyList<CaptureEvent> events = DriverEventCodec.DecodeBatch(bytes);

        Assert.Collection(
            events,
            item =>
            {
                Assert.Equal(7L, item.Sequence);
                Assert.True(item.Payload.AsSpan().SequenceEqual(new byte[] { 0x01 }));
            },
            item =>
            {
                Assert.Equal(8L, item.Sequence);
                Assert.True(item.Payload.AsSpan().SequenceEqual(new byte[] { 0x02, 0x03 }));
            });
    }

    [Fact]
    public void DecodeBatch_maps_all_header_fields()
    {
        byte[] bytes = CreateEvent(
            sequence: 0x0102030405060708,
            qpcTicks: -123456789,
            deviceId: 0x8877665544332211,
            processId: 0xF1234567,
            kind: CaptureKind.Ioctl,
            ioctlCode: 0x00222000,
            ntStatus: unchecked((int)0xC0000001),
            requestedLength: 128,
            completedLength: 64,
            flags: CaptureFlags.Truncated | CaptureFlags.InputPayload,
            payload: [0xA1, 0xB2]);

        CaptureEvent item = Assert.Single(DriverEventCodec.DecodeBatch(bytes));

        Assert.Equal(0x0102030405060708, item.Sequence);
        Assert.Equal(-123456789, item.QpcTicks);
        Assert.Equal(0x8877665544332211UL, item.DeviceId);
        Assert.Equal(unchecked((int)0xF1234567), item.ProcessId);
        Assert.Equal(CaptureKind.Ioctl, item.Kind);
        Assert.Equal(0x00222000U, item.IoctlCode);
        Assert.Equal(unchecked((int)0xC0000001), item.NtStatus);
        Assert.Equal(128, item.RequestedLength);
        Assert.Equal(64, item.CompletedLength);
        Assert.Equal(CaptureFlags.Truncated | CaptureFlags.InputPayload, item.Flags);
        Assert.True(item.Payload.AsSpan().SequenceEqual(new byte[] { 0xA1, 0xB2 }));
    }

    [Fact]
    public void DecodeBatch_owns_an_immutable_payload()
    {
        byte[] bytes = CreateEvent(payload: [0xAA]);

        CaptureEvent item = Assert.Single(DriverEventCodec.DecodeBatch(bytes));
        bytes[DriverProtocol.HeaderSize] = 0xBB;

        Assert.IsType<ImmutableArray<byte>>(item.Payload);
        Assert.True(item.Payload.AsSpan().SequenceEqual(new byte[] { 0xAA }));
    }

    private static byte[] CreateEvent(
        ulong sequence = 7,
        long qpcTicks = 1234,
        ulong deviceId = 99,
        uint processId = 42,
        CaptureKind kind = CaptureKind.Write,
        uint ioctlCode = 0,
        int ntStatus = 0,
        uint requestedLength = 3,
        uint completedLength = 3,
        CaptureFlags flags = CaptureFlags.None,
        byte[]? payload = null)
    {
        payload ??= [0x01, 0x02, 0x03];
        byte[] bytes = new byte[DriverProtocol.HeaderSize + payload.Length];
        BinaryPrimitives.WriteUInt32LittleEndian(bytes, DriverProtocol.Magic);
        BinaryPrimitives.WriteUInt16LittleEndian(bytes.AsSpan(4), DriverProtocol.Version);
        BinaryPrimitives.WriteUInt16LittleEndian(bytes.AsSpan(6), DriverProtocol.HeaderSize);
        BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(8), (uint)bytes.Length);
        BinaryPrimitives.WriteUInt64LittleEndian(bytes.AsSpan(12), sequence);
        BinaryPrimitives.WriteInt64LittleEndian(bytes.AsSpan(20), qpcTicks);
        BinaryPrimitives.WriteUInt64LittleEndian(bytes.AsSpan(28), deviceId);
        BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(36), processId);
        BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(40), (uint)kind);
        BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(44), ioctlCode);
        BinaryPrimitives.WriteInt32LittleEndian(bytes.AsSpan(48), ntStatus);
        BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(52), requestedLength);
        BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(56), completedLength);
        BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(60), (uint)payload.Length);
        BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(64), (uint)flags);
        payload.CopyTo(bytes, DriverProtocol.HeaderSize);
        return bytes;
    }
}
