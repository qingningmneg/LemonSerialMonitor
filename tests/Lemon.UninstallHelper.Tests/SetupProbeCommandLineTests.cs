using System.Text;
using Lemon.UninstallHelper.CommandLine;

namespace Lemon.UninstallHelper.Tests;

public sealed class SetupProbeCommandLineTests
{
    [Fact]
    public void Parses_an_exact_base64_encoded_path_probe_command()
    {
        string path = Path.GetFullPath(@"C:\Program Files\Lemon 串口");
        string encoded = Convert.ToBase64String(Encoding.UTF8.GetBytes(path));

        PathProbeCommand command = SetupProbeCommandLine.Parse(
            ["probe-path", "--path-base64", encoded]);

        Assert.Equal(path, command.Path);
    }

    [Theory]
    [InlineData("probe-path")]
    [InlineData("probe-path", "--path", "QzpcVGVzdA==")]
    [InlineData("probe-path", "--path-base64", "not-base64")]
    [InlineData("probe-path", "--path-base64", "AA==")]
    public void Rejects_missing_unknown_or_invalid_probe_arguments(params string[] args)
    {
        Assert.Throws<ArgumentException>(() => SetupProbeCommandLine.Parse(args));
    }
}
