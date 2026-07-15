using Lemon.UninstallHelper.CommandLine;
using Lemon.UninstallHelper.Execution;

namespace Lemon.UninstallHelper;

public static class Program
{
    public static int Main(string[] args)
    {
        if (args.Length > 0 &&
            string.Equals(args[0], "probe-path", StringComparison.Ordinal))
        {
            return RunPathProbe(args);
        }
        if (args.Length > 0 &&
            string.Equals(args[0], "prepare-work", StringComparison.Ordinal))
        {
            return RunPrepareWork(args);
        }

        HelperCommand command;
        try
        {
            command = HelperCommandLine.Parse(args);
        }
        catch (Exception exception) when (
            exception is ArgumentException or IOException or
                NotSupportedException or UnauthorizedAccessException)
        {
            Console.Error.WriteLine("The uninstall-helper command line is invalid.");
            return HelperExitCodes.InvalidArguments;
        }

        try
        {
            var runner = new HelperCommandRunner(
                new WindowsProtectedStateBoundary(),
                new SafeApprovedRootDeletionEngine(),
                TimeProvider.System);
            return runner.Run(command);
        }
        catch (Exception)
        {
            Console.Error.WriteLine("The protected uninstall operation failed.");
            return HelperExitCodes.Failed;
        }
    }

    private static int RunPathProbe(string[] args)
    {
        PathProbeCommand command;
        try
        {
            command = SetupProbeCommandLine.Parse(args);
        }
        catch (ArgumentException)
        {
            Console.Error.WriteLine("The setup-probe command line is invalid.");
            return HelperExitCodes.InvalidArguments;
        }

        try
        {
            Console.Out.WriteLine(SetupProbeRunner.CapturePathJson(command.Path));
            return HelperExitCodes.Completed;
        }
        catch (Exception exception) when (
            exception is ArgumentException or IOException or
                NotSupportedException or UnauthorizedAccessException)
        {
            Console.Error.WriteLine("The protected setup path probe failed.");
            return HelperExitCodes.Failed;
        }
    }

    private static int RunPrepareWork(string[] args)
    {
        PrepareWorkCommand command;
        try
        {
            command = PrepareWorkCommandLine.Parse(args);
        }
        catch (ArgumentException)
        {
            Console.Error.WriteLine("The prepare-work command line is invalid.");
            return HelperExitCodes.InvalidArguments;
        }

        try
        {
            byte[] work = Manifest.UninstallWorkBuilder.Build(
                command.InstallId,
                command.OwnershipManifestSha256,
                command.AppRoot,
                command.AiStateRoot);
            Console.Out.WriteLine(Convert.ToBase64String(work));
            return HelperExitCodes.Completed;
        }
        catch (Exception exception) when (
            exception is ArgumentException or IOException or
                NotSupportedException or UnauthorizedAccessException or
                System.Security.Cryptography.CryptographicException)
        {
            Console.Error.WriteLine("The protected uninstall work preparation failed.");
            return HelperExitCodes.Failed;
        }
    }
}
