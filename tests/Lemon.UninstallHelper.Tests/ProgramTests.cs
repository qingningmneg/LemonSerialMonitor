using Lemon.UninstallHelper.Execution;

namespace Lemon.UninstallHelper.Tests;

public sealed class ProgramTests
{
    [Fact]
    public void Invalid_command_line_returns_the_documented_argument_exit_code()
    {
        Assert.Equal(HelperExitCodes.InvalidArguments, Program.Main(["invalid"]));
    }
}
