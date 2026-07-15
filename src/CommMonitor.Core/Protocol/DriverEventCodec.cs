using System.Buffers.Binary;
using System.Collections.Immutable;
using CommMonitor.Core.Models;

namespace CommMonitor.Core.Protocol;

public static class DriverEventCodec
{
    public static IReadOnlyList<CaptureEvent> DecodeBatch(ReadOnlySpan<byte> bytes)
    {
        if (bytes.Length > DriverProtocol.MaxBatchBytes)
        {
            throw new InvalidDataException("Capture batch exceeds the maximum size.");
        }

        List<CaptureEvent> events = [];
        int offset = 0;

        while (offset < bytes.Length)
        {
            int remaining = bytes.Length - offset;
            if (remaining < DriverProtocol.HeaderSize)
            {
                throw new InvalidDataException("Capture batch contains trailing bytes.");
            }

            ReadOnlySpan<byte> header = bytes.Slice(offset, DriverProtocol.HeaderSize);

            if (BinaryPrimitives.ReadUInt32LittleEndian(header) != DriverProtocol.Magic)
            {
                throw new InvalidDataException("Capture event has an invalid magic value.");
            }

            if (BinaryPrimitives.ReadUInt16LittleEndian(header.Slice(4, sizeof(ushort))) != DriverProtocol.Version)
            {
                throw new InvalidDataException("Capture event has an unsupported version.");
            }

            if (BinaryPrimitives.ReadUInt16LittleEndian(header.Slice(6, sizeof(ushort))) != DriverProtocol.HeaderSize)
            {
                throw new InvalidDataException("Capture event has an invalid header size.");
            }

            uint totalSize = BinaryPrimitives.ReadUInt32LittleEndian(header.Slice(8, sizeof(uint)));
            if (totalSize < DriverProtocol.HeaderSize || totalSize > remaining)
            {
                throw new InvalidDataException("Capture event has an invalid total size.");
            }

            uint payloadLength = BinaryPrimitives.ReadUInt32LittleEndian(header.Slice(60, sizeof(uint)));
            if (payloadLength > DriverProtocol.MaxPayload || totalSize != DriverProtocol.HeaderSize + payloadLength)
            {
                throw new InvalidDataException("Capture event has an invalid payload size.");
            }

            int eventSize = checked((int)totalSize);
            int payloadSize = checked((int)payloadLength);
            if (payloadSize > eventSize - DriverProtocol.HeaderSize)
            {
                throw new InvalidDataException("Capture event payload exceeds its frame.");
            }

            ReadOnlySpan<byte> payload = bytes.Slice(offset + DriverProtocol.HeaderSize, payloadSize);
            events.Add(new CaptureEvent(
                unchecked((long)BinaryPrimitives.ReadUInt64LittleEndian(header.Slice(12, sizeof(ulong)))),
                BinaryPrimitives.ReadInt64LittleEndian(header.Slice(20, sizeof(long))),
                BinaryPrimitives.ReadUInt64LittleEndian(header.Slice(28, sizeof(ulong))),
                unchecked((int)BinaryPrimitives.ReadUInt32LittleEndian(header.Slice(36, sizeof(uint)))),
                (CaptureKind)BinaryPrimitives.ReadUInt32LittleEndian(header.Slice(40, sizeof(uint))),
                BinaryPrimitives.ReadUInt32LittleEndian(header.Slice(44, sizeof(uint))),
                BinaryPrimitives.ReadInt32LittleEndian(header.Slice(48, sizeof(int))),
                unchecked((int)BinaryPrimitives.ReadUInt32LittleEndian(header.Slice(52, sizeof(uint)))),
                unchecked((int)BinaryPrimitives.ReadUInt32LittleEndian(header.Slice(56, sizeof(uint)))),
                (CaptureFlags)BinaryPrimitives.ReadUInt32LittleEndian(header.Slice(64, sizeof(uint))),
                ImmutableArray.CreateRange(payload.ToArray())));

            offset += eventSize;
        }

        return events;
    }
}
