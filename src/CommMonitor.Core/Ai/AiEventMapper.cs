using System.Globalization;
using CommMonitor.Core.Formatting;
using CommMonitor.Core.Models;

namespace CommMonitor.Core.Ai;

public static class AiEventMapper
{
    private static readonly (CaptureFlags Flag, string Name)[] StableFlags =
    [
        (CaptureFlags.Truncated, nameof(CaptureFlags.Truncated)),
        (CaptureFlags.InputPayload, nameof(CaptureFlags.InputPayload)),
        (CaptureFlags.OutputPayload, nameof(CaptureFlags.OutputPayload)),
        (CaptureFlags.Synthetic, nameof(CaptureFlags.Synthetic)),
    ];

    public static AiEventDto Map(CaptureEvent source, bool includeHex)
    {
        ArgumentNullException.ThrowIfNull(source);

        bool processNameAvailable = !string.IsNullOrWhiteSpace(source.ProcessName);
        ReadOnlySpan<byte> payload = source.Payload.AsSpan();
        return new AiEventDto(
            SchemaVersion: AiProtocol.Version,
            Sequence: source.Sequence.ToString(CultureInfo.InvariantCulture),
            WireSequence: source.WireSequence.ToString(CultureInfo.InvariantCulture),
            TimestampUtc: source.Timestamp.UtcDateTime.ToString("O", CultureInfo.InvariantCulture),
            QpcTicks: source.QpcTicks.ToString(CultureInfo.InvariantCulture),
            DeviceId: source.DeviceId.ToString("X16", CultureInfo.InvariantCulture),
            PortName: source.PortName,
            ProcessId: source.ProcessId,
            ProcessName: processNameAvailable ? source.ProcessName : string.Empty,
            ProcessNameStatus: processNameAvailable ? "available" : "unavailable",
            Kind: source.Kind.ToString(),
            IoctlCodeHex: $"0x{source.IoctlCode:X8}",
            NtStatusHex: $"0x{unchecked((uint)source.NtStatus):X8}",
            RequestedLength: source.RequestedLength,
            CompletedLength: source.CompletedLength,
            CapturedLength: payload.Length,
            Flags: MapFlags(source.Flags),
            PayloadBase64: Convert.ToBase64String(payload),
            PayloadHex: includeHex ? ByteFormatter.Format(payload, ByteFormat.HexSpaced) : null,
            TextPreview: null,
            Truncated: source.Flags.HasFlag(CaptureFlags.Truncated));
    }

    private static IReadOnlyList<string> MapFlags(CaptureFlags flags)
    {
        if (flags == CaptureFlags.None)
        {
            return [];
        }

        var names = new List<string>(StableFlags.Length);
        foreach ((CaptureFlags flag, string name) in StableFlags)
        {
            if ((flags & flag) != 0)
            {
                names.Add(name);
            }
        }

        return names;
    }
}
