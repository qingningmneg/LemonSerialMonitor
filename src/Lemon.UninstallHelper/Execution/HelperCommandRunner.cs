using System.Security.Cryptography;
using Lemon.UninstallHelper.CommandLine;
using Lemon.UninstallHelper.Completion;
using Lemon.UninstallHelper.Manifest;
using Lemon.UninstallHelper.Security;

namespace Lemon.UninstallHelper.Execution;

public static class HelperExitCodes
{
    public const int Completed = 0;
    public const int InvalidArguments = 2;
    public const int Failed = 5;
    public const int RebootRequired = 3010;
}

public interface IProtectedStateBoundary
{
    byte[] ReadManifest(HelperCommand command);

    void WriteResult(HelperCommand command, byte[] result);
}

public interface IApprovedRootDeletionEngine
{
    DeletionReport Execute(ApprovedRootManifest root);
}

public sealed class SafeApprovedRootDeletionEngine : IApprovedRootDeletionEngine
{
    private readonly SafeOwnedTreeDelete _inner = new();

    public DeletionReport Execute(ApprovedRootManifest root) => _inner.Execute(root);
}

public sealed class HelperCommandRunner(
    IProtectedStateBoundary boundary,
    IApprovedRootDeletionEngine deletionEngine,
    TimeProvider timeProvider)
{
    private readonly IProtectedStateBoundary _boundary =
        boundary ?? throw new ArgumentNullException(nameof(boundary));
    private readonly IApprovedRootDeletionEngine _deletionEngine =
        deletionEngine ?? throw new ArgumentNullException(nameof(deletionEngine));
    private readonly TimeProvider _timeProvider =
        timeProvider ?? throw new ArgumentNullException(nameof(timeProvider));

    public int Run(HelperCommand command)
    {
        ArgumentNullException.ThrowIfNull(command);
        byte[] workBytes = _boundary.ReadManifest(command);
        using ValidatedUninstallWork work =
            UninstallWorkManifestCodec.ParseAndValidate(workBytes);
        string expectedInstallId = command.InstallId.ToString("D").ToLowerInvariant();
        if (!string.Equals(
                work.Payload.InstallId,
                expectedInstallId,
                StringComparison.Ordinal))
        {
            throw new CryptographicException(
                "The protected work manifest is bound to another installation.");
        }

        DeletionStatus aggregate = DeletionStatus.Completed;
        foreach (ApprovedRootManifest root in work.Payload.Roots)
        {
            try
            {
                DeletionStatus status = _deletionEngine.Execute(root).Status;
                aggregate = Merge(aggregate, status);
            }
            catch (Exception exception) when (
                exception is not (OutOfMemoryException or StackOverflowException or
                    AccessViolationException))
            {
                aggregate = DeletionStatus.Failed;
            }
        }

        CompletionStatus completionStatus = aggregate switch
        {
            DeletionStatus.Completed => CompletionStatus.Completed,
            DeletionStatus.PendingReboot => CompletionStatus.PendingReboot,
            _ => CompletionStatus.Failed,
        };
        CompletionToken token = CompletionTokenCodec.Create(
            command.InstallId,
            work.Payload.OwnershipManifestSha256,
            completionStatus,
            _timeProvider.GetUtcNow(),
            work.Key);
        _boundary.WriteResult(command, CompletionTokenCodec.GetStateFileBytes(token));
        return aggregate switch
        {
            DeletionStatus.Completed => HelperExitCodes.Completed,
            DeletionStatus.PendingReboot => HelperExitCodes.RebootRequired,
            _ => HelperExitCodes.Failed,
        };
    }

    private static DeletionStatus Merge(DeletionStatus left, DeletionStatus right)
    {
        if (left == DeletionStatus.Failed || right == DeletionStatus.Failed)
        {
            return DeletionStatus.Failed;
        }

        return left == DeletionStatus.PendingReboot ||
            right == DeletionStatus.PendingReboot
                ? DeletionStatus.PendingReboot
                : DeletionStatus.Completed;
    }
}
