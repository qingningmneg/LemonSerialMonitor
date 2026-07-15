using System.Runtime.Versioning;
using System.Security.AccessControl;
using System.Security.Principal;
using Microsoft.Win32.SafeHandles;

namespace Lemon.UninstallHelper.Security;

public sealed record OwnershipAclProfile(
    string OwnerSid,
    bool AreAccessRulesProtected,
    string[] AllowedFullControlSids,
    int DenyRuleCount,
    bool UsersWritable);

public sealed record OwnershipAncestorEvidence(
    string RequestedPath,
    string FinalPath,
    string VolumeSerial,
    string FileId,
    uint ReparseTag);

public sealed record OwnershipNearestAncestorEvidence(
    string RequestedPath,
    string FinalPath,
    string VolumeSerial,
    string FileId);

public sealed record OwnershipPathProbeResult(
    string Provider,
    string VolumeKind,
    string VolumeSerialNumber,
    string RequestedPath,
    string? FinalPath,
    bool Exists,
    bool IsDirectory,
    bool IsEmpty,
    bool IsReparse,
    string? FileId,
    string? ExistingParentFileId,
    OwnershipAclProfile AclProfile,
    string? InstallIdMarker,
    OwnershipNearestAncestorEvidence NearestExistingAncestor,
    string UnresolvedSuffix,
    OwnershipAncestorEvidence[] Ancestors);

[SupportedOSPlatform("windows")]
public static class OwnershipPathProbe
{
    private static readonly SecurityIdentifier SystemSid =
        new(WellKnownSidType.LocalSystemSid, domainSid: null);
    private static readonly SecurityIdentifier AdministratorsSid =
        new(WellKnownSidType.BuiltinAdministratorsSid, domainSid: null);

    private const FileSystemRights WritableRights =
        FileSystemRights.WriteData |
        FileSystemRights.AppendData |
        FileSystemRights.WriteExtendedAttributes |
        FileSystemRights.WriteAttributes |
        FileSystemRights.Delete |
        FileSystemRights.DeleteSubdirectoriesAndFiles |
        FileSystemRights.ChangePermissions |
        FileSystemRights.TakeOwnership;

    internal static bool IncludesWritableRights(FileSystemRights rights) =>
        (rights & WritableRights) != 0;

    public static OwnershipPathProbeResult Capture(string path)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        string requestedPath = ValidateLocalPath(path);
        string volumeRoot = Path.GetPathRoot(requestedPath)
            ?? throw new IOException("The ownership path has no volume root.");
        var drive = new DriveInfo(volumeRoot);
        if (drive.DriveType != DriveType.Fixed)
        {
            throw new IOException("Ownership paths must be on a fixed local drive.");
        }

