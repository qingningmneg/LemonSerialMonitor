namespace Lemon.UninstallHelper.CommandLine;

public sealed record HelperCommand(
    string ManifestPath,
    Guid InstallId,
    string ResultPath);

public static class HelperCommandLine
{
    private static readonly HashSet<string> AllowedFlags = new(
        ["--manifest", "--install-id", "--result"],
        StringComparer.Ordinal);

    public static HelperCommand Parse(string[] args)
    {
        ArgumentNullException.ThrowIfNull(args);
        if (args.Length != 7 ||
            !string.Equals(args[0], "verify-delete", StringComparison.Ordinal))
        {
            throw new ArgumentException(
                "Expected verify-delete and exactly three required flag/value pairs.",
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
                    "Command flags must be known, unique, and have nonempty values.",
                    nameof(args));
            }
        }

        if (values.Count != AllowedFlags.Count ||
            !values.Keys.All(AllowedFlags.Contains))
        {
            throw new ArgumentException("Every required command flag must appear once.", nameof(args));
        }

        string installIdText = values["--install-id"];
        Guid installId = Guid.Empty;
        if (!Guid.TryParseExact(installIdText, "D", out installId) ||
            !string.Equals(
                installIdText,
                installId.ToString("D").ToLowerInvariant(),
                StringComparison.Ordinal))
        {
            throw new ArgumentException("Install ID must be a canonical lowercase GUID.", nameof(args));
        }

        string manifestPath = ValidateAbsoluteLocalPath(values["--manifest"], "manifest");
        string resultPath = ValidateAbsoluteLocalPath(values["--result"], "result");
        if (string.Equals(manifestPath, resultPath, StringComparison.OrdinalIgnoreCase))
        {
            throw new ArgumentException("Manifest and result paths must be distinct.", nameof(args));
        }

        return new HelperCommand(manifestPath, installId, resultPath);
    }

    private static string ValidateAbsoluteLocalPath(string path, string subject)
    {
        if (!Path.IsPathFullyQualified(path) ||
            path.StartsWith(@"\\", StringComparison.Ordinal) ||
            path.StartsWith(@"\\?\", StringComparison.OrdinalIgnoreCase) ||
            path.StartsWith(@"\\.\", StringComparison.OrdinalIgnoreCase))
        {
            throw new ArgumentException($"The {subject} path must be fully qualified and local.");
        }

        string canonical = Path.TrimEndingDirectorySeparator(Path.GetFullPath(path));
        string? root = Path.GetPathRoot(canonical);
        if (root is null || new DriveInfo(root).DriveType != DriveType.Fixed)
        {
            throw new ArgumentException($"The {subject} path must use a fixed local drive.");
        }

        return canonical;
    }
}
