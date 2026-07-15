using System.Globalization;
using System.Text;

namespace CommMonitor.Core.Formatting;

public enum ByteFormat
{
    HexSpaced,
    HexCompact,
    Decimal,
    Octal,
    Binary,
    CArray,
    PythonBytes,
}

public static class ByteFormatter
{
    public static string Format(ReadOnlySpan<byte> data, ByteFormat format)
    {
        if (data.IsEmpty)
        {
            return string.Empty;
        }

        return format switch
        {
            ByteFormat.HexSpaced => FormatHexSpaced(data),
            ByteFormat.HexCompact => Convert.ToHexString(data),
            ByteFormat.Decimal => FormatRadix(data, static value => value.ToString(CultureInfo.InvariantCulture)),
            ByteFormat.Octal => FormatRadix(data, static value => Convert.ToString(value, 8).PadLeft(3, '0')),
            ByteFormat.Binary => FormatRadix(data, static value => Convert.ToString(value, 2).PadLeft(8, '0')),
            ByteFormat.CArray => FormatCArray(data),
            ByteFormat.PythonBytes => FormatPythonBytes(data),
            _ => throw new ArgumentOutOfRangeException(nameof(format), format, "Unknown byte format."),
        };
    }

    private static string FormatHexSpaced(ReadOnlySpan<byte> data)
    {
        string compact = Convert.ToHexString(data);
        var result = new StringBuilder((data.Length * 3) - 1);
        for (int index = 0; index < data.Length; index++)
        {
            if (index > 0)
            {
                result.Append(' ');
            }

            result.Append(compact, index * 2, 2);
        }

        return result.ToString();
    }

    private static string FormatRadix(ReadOnlySpan<byte> data, Func<byte, string> formatter)
    {
        var result = new StringBuilder();
        for (int index = 0; index < data.Length; index++)
        {
            if (index > 0)
            {
                result.Append(' ');
            }

            result.Append(formatter(data[index]));
        }

        return result.ToString();
    }

    private static string FormatCArray(ReadOnlySpan<byte> data)
    {
        var result = new StringBuilder("new byte[] { ");
        for (int index = 0; index < data.Length; index++)
        {
            if (index > 0)
            {
                result.Append(", ");
            }

            result.Append("0x");
            result.Append(data[index].ToString("X2", CultureInfo.InvariantCulture));
        }

        return result.Append(" }").ToString();
    }

    private static string FormatPythonBytes(ReadOnlySpan<byte> data)
    {
        var result = new StringBuilder((data.Length * 4) + 3);
        result.Append("b'");
        foreach (byte value in data)
        {
            result.Append("\\x");
            result.Append(value.ToString("x2", CultureInfo.InvariantCulture));
        }

        return result.Append('\'').ToString();
    }
}
