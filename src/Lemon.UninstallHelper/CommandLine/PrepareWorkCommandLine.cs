using System.Text;
using System.Text.RegularExpressions;

namespace Lemon.UninstallHelper.CommandLine;

public sealed record PrepareWorkCommand(
    string InstallId,
    string OwnershipManifestSha256,
    string? AppRoot,
    string? AiStateRoot);

public static class PrepareWorkCommandLine
{
    private static readonly UTF8Encoding StrictUtf8 =
        new(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true);
    private static readonly Regex LowerSha256 = new(
        "^[0-9a-f]{64}$",
        RegexOptions.CultureInvariant);
    private static readonly HashSet<string> AllowedFlags = new(
        [
            "--install-id",
            "--ownership-sha256",
            "--app-root-base64",
            "--ai-root-base64",
        ],
        StringComparer.Ordinal);

    public static PrepareWorkCommand Parse(string[] args)
    {
        ArgumentNullException.ThrowIfNull(args);
        if (args.Length != 9 ||
            !string.Equals(args[0], "prepare-work", StringComparison.Ordinal))
        {
            throw new ArgumentException(
                "Expected prepare-work and four required flag/value pairs.",
                nameof(args));
        }

        var values = new Dictionary<string, string>(StringComparer.Ordinal);
        for (int index = 1; index < args.Length; index += 2)
        {
            string flag = args[index];
            string value = args[index + 1];
            if (!AllowedFlags.Contains(flag) || string.IsNullOrWhiteSpace(value) ||
                !values.TryAdd(flag, value))
            {
                throw new ArgumentException(
                    "Prepare-work flags must be known, unique, and nonempty.",
                    nameof(args));
            }
        }

        string installIdText = values["--install-id"];
        if (!Guid.TryParseExact(installIdText, "D", out Guid installId) ||
            !string.Equals(
                installIdText,
                installId.ToString("D").ToLowerInvariant(),
                StringComparison.Ordinal) ||
            !LowerSha256.IsMatch(values["--ownership-sha256"]))
        {
            throw new ArgumentException(
                "Prepare-work installation identity is noncanonical.", nameof(args));
        }

        string? appRoot = DecodeOptionalPath(values["--app-root-base64"]);
        string? aiRoot = DecodeOptionalPath(values["--ai-root-base64"]);
        if (appRoot is null && aiRoot is null)
        {
            throw new ArgumentException(
                "Prepare-work requires at least one owned root.", nameof(args));
        }

        return new PrepareWorkCommand(
            installIdText,
            values["--ownership-sha256"],
            appRoot,
            aiRoot);
    }

    private static string? DecodeOptionalPath(string value)
    {
        if (string.Equals(value, "-", StringComparison.Ordinal))
        {
            return null;
        }

        try
        {
            string path = StrictUtf8.GetString(Convert.FromBase64String(value));
            if (string.IsNullOrWhiteSpace(path) || path.Contains('\0'))
            {
                throw new ArgumentException("The decoded owned-root path is invalid.");
            }

            return path;
        }
        catch (Exception exception) when (
            exception is FormatException or DecoderFallbackException)
        {
            throw new ArgumentException(
                "An owned-root path is not strict UTF-8 base64.", nameof(value), exception);
        }
    }
}