        string[] requestedAncestors = BuildRequestedAncestors(requestedPath);
        var openHandles = new List<SafeFileHandle>(requestedAncestors.Length);
        var identities = new List<PathIdentitySnapshot>(requestedAncestors.Length);
        try
        {
            for (int index = 0; index < requestedAncestors.Length; index++)
            {
                SafeFileHandle handle = NativeMethods.OpenNoFollow(
                    requestedAncestors[index],
                    NativeMethods.FileReadAttributes,
                    FileShare.Read | FileShare.Write | FileShare.Delete,
                    out int error);
                if (handle.IsInvalid)
                {
                    handle.Dispose();
                    if (error is NativeMethods.ErrorFileNotFound or
                        NativeMethods.ErrorPathNotFound)
                    {
                        break;
                    }

                    throw NativeMethods.Win32(
                        "Unable to open an ownership-path ancestor", error);
                }

                openHandles.Add(handle);
                PathIdentitySnapshot identity = PathIdentity.Inspect(handle);
                if ((identity.FileAttributes & NativeMethods.FileAttributeReparsePoint) != 0 ||
                    identity.ReparseTag != 0)
                {
                    throw new IOException("Ownership paths reject reparse points.");
                }

                if (!PathIdentity.PathsEqual(
                        identity.FinalPath,
                        requestedAncestors[index]))
                {
                    throw new IOException(
                        "An ownership-path ancestor resolves to a different final path.");
                }

                if (index < requestedAncestors.Length - 1 && !identity.IsDirectory)
                {
                    throw new IOException(
                        "An ownership-path intermediate ancestor is not a directory.");
                }

                if (identities.Count > 0)
                {
                    PathIdentitySnapshot parent = identities[^1];
                    if (identity.VolumeSerialNumber != parent.VolumeSerialNumber ||
                        !PathIdentity.IsWithin(identity.FinalPath, parent.FinalPath))
                    {
                        throw new IOException(
                            "Ownership-path ancestor identities are not physically nested.");
                    }
                }

                identities.Add(identity);
            }

            if (identities.Count == 0)
            {
                throw new IOException("The ownership-path volume root is unavailable.");
            }

            int nearestIndex = identities.Count - 1;
            PathIdentitySnapshot nearestIdentity = identities[nearestIndex];
            string nearestRequestedPath = requestedAncestors[nearestIndex];
            bool exists = identities.Count == requestedAncestors.Length;
            PathIdentitySnapshot? targetIdentity = exists ? nearestIdentity : null;
            string unresolvedSuffix = exists
                ? string.Empty
                : Path.GetRelativePath(nearestRequestedPath, requestedPath);
            bool isDirectory = !exists || targetIdentity!.IsDirectory;
            bool isEmpty = !exists || (targetIdentity!.IsDirectory &&
                !Directory.EnumerateFileSystemEntries(requestedPath).Any());
            string volumeSerial = nearestIdentity.VolumeSerialNumber.ToString("x16");

            OwnershipAncestorEvidence[] ancestors = identities
                .Select((identity, index) => new OwnershipAncestorEvidence(
                    requestedAncestors[index],
                    identity.FinalPath,
                    identity.VolumeSerialNumber.ToString("x16"),
                    identity.FileId,
                    identity.ReparseTag))
                .ToArray();

            return new OwnershipPathProbeResult(
                "FileSystem",
                "Fixed",
                volumeSerial,
                requestedPath,
                targetIdentity?.FinalPath,
                exists,
                isDirectory,
                isEmpty,
                false,
                targetIdentity?.FileId,
                exists ? null : nearestIdentity.FileId,
                CaptureAclProfile(nearestRequestedPath, nearestIdentity.IsDirectory),
                null,
                new OwnershipNearestAncestorEvidence(
                    nearestRequestedPath,
                    nearestIdentity.FinalPath,
                    volumeSerial,
                    nearestIdentity.FileId),
                unresolvedSuffix,
                ancestors);
        }
        finally
        {
            for (int index = openHandles.Count - 1; index >= 0; index--)
            {
                openHandles[index].Dispose();
            }
        }
    }

    private static string ValidateLocalPath(string path)
    {
        if (!Path.IsPathFullyQualified(path) ||
            path.StartsWith(@"\\", StringComparison.Ordinal) ||
            path.StartsWith(@"\\?\", StringComparison.OrdinalIgnoreCase) ||
            path.StartsWith(@"\\.\", StringComparison.OrdinalIgnoreCase))
        {
            throw new ArgumentException(
                "The ownership path must be a fully qualified ordinary local path.",
                nameof(path));
        }

        return PathIdentity.NormalizePath(path);
    }

    private static string[] BuildRequestedAncestors(string requestedPath)
    {
        string root = Path.GetPathRoot(requestedPath)
            ?? throw new IOException("The ownership path has no volume root.");
        var result = new List<string> { root };
        string relative = requestedPath[root.Length..];
        string cursor = root;
        foreach (string segment in relative.Split(
                     Path.DirectorySeparatorChar,
                     StringSplitOptions.RemoveEmptyEntries))
        {
            cursor = Path.Combine(cursor, segment);
            result.Add(cursor);
        }

        return result.ToArray();
    }

    private static OwnershipAclProfile CaptureAclProfile(
        string path,
        bool directory)
    {
        FileSystemSecurity security = directory
            ? new DirectoryInfo(path).GetAccessControl(
                AccessControlSections.Access | AccessControlSections.Owner)
            : new FileInfo(path).GetAccessControl(
                AccessControlSections.Access | AccessControlSections.Owner);
        SecurityIdentifier? owner =
            security.GetOwner(typeof(SecurityIdentifier)) as SecurityIdentifier;
        if (owner is null)
        {
            throw new UnauthorizedAccessException(
                "The ownership-path ACL has no SID owner.");
        }

        FileSystemAccessRule[] rules = security.GetAccessRules(
                includeExplicit: true,
                includeInherited: true,
                typeof(SecurityIdentifier))
            .Cast<FileSystemAccessRule>()
            .ToArray();
        int denyRuleCount = rules.Count(rule =>
            rule.AccessControlType == AccessControlType.Deny);
        bool usersWritable = rules.Any(rule =>
            rule.AccessControlType == AccessControlType.Allow &&
            rule.IdentityReference is SecurityIdentifier sid &&
            !sid.Equals(SystemSid) &&
            !sid.Equals(AdministratorsSid) &&
            IncludesWritableRights(rule.FileSystemRights));

        string[] fullControlSids = rules
            .Where(rule =>
                rule.AccessControlType == AccessControlType.Allow &&
                rule.IdentityReference is SecurityIdentifier &&
                (rule.FileSystemRights & FileSystemRights.FullControl) ==
                    FileSystemRights.FullControl)
            .Select(rule => ((SecurityIdentifier)rule.IdentityReference).Value)
            .Distinct(StringComparer.Ordinal)
            .OrderBy(GetTrustedSidOrder)
            .ThenBy(value => value, StringComparer.Ordinal)
            .ToArray();

        return new OwnershipAclProfile(
            owner.Value,
            security.AreAccessRulesProtected,
            fullControlSids,
            denyRuleCount,
            usersWritable);
    }

    private static int GetTrustedSidOrder(string sid) => sid switch
    {
        "S-1-5-18" => 0,
        "S-1-5-32-544" => 1,
        _ => 2,
    };
}
