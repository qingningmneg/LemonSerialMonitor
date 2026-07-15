using Lemon.UninstallHelper.CommandLine;

namespace Lemon.UninstallHelper.Tests;

public sealed class CommandLineTests
{
    [Fact]
    public void Parses_the_exact_verify_delete_command()
    {
        string manifest = Path.GetFullPath(@"C:\ProgramData\LemonSerialMonitor\Installer\state\uninstall-work.v1.json");
        string result = Path.GetFullPath(@"C:\ProgramData\LemonSerialMonitor\Installer\state\results\11111111-1111-1111-1111-111111111111.completion.v1.json");

        HelperCommand command = HelperCommandLine.Parse(
        [
            "verify-delete",
            "--manifest", manifest,
            "--install-id", "11111111-1111-1111-1111-111111111111",
            "--result", result,
        ]);

        Assert.Equal(manifest, command.ManifestPath);
        Assert.Equal(result, command.ResultPath);
        Assert.Equal(
            Guid.Parse("11111111-1111-1111-1111-111111111111"),
            command.InstallId);
    }

    [Fact]
    public void Accepts_each_required_flag_once_regardless_of_flag_order()
    {
        string manifest = Path.GetFullPath(@"C:\ProgramData\LemonSerialMonitor\Installer\state\uninstall-work.v1.json");
        string result = Path.GetFullPath(@"C:\ProgramData\LemonSerialMonitor\Installer\state\results\11111111-1111-1111-1111-111111111111.completion.v1.json");

        HelperCommand command = HelperCommandLine.Parse(
        [
            "verify-delete",
            "--result", result,
            "--manifest", manifest,
            "--install-id", "11111111-1111-1111-1111-111111111111",
        ]);

        Assert.Equal(result, command.ResultPath);
    }

    [Theory]
    [InlineData()]
    [InlineData("delete")]
    [InlineData("verify-delete", "--manifest", "x")]
    [InlineData("verify-delete", "--unknown", "x", "--manifest", "x", "--install-id", "11111111-1111-1111-1111-111111111111", "--result", "y")]
    [InlineData("verify-delete", "--manifest", "x", "--manifest", "x", "--install-id", "11111111-1111-1111-1111-111111111111", "--result", "y")]
    public void Rejects_missing_unknown_or_duplicate_command_parts(params string[] args)
    {
        Assert.Throws<ArgumentException>(() => HelperCommandLine.Parse(args));
    }

    [Theory]
    [InlineData("11111111-1111-1111-1111-11111111111A")]
    [InlineData("{11111111-1111-1111-1111-111111111111}")]
    [InlineData("not-a-guid")]
    public void Rejects_noncanonical_install_ids(string installId)
    {
        Assert.Throws<ArgumentException>(() => HelperCommandLine.Parse(
        [
            "verify-delete",
            "--manifest", @"C:\manifest.json",
            "--install-id", installId,
            "--result", @"C:\result.json",
        ]));
    }

    [Theory]
    [InlineData("manifest.json", @"C:\result.json")]
    [InlineData(@"C:\manifest.json", "result.json")]
    [InlineData(@"C:\same.json", @"C:\same.json")]
    public void Rejects_relative_or_aliasing_state_paths(string manifest, string result)
    {
        Assert.Throws<ArgumentException>(() => HelperCommandLine.Parse(
        [
            "verify-delete",
            "--manifest", manifest,
            "--install-id", "11111111-1111-1111-1111-111111111111",
            "--result", result,
        ]));
    }
}
