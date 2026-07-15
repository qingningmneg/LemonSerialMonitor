using System.Text;
using Lemon.UninstallHelper.CommandLine;

namespace Lemon.UninstallHelper.Tests;

public sealed class PrepareWorkCommandLineTests
{
    [Fact]
    public void Parses_exact_prepare_work_arguments_and_optional_root_sentinel()
    {
        string appRoot = Path.GetFullPath(@"C:\Program Files\Lemon 串口");
        string encoded = Convert.ToBase64String(Encoding.UTF8.GetBytes(appRoot));

        PrepareWorkCommand command = PrepareWorkCommandLine.Parse(
        [
            "prepare-work",
            "--install-id", "11111111-1111-1111-1111-111111111111",
            "--ownership-sha256", new string('a', 64),
            "--app-root-base64", encoded,
            "--ai-root-base64", "-",
        ]);

        Assert.Equal(appRoot, command.AppRoot);
        Assert.Null(command.AiStateRoot);
    }

    [Theory]
    [InlineData("prepare-work")]
    [InlineData("prepare-work", "--install-id", "bad", "--ownership-sha256", "bad", "--app-root-base64", "-", "--ai-root-base64", "-")]
    [InlineData("prepare-work", "--install-id", "11111111-1111-1111-1111-111111111111", "--ownership-sha256", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "--app-root-base64", "-", "--ai-root-base64", "-")]
    public void Rejects_incomplete_invalid_or_rootless_requests(params string[] args)
    {
        Assert.Throws<ArgumentException>(() => PrepareWorkCommandLine.Parse(args));
    }
}
