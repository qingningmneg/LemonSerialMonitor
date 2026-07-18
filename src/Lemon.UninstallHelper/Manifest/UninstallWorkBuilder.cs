using System.Security.Cryptography;
using Lemon.UninstallHelper.Completion;
using Lemon.UninstallHelper.Security;
using Microsoft.Win32.SafeHandles;

namespace Lemon.UninstallHelper.Manifest;

public static class UninstallWorkBuilder
{
    private const string ProductMarker = "CommMonitor:0.1.1";

    public static byte[] Build(
        string installId,
        string ownershipManifestSha256,
        string? appRoot,
        string? aiStateRoot)
    {
        var roots = new List<ApprovedRootManifest>(2);
        if (appRoot is not null)
        {
            roots.Add(BuildRoot(appRoot, ApprovedRootRole.AppRoot));
        }
        if (aiStateRoot is not null)
        {
            roots.Add(BuildRoot(aiStateRoot, ApprovedRootRole.AiStateRoot));
        }
        if (roots.Count == 0)
        {
            throw new ArgumentException("At least one owned root is required.");
        }

        byte[] key = RandomNumberGenerator.GetBytes(32);
        try
        {
            ProtectedCompletionKey protectedKey = CompletionKeyProtection.Protect(key);
            var payload = new UninstallWorkPayload(
                installId,
                ownershipManifestSha256,
                protectedKey,
                roots);
            UninstallWorkEnvelope envelope =
                UninstallWorkManifestCodec.Create(payload, key);
            return UninstallWorkManifestCodec.GetStateFileBytes(envelope);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(key);
        }
    }

    private static ApprovedRootManifest BuildRoot(
        string path,
        ApprovedRootRole role)
    {
        PathIdentitySnapshot rootIdentity = PathIdentity.Capture(path);
        if (!rootIdentity.IsDirectory ||
            NativeMethods.HasUnexpectedDataStreams(path, directory: true))
        {
            throw new IOException("An owned root is not an ordinary directory.");
        }

        string root = rootIdentity.FinalPath;
        var directories = new List<string>();
        var files = new List<(string RelativePath, long Size, string Sha256)>();
        var pending = new Stack<string>();
        pending.Push(root);
        while (pending.Count > 0)
        {
            string current = pending.Pop();
            foreach (string entry in Directory.EnumerateFileSystemEntries(current))
            {
                string fullPath = PathIdentity.NormalizePath(entry);
                if (!PathIdentity.IsWithin(fullPath, root))
                {
                    throw new IOException("An owned-root entry escaped its boundary.");
                }

                FileAttributes attributes = File.GetAttributes(fullPath);
                if ((attributes & FileAttributes.ReparsePoint) != 0)
                {
                    throw new IOException("Owned-root work preparation rejects reparse points.");
                }

                string relative = Path.GetRelativePath(root, fullPath);
                if ((attributes & FileAttributes.Directory) != 0)
                {
                    directories.Add(relative);
                    pending.Push(fullPath);
                    continue;
                }

                files.Add(CaptureImmutableFile(root, fullPath, relative));
            }
        }

        var objects = new List<OwnedObject>(directories.Count + files.Count);
        int directoryIndex = 0;
        foreach (string relative in directories.OrderBy(
                     value => value,
                     StringComparer.Ordinal))
        {
            directoryIndex++;
            objects.Add(OwnedObject.Directory(
                $"directory-{directoryIndex:D6}", relative));
        }
        int fileIndex = 0;
        foreach ((string relative, long size, string sha256) in files.OrderBy(
                     value => value.RelativePath,
                     StringComparer.Ordinal))
        {
            fileIndex++;
            objects.Add(OwnedObject.ImmutableFile(
                $"file-{fileIndex:D6}",
                relative,
                size,
                sha256,
                ProductMarker));
        }

        return new ApprovedRootManifest(
            root,
            rootIdentity.VolumeSerialNumber,
            rootIdentity.FileId,
            objects,
            role);
    }

    private static (string RelativePath, long Size, string Sha256) CaptureImmutableFile(
        string root,
        string fullPath,
        string relative)
    {
        using SafeFileHandle handle = NativeMethods.OpenNoFollow(
            fullPath,
            NativeMethods.FileReadData | NativeMethods.FileReadAttributes,
            FileShare.Read,
            out int error);
        if (handle.IsInvalid)
        {
            throw NativeMethods.Win32(
                "Unable to hold an owned file during work preparation", error);
        }

        PathIdentitySnapshot identity = PathIdentity.Inspect(handle);
        if (identity.IsDirectory || identity.ReparseTag != 0 ||
            (identity.FileAttributes & NativeMethods.FileAttributeReparsePoint) != 0 ||
            identity.NumberOfLinks != 1 ||
            !PathIdentity.PathsEqual(identity.FinalPath, fullPath) ||
            !PathIdentity.IsWithin(identity.FinalPath, root) ||
            NativeMethods.HasUnexpectedDataStreams(fullPath, directory: false))
        {
            throw new IOException("An owned file has an unsafe path identity.");
        }

        using var stream = new FileStream(handle, FileAccess.Read);
        string sha256 = Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant();
        return (relative, identity.Length, sha256);
    }
}
