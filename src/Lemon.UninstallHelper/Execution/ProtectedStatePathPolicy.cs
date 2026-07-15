using Lemon.UninstallHelper.CommandLine;
using Lemon.UninstallHelper.Security;

namespace Lemon.UninstallHelper.Execution;

public static class ProtectedStatePathPolicy
{
    public static void Validate(HelperCommand command, string installerRoot)
    {
        ArgumentNullException.ThrowIfNull(command);
        ArgumentException.ThrowIfNullOrWhiteSpace(installerRoot);
        string root = PathIdentity.NormalizePath(installerRoot);
        string expectedManifest = PathIdentity.NormalizePath(
            Path.Combine(root, "state", "uninstall-work.v1.json"));
        string expectedResult = PathIdentity.NormalizePath(Path.Combine(
            root,
            "state",
            "results",
            $"{command.InstallId:D}.completion.v1.json"));
        if (!PathIdentity.PathsEqual(command.ManifestPath, expectedManifest) ||
            !PathIdentity.PathsEqual(command.ResultPath, expectedResult))
        {
            throw new UnauthorizedAccessException(
                "Helper state paths are outside the fixed protected boundary.");
        }
    }
}
