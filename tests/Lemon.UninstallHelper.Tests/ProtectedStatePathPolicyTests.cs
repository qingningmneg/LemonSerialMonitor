using Lemon.UninstallHelper.CommandLine;
using Lemon.UninstallHelper.Execution;

namespace Lemon.UninstallHelper.Tests;

public sealed class ProtectedStatePathPolicyTests
{
    private const string InstallerRoot =
        @"C:\ProgramData\LemonSerialMonitor\Installer";
    private static readonly Guid InstallId =
        Guid.Parse("11111111-1111-1111-1111-111111111111");

    [Fact]
    public void Accepts_only_the_fixed_manifest_and_install_bound_result_paths()
    {
        HelperCommand command = Command(
            InstallerRoot + @"\state\uninstall-work.v1.json",
            InstallerRoot + @"\state\results\11111111-1111-1111-1111-111111111111.completion.v1.json");

        ProtectedStatePathPolicy.Validate(command, InstallerRoot);
    }

    [Theory]
    [InlineData(@"C:\ProgramData\LemonSerialMonitor\Installer\state\other.json", @"C:\ProgramData\LemonSerialMonitor\Installer\state\results\11111111-1111-1111-1111-111111111111.completion.v1.json")]
    [InlineData(@"C:\ProgramData\LemonSerialMonitor\Installer\state\uninstall-work.v1.json:stream", @"C:\ProgramData\LemonSerialMonitor\Installer\state\results\11111111-1111-1111-1111-111111111111.completion.v1.json")]
    [InlineData(@"C:\ProgramData\LemonSerialMonitor\Installer\state\uninstall-work.v1.json", @"C:\ProgramData\LemonSerialMonitor\Installer\state\results\22222222-2222-2222-2222-222222222222.completion.v1.json")]
    [InlineData(@"C:\ProgramData\LemonSerialMonitor\Installer\state\uninstall-work.v1.json", @"C:\Temp\11111111-1111-1111-1111-111111111111.completion.v1.json")]
    public void Rejects_siblings_streams_another_install_and_external_results(
        string manifest,
        string result)
    {
        Assert.Throws<UnauthorizedAccessException>(() =>
            ProtectedStatePathPolicy.Validate(Command(manifest, result), InstallerRoot));
    }

    private static HelperCommand Command(string manifest, string result) =>
        new(Path.GetFullPath(manifest), InstallId, Path.GetFullPath(result));
}
