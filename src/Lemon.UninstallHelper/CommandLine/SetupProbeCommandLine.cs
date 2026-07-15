using System.Text;

namespace Lemon.UninstallHelper.CommandLine;

public sealed record PathProbeCommand(string Path);

public static class SetupProbeCommandLine
{
    private static readonly UTF8Encoding StrictUtf8 =
        new(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true);

    public static PathProbeCommand Parse(string[] args)
    {
        ArgumentNullException.ThrowIfNull(args);
        if (args.Length != 3 ||
            !string.Equals(args[0], "probe-path", StringComparison.Ordinal) ||
            !string.Equals(args[1], "--path-base64", StringComparison.Ordinal) ||
            string.IsNullOrWhiteSpace(args[2]))
        {
            throw new ArgumentException(
                "Expected probe-path and one base64-encoded path.", nameof(args));
        }

        try
        {
            byte[] bytes = Convert.FromBase64String(args[2]);
            string path = StrictUtf8.GetString(bytes);
            if (string.IsNullOrWhiteSpace(path) || path.Contains('\0'))
            {
                throw new ArgumentException("The decoded probe path is invalid.", nameof(args));
            }

            return new PathProbeCommand(path);
        }
        catch (Exception exception) when (
            exception is FormatException or DecoderFallbackException)
        {
            throw new ArgumentException(
                "The probe path is not strict UTF-8 base64.", nameof(args), exception);
        }
    }
}
