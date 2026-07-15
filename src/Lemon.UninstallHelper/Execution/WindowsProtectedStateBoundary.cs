using System.Security.AccessControl;
using System.Security.Principal;
using System.Runtime.Versioning;
using Lemon.UninstallHelper.CommandLine;
using Lemon.UninstallHelper.Security;
using Microsoft.Win32.SafeHandles;

namespace Lemon.UninstallHelper.Execution;

public interface IProtectedStateAclPolicy
{
    void VerifyDirectory(string path);

    void VerifyFile(string path);

    void ProtectFile(string path);
}

[SupportedOSPlatform("windows")]
public static class ProtectedStateAclValidator
{
    private static readonly SecurityIdentifier SystemSid =
        new(WellKnownSidType.LocalSystemSid, domainSid: null);
    private static readonly SecurityIdentifier AdministratorsSid =
        new(WellKnownSidType.BuiltinAdministratorsSid, domainSid: null);
    private static readonly HashSet<SecurityIdentifier> TrustedIdentities =
        [SystemSid, AdministratorsSid];

    public static void Validate(FileSystemSecurity security)
    {
        ArgumentNullException.ThrowIfNull(security);
        SecurityIdentifier? owner =
            security.GetOwner(typeof(SecurityIdentifier)) as SecurityIdentifier;
        if (!security.AreAccessRulesProtected || owner is null ||
            !TrustedIdentities.Contains(owner))
        {
            throw new UnauthorizedAccessException(
                "Protected helper state has an untrusted owner or inherited ACL.");
        }

        FileSystemAccessRule[] rules = security.GetAccessRules(
                includeExplicit: true,
                includeInherited: true,
                typeof(SecurityIdentifier))
            .Cast<FileSystemAccessRule>()
            .ToArray();
        foreach (FileSystemAccessRule rule in rules)
        {
            if (rule.AccessControlType != AccessControlType.Allow ||
                rule.IdentityReference is not SecurityIdentifier identity ||
                !TrustedIdentities.Contains(identity) ||
                (rule.FileSystemRights & FileSystemRights.FullControl) !=
                    FileSystemRights.FullControl)
            {
                throw new UnauthorizedAccessException(
                    "Protected helper state grants access outside SYSTEM and Administrators.");
            }
        }

        foreach (SecurityIdentifier identity in TrustedIdentities)
        {
            if (!rules.Any(rule =>
                    rule.AccessControlType == AccessControlType.Allow &&
                    identity.Equals(rule.IdentityReference) &&
                    (rule.FileSystemRights & FileSystemRights.FullControl) ==
                        FileSystemRights.FullControl))
            {
                throw new UnauthorizedAccessException(
                    "Protected helper state is missing a required trusted ACL entry.");
            }
        }
    }
}

[SupportedOSPlatform("windows")]
public sealed class WindowsProtectedStateAclPolicy : IProtectedStateAclPolicy
{
    private static readonly SecurityIdentifier SystemSid =
        new(WellKnownSidType.LocalSystemSid, domainSid: null);
    private static readonly SecurityIdentifier AdministratorsSid =
        new(WellKnownSidType.BuiltinAdministratorsSid, domainSid: null);
    private static readonly HashSet<SecurityIdentifier> TrustedIdentities =
        [SystemSid, AdministratorsSid];

    public void VerifyDirectory(string path) => ProtectedStateAclValidator.Validate(
        new DirectoryInfo(path).GetAccessControl(
            AccessControlSections.Access | AccessControlSections.Owner));

    public void VerifyFile(string path) => ProtectedStateAclValidator.Validate(
        new FileInfo(path).GetAccessControl(
            AccessControlSections.Access | AccessControlSections.Owner));

    public void ProtectFile(string path)
    {
        var security = new FileSecurity();
        security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        security.SetOwner(AdministratorsSid);
        foreach (SecurityIdentifier identity in TrustedIdentities)
        {
            security.AddAccessRule(new FileSystemAccessRule(
                identity,
                FileSystemRights.FullControl,
                InheritanceFlags.None,
                PropagationFlags.None,
                AccessControlType.Allow));
        }

        new FileInfo(path).SetAccessControl(security);
        VerifyFile(path);
    }
}

[SupportedOSPlatform("windows")]
public sealed class WindowsProtectedStateBoundary : IProtectedStateBoundary
{
    public const int MaximumStateBytes = 4 * 1024 * 1024;

    private readonly string _installerRoot;
    private readonly IProtectedStateAclPolicy _aclPolicy;

    public WindowsProtectedStateBoundary()
        : this(GetDefaultInstallerRoot(), new WindowsProtectedStateAclPolicy())
    {
    }

