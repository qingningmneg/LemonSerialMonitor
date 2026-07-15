using Microsoft.Win32.SafeHandles;

namespace Lemon.UninstallHelper.Security;

public sealed record PathIdentitySnapshot(
    string FinalPath,
    ulong VolumeSerialNumber,
    string FileId,
    bool IsDirectory,
    uint NumberOfLinks,
    long Length,
    uint FileAttributes,
    uint ReparseTag);

public static class PathIdentity
{
    public static PathIdentitySnapshot Capture(string path)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        string canonicalPath = NormalizePath(path);
        using SafeFileHandle handle = NativeMethods.OpenNoFollow(
            canonicalPath,
            NativeMethods.FileReadAttributes,
            FileShare.Read | FileShare.Write | FileShare.Delete,
            out int error);
        if (handle.IsInvalid)
        {
            throw NativeMethods.Win32("Unable to open the path for identity capture", error);
        }

        PathIdentitySnapshot identity = Inspect(handle);
        if ((identity.FileAttributes & NativeMethods.FileAttributeReparsePoint) != 0 ||
            identity.ReparseTag != 0)
        {
            throw new IOException("Identity capture rejects reparse points.");
        }

        if (!PathsEqual(identity.FinalPath, canonicalPath))
        {
            throw new IOException("The opened path resolves to a different final path.");
        }

        return identity;
    }

    internal static PathIdentitySnapshot Inspect(SafeFileHandle handle)
    {
        NativeMethods.FileAttributeTagInfo attributes =
            NativeMethods.GetAttributeTagInfo(handle);
        NativeMethods.ByHandleFileInformation basic =
            NativeMethods.GetBasicInformation(handle);
        (ulong volumeSerialNumber, string fileId) = NativeMethods.GetFileId(handle);
        string finalPath = NormalizeFinalPath(NativeMethods.GetFinalPath(handle));
        return new PathIdentitySnapshot(
            finalPath,
            volumeSerialNumber,
            fileId,
            (attributes.FileAttributes & NativeMethods.FileAttributeDirectory) != 0,
            basic.NumberOfLinks,
            basic.Length,
            attributes.FileAttributes,
            attributes.ReparseTag);
    }

    internal static string NormalizePath(string path) =>
        Path.TrimEndingDirectorySeparator(Path.GetFullPath(path));

    internal static string NormalizeFinalPath(string path)
    {
        const string uncPrefix = @"\\?\UNC\";
        const string devicePrefix = @"\\?\";
        string normalized = path.StartsWith(uncPrefix, StringComparison.OrdinalIgnoreCase)
            ? @"\\" + path[uncPrefix.Length..]
            : path.StartsWith(devicePrefix, StringComparison.OrdinalIgnoreCase)
                ? path[devicePrefix.Length..]
                : path;
        return NormalizePath(normalized);
    }

    internal static bool PathsEqual(string left, string right) =>
        string.Equals(
            NormalizePath(left),
            NormalizePath(right),
            StringComparison.OrdinalIgnoreCase);

    internal static bool IsWithin(string path, string root, bool allowEqual = false)
    {
        string canonicalPath = NormalizePath(path);
        string canonicalRoot = NormalizePath(root);
        if (allowEqual && PathsEqual(canonicalPath, canonicalRoot))
        {
            return true;
        }

        string prefix = canonicalRoot.EndsWith(Path.DirectorySeparatorChar)
            ? canonicalRoot
            : canonicalRoot + Path.DirectorySeparatorChar;
        return canonicalPath.StartsWith(prefix, StringComparison.OrdinalIgnoreCase);
    }
}
