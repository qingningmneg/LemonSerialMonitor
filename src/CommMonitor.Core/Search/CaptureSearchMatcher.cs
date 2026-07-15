using System.Globalization;
using CommMonitor.Core.Models;

namespace CommMonitor.Core.Search;

public static class CaptureSearchMatcher
{
    public static bool IsMatch(
        CaptureEvent captureEvent,
        string hexPattern,
        out string? validationError)
    {
        ArgumentNullException.ThrowIfNull(captureEvent);
        return IsMatch(captureEvent.Payload.AsSpan(), hexPattern, out validationError);
    }

    public static bool IsMatch(
        ReadOnlySpan<byte> payload,
        string hexPattern,
        out string? validationError)
    {
        if (!TryParse(hexPattern, out byte?[] pattern, out validationError))
        {
            return false;
        }

        if (pattern.Length > payload.Length)
        {
            return false;
        }

        for (int start = 0; start <= payload.Length - pattern.Length; start++)
        {
            bool matched = true;
            for (int offset = 0; offset < pattern.Length; offset++)
            {
                byte? expected = pattern[offset];
                if (expected.HasValue && expected.Value != payload[start + offset])
                {
                    matched = false;
                    break;
                }
            }

            if (matched)
            {
                return true;
            }
        }

        return false;
    }

    private static bool TryParse(
        string? hexPattern,
        out byte?[] pattern,
        out string? validationError)
    {
        if (string.IsNullOrWhiteSpace(hexPattern))
        {
            pattern = [];
            validationError = "HEX pattern cannot be empty.";
            return false;
        }

        string[] tokens = hexPattern.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        pattern = new byte?[tokens.Length];
        for (int index = 0; index < tokens.Length; index++)
        {
            string token = tokens[index];
            if (token == "??")
            {
                continue;
            }

            if (token.Length != 2 ||
                !byte.TryParse(token, NumberStyles.AllowHexSpecifier, CultureInfo.InvariantCulture, out byte value))
            {
                pattern = [];
                validationError = $"Invalid HEX token '{token}'. Use 00-FF or ??.";
                return false;
            }

            pattern[index] = value;
        }

        validationError = null;
        return true;
    }
}