    public WindowsProtectedStateBoundary(
        string installerRoot,
        IProtectedStateAclPolicy aclPolicy)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(installerRoot);
        _aclPolicy = aclPolicy ?? throw new ArgumentNullException(nameof(aclPolicy));
        _installerRoot = PathIdentity.NormalizePath(installerRoot);
        if (!Path.IsPathFullyQualified(_installerRoot) ||
            _installerRoot.StartsWith(@"\\", StringComparison.Ordinal) ||
            _installerRoot.StartsWith(@"\\?\", StringComparison.OrdinalIgnoreCase) ||
            _installerRoot.StartsWith(@"\\.\", StringComparison.OrdinalIgnoreCase))
        {
            throw new ArgumentException(
                "Installer state root must be a fully qualified local path.",
                nameof(installerRoot));
        }

        string? driveRoot = Path.GetPathRoot(_installerRoot);
        if (driveRoot is null || new DriveInfo(driveRoot).DriveType != DriveType.Fixed)
        {
            throw new ArgumentException(
                "Installer state root must use a fixed local drive.",
                nameof(installerRoot));
        }
    }

    public byte[] ReadManifest(HelperCommand command)
    {
        ProtectedStatePathPolicy.Validate(command, _installerRoot);
        string statePath = Path.Combine(_installerRoot, "state");
        using SafeFileHandle installer = OpenProtectedDirectory(_installerRoot);
        using SafeFileHandle state = OpenProtectedDirectory(statePath);
        using SafeFileHandle manifest = OpenProtectedFile(command.ManifestPath, statePath);
        PathIdentitySnapshot identity = PathIdentity.Inspect(manifest);
        if (identity.Length is < 1 or > MaximumStateBytes)
        {
            throw new IOException("Protected work manifest has an invalid size.");
        }

        return ReadHeldFile(manifest, identity.Length);
    }

    public void WriteResult(HelperCommand command, byte[] result)
    {
        ArgumentNullException.ThrowIfNull(result);
        if (result.Length is < 1 or > MaximumStateBytes)
        {
            throw new IOException("Protected helper result has an invalid size.");
        }

        ProtectedStatePathPolicy.Validate(command, _installerRoot);
        string statePath = Path.Combine(_installerRoot, "state");
        string resultsPath = Path.Combine(statePath, "results");
        using SafeFileHandle installer = OpenProtectedDirectory(_installerRoot);
        using SafeFileHandle state = OpenProtectedDirectory(statePath);
        using SafeFileHandle results = OpenProtectedDirectory(resultsPath);
        ValidateExistingResult(command.ResultPath, resultsPath);

        string temporaryPath = Path.Combine(
            resultsPath,
            $".result-{command.InstallId:N}-{Guid.NewGuid():N}.tmp");
        bool moved = false;
        try
        {
            using (var stream = new FileStream(
                       temporaryPath,
                       FileMode.CreateNew,
                       FileAccess.ReadWrite,
                       FileShare.Read,
                       bufferSize: 4096,
                       FileOptions.WriteThrough))
            {
                PathIdentitySnapshot identity = PathIdentity.Inspect(stream.SafeFileHandle);
                EnsureOrdinaryExactFile(identity, temporaryPath, resultsPath);
                if (NativeMethods.HasUnexpectedDataStreams(
                        temporaryPath,
                        directory: false))
                {
                    throw new IOException("Temporary protected result has a named stream.");
                }

                _aclPolicy.ProtectFile(temporaryPath);
                stream.Write(result);
                stream.Flush(flushToDisk: true);
            }

            File.Move(temporaryPath, command.ResultPath, overwrite: true);
            moved = true;
            using SafeFileHandle written = OpenProtectedFile(
                command.ResultPath,
                resultsPath);
            PathIdentitySnapshot finalIdentity = PathIdentity.Inspect(written);
            if (finalIdentity.Length != result.Length)
            {
                throw new IOException("Protected helper result length verification failed.");
            }

            byte[] writtenBytes = ReadHeldFile(written, finalIdentity.Length);
            if (!result.AsSpan().SequenceEqual(writtenBytes))
            {
                throw new IOException("Protected helper result content verification failed.");
            }
        }
        finally
        {
            if (!moved)
            {
                TryDeleteTemporaryFile(temporaryPath, resultsPath);
            }
        }
    }

    private SafeFileHandle OpenProtectedDirectory(string path)
    {
        SafeFileHandle handle = NativeMethods.OpenNoFollow(
            path,
            NativeMethods.FileReadAttributes,
            FileShare.Read,
            out int error);
        if (handle.IsInvalid)
        {
            handle.Dispose();
            throw NativeMethods.Win32("Unable to hold protected state directory", error);
        }

        try
        {
            PathIdentitySnapshot identity = PathIdentity.Inspect(handle);
            if (!identity.IsDirectory ||
                (identity.FileAttributes & NativeMethods.FileAttributeReparsePoint) != 0 ||
                identity.ReparseTag != 0 ||
                !PathIdentity.PathsEqual(identity.FinalPath, path) ||
                !PathIdentity.IsWithin(
                    identity.FinalPath,
                    _installerRoot,
                    allowEqual: true) ||
                NativeMethods.HasUnexpectedDataStreams(path, directory: true))
            {
                throw new IOException(
                    "Protected state directory is linked, redirected, or outside its boundary.");
            }

            _aclPolicy.VerifyDirectory(path);
            return handle;
        }
        catch
        {
            handle.Dispose();
            throw;
        }
    }

    private SafeFileHandle OpenProtectedFile(string path, string parentPath)
    {
        SafeFileHandle handle = NativeMethods.OpenNoFollow(
            path,
            NativeMethods.FileReadData | NativeMethods.FileReadAttributes,
            FileShare.Read,
            out int error);
        if (handle.IsInvalid)
        {
            handle.Dispose();
            throw NativeMethods.Win32("Unable to hold protected state file", error);
        }

        try
        {
            PathIdentitySnapshot identity = PathIdentity.Inspect(handle);
            EnsureOrdinaryExactFile(identity, path, parentPath);
            if (NativeMethods.HasUnexpectedDataStreams(path, directory: false))
            {
                throw new IOException("Protected state file has a named stream.");
            }

            _aclPolicy.VerifyFile(path);
            return handle;
        }
        catch
        {
            handle.Dispose();
            throw;
        }
    }

    private void ValidateExistingResult(string path, string resultsPath)
    {
        SafeFileHandle handle = NativeMethods.OpenNoFollow(
            path,
            NativeMethods.FileReadAttributes,
            FileShare.Read,
            out int error);
        if (handle.IsInvalid)
        {
            handle.Dispose();
            if (error is NativeMethods.ErrorFileNotFound or NativeMethods.ErrorPathNotFound)
            {
                return;
            }

            throw NativeMethods.Win32("Unable to inspect existing protected result", error);
        }

        using (handle)
        {
            PathIdentitySnapshot identity = PathIdentity.Inspect(handle);
            EnsureOrdinaryExactFile(identity, path, resultsPath);
            if (NativeMethods.HasUnexpectedDataStreams(path, directory: false))
            {
                throw new IOException("Existing protected result has a named stream.");
            }

            _aclPolicy.VerifyFile(path);
        }
    }

    private static void EnsureOrdinaryExactFile(
        PathIdentitySnapshot identity,
        string expectedPath,
        string parentPath)
    {
        if (identity.IsDirectory || identity.NumberOfLinks != 1 ||
            (identity.FileAttributes & NativeMethods.FileAttributeReparsePoint) != 0 ||
            identity.ReparseTag != 0 ||
            !PathIdentity.PathsEqual(identity.FinalPath, expectedPath) ||
            !PathIdentity.IsWithin(identity.FinalPath, parentPath))
        {
            throw new IOException(
                "Protected state file is linked, redirected, or outside its boundary.");
        }
    }

    private static byte[] ReadHeldFile(SafeFileHandle handle, long expectedLength)
    {
        byte[] bytes = new byte[checked((int)expectedLength)];
        int total = 0;
        while (total < bytes.Length)
        {
            int read = RandomAccess.Read(handle, bytes.AsSpan(total), total);
            if (read == 0)
            {
                throw new IOException("Protected state changed while being read.");
            }

            total += read;
        }

        return bytes;
    }

    private static void TryDeleteTemporaryFile(string path, string parentPath)
    {
        SafeFileHandle handle = NativeMethods.OpenNoFollow(
            path,
            NativeMethods.DeleteAccess | NativeMethods.FileReadAttributes,
            FileShare.Read,
            out int error);
        if (handle.IsInvalid)
        {
            handle.Dispose();
            return;
        }

        using (handle)
        {
            try
            {
                PathIdentitySnapshot identity = PathIdentity.Inspect(handle);
                EnsureOrdinaryExactFile(identity, path, parentPath);
                _ = NativeMethods.TryMarkDelete(handle, out _);
            }
            catch (Exception exception) when (
                exception is IOException or UnauthorizedAccessException)
            {
                // Never broaden cleanup after a failed protected-state write.
            }
        }
    }

    private static string GetDefaultInstallerRoot()
    {
        string commonData = Environment.GetFolderPath(
            Environment.SpecialFolder.CommonApplicationData);
        if (string.IsNullOrWhiteSpace(commonData))
        {
            throw new IOException("Windows common application-data path is unavailable.");
        }

        return Path.Combine(commonData, "LemonSerialMonitor", "Installer");
    }
}
