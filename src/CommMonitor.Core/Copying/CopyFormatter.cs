using System.Globalization;
using System.Text;
using System.Text.Json;
using CommMonitor.Core.Formatting;
using CommMonitor.Core.Models;

namespace CommMonitor.Core.Copying;

public static class CopyFormatter
{
    private const string CrLf = "\r\n";

    public static string Format(
        IReadOnlyList<CaptureEvent> events,
        CopyOptions options,
        Encoding encoding)
    {
        ArgumentNullException.ThrowIfNull(events);
        ArgumentNullException.ThrowIfNull(options);
        ArgumentNullException.ThrowIfNull(encoding);

        return options.Format switch
        {
            CopyFormat.HexSpaced => ByteFormatter.Format(CombinePayloads(events), ByteFormat.HexSpaced),
            CopyFormat.HexCompact => ByteFormatter.Format(CombinePayloads(events), ByteFormat.HexCompact),
            CopyFormat.Text => encoding.GetString(CombinePayloads(events)),
            CopyFormat.CArray => ByteFormatter.Format(CombinePayloads(events), ByteFormat.CArray),
            CopyFormat.PythonBytes => ByteFormatter.Format(CombinePayloads(events), ByteFormat.PythonBytes),
            CopyFormat.Tsv => FormatDelimited(events, options, '\t'),
            CopyFormat.Csv => FormatDelimited(events, options, ','),
            CopyFormat.Json => FormatJson(events, options),
            _ => throw new ArgumentOutOfRangeException(nameof(options), options.Format, "Unknown copy format."),
        };
    }

    private static byte[] CombinePayloads(IReadOnlyList<CaptureEvent> events)
    {
        int length = 0;
        foreach (CaptureEvent captureEvent in events)
        {
            ArgumentNullException.ThrowIfNull(captureEvent);
            length = checked(length + captureEvent.Payload.Length);
        }

        byte[] combined = new byte[length];
        int offset = 0;
        foreach (CaptureEvent captureEvent in events)
        {
            ReadOnlySpan<byte> payload = captureEvent.Payload.AsSpan();
            payload.CopyTo(combined.AsSpan(offset));
            offset += payload.Length;
        }

        return combined;
    }

    private static string FormatDelimited(
        IReadOnlyList<CaptureEvent> events,
        CopyOptions options,
        char delimiter)
    {
        List<string> headers = GetHeaders(options);
        var result = new StringBuilder();
        AppendDelimitedRow(result, headers, delimiter);

        foreach (CaptureEvent captureEvent in events)
        {
            ArgumentNullException.ThrowIfNull(captureEvent);
            AppendDelimitedRow(result, GetValues(captureEvent, options), delimiter);
        }

        return result.ToString();
    }

    private static void AppendDelimitedRow(StringBuilder result, IReadOnlyList<string> fields, char delimiter)
    {
        for (int index = 0; index < fields.Count; index++)
        {
            if (index > 0)
            {
                result.Append(delimiter);
            }

            string field = fields[index];
            result.Append(delimiter == ',' ? EscapeCsv(field) : field);
        }

        result.Append(CrLf);
    }

    private static string EscapeCsv(string value)
    {
        if (!value.Contains(',') &&
            !value.Contains('"') &&
            !value.Contains('\r') &&
            !value.Contains('\n'))
        {
            return value;
        }

        return $"\"{value.Replace("\"", "\"\"")}\"";
    }

    private static string FormatJson(IReadOnlyList<CaptureEvent> events, CopyOptions options)
    {
        var rows = new List<Dictionary<string, object?>>(events.Count);
        foreach (CaptureEvent captureEvent in events)
        {
            ArgumentNullException.ThrowIfNull(captureEvent);
            var row = new Dictionary<string, object?>();
            if (options.IncludeSequence)
            {
                row.Add("sequence", captureEvent.Sequence);
            }

            if (options.IncludeTimestamp)
            {
                row.Add("timestamp", FormatTimestamp(captureEvent.Timestamp));
            }

            if (options.IncludePort)
            {
                row.Add("port", captureEvent.PortName);
            }

            if (options.IncludeDirection)
            {
                row.Add("direction", FormatDirection(captureEvent.Kind));
            }

            if (options.IncludeProcess)
            {
                row.Add("process", FormatProcess(captureEvent));
            }

            row.Add("data", ByteFormatter.Format(captureEvent.Payload.AsSpan(), ByteFormat.HexSpaced));
            rows.Add(row);
        }

        return JsonSerializer.Serialize(rows);
    }

    private static List<string> GetHeaders(CopyOptions options)
    {
        var headers = new List<string>(6);
        if (options.IncludeSequence)
        {
            headers.Add("Sequence");
        }

        if (options.IncludeTimestamp)
        {
            headers.Add("Timestamp");
        }

        if (options.IncludePort)
        {
            headers.Add("Port");
        }

        if (options.IncludeDirection)
        {
            headers.Add("Direction");
        }

        if (options.IncludeProcess)
        {
            headers.Add("Process");
        }

        headers.Add("Data");
        return headers;
    }

    private static List<string> GetValues(CaptureEvent captureEvent, CopyOptions options)
    {
        var values = new List<string>(6);
        if (options.IncludeSequence)
        {
            values.Add(captureEvent.Sequence.ToString(CultureInfo.InvariantCulture));
        }

        if (options.IncludeTimestamp)
        {
            values.Add(FormatTimestamp(captureEvent.Timestamp));
        }

        if (options.IncludePort)
        {
            values.Add(captureEvent.PortName);
        }

        if (options.IncludeDirection)
        {
            values.Add(FormatDirection(captureEvent.Kind));
        }

        if (options.IncludeProcess)
        {
            values.Add(FormatProcess(captureEvent));
        }

        values.Add(ByteFormatter.Format(captureEvent.Payload.AsSpan(), ByteFormat.HexSpaced));
        return values;
    }

    private static string FormatTimestamp(DateTimeOffset timestamp) =>
        timestamp.ToString("O", CultureInfo.InvariantCulture);

    private static string FormatDirection(CaptureKind kind) => kind switch
    {
        CaptureKind.Read => "RX",
        CaptureKind.Write => "TX",
        _ => kind.ToString(),
    };

    private static string FormatProcess(CaptureEvent captureEvent)
    {
        string processId = captureEvent.ProcessId.ToString(CultureInfo.InvariantCulture);
        return string.IsNullOrWhiteSpace(captureEvent.ProcessName)
            ? processId
            : $"{captureEvent.ProcessName} ({processId})";
    }
}
