using System.Security.Cryptography;
using System.Text.RegularExpressions;
using Lemon.UninstallHelper.Manifest;
using Microsoft.Win32.SafeHandles;

namespace Lemon.UninstallHelper.Security;

public interface IDeletionRaceProbe
{
    void RootHeld(string canonicalPath);
    void ObjectHeld(string relativePath);
}

public enum DeletionStatus
{
    Completed,
    PendingReboot,
    Failed,
}

public enum DeletionOutcomeStatus
{
    Deleted,
    AlreadyAbsent,
    PendingReboot,
    Preserved,
    Failed,
}

public sealed record DeletionOutcome(
    int Sequence,
    string ObjectId,
    string RelativePath,
    DeletionOutcomeStatus Status,
    string Reason,
    int Win32Code);

public sealed record DeletionReport(
    DeletionStatus Status,
    IReadOnlyList<DeletionOutcome> Outcomes)
{
    public DeletionOutcome Outcome(string objectId) =>
        Outcomes.Single(item => string.Equals(
            item.ObjectId,
            objectId,
            StringComparison.Ordinal));
}

public sealed class SafeOwnedTreeDelete(IDeletionRaceProbe? raceProbe = null)
{
    private static readonly Regex ObjectIdPattern = new(
        "^[a-z0-9][a-z0-9.-]*$",
        RegexOptions.CultureInvariant);
    private static readonly Regex LowerSha256Pattern = new(
        "^[0-9a-f]{64}$",
        RegexOptions.CultureInvariant);
    private static readonly Regex LowerFileIdPattern = new(
        "^[0-9a-f]{32}$",
        RegexOptions.CultureInvariant);
    private static readonly Regex ProductMarkerPattern = new(
        "^CommMonitor:[0-9]+\\.[0-9]+\\.[0-9]+(?:[-+][A-Za-z0-9.-]+)?$",
        RegexOptions.CultureInvariant);
    private static readonly HashSet<string> DynamicFileAllowList = new(
        ["leases.json"],
        StringComparer.Ordinal);

    private readonly IDeletionRaceProbe? _raceProbe = raceProbe;

    public DeletionReport Execute(ApprovedRootManifest manifest)
    {
        ArgumentNullException.ThrowIfNull(manifest);
        var context = new ExecutionContext();
        ValidatedManifest validated;
        try
        {
            validated = ValidateManifest(manifest);
        }
        catch (Exception exception) when (
            exception is ArgumentException or InvalidDataException or IOException)
        {
            context.Add(
                "manifest",
                string.Empty,
                DeletionOutcomeStatus.Failed,
                exception.Message,
                0);
            return context.CreateReport();
        }

        SafeFileHandle? rootHandle = null;
        var directories = new Dictionary<string, DirectoryState>(
            StringComparer.OrdinalIgnoreCase);
        try
        {
            rootHandle = NativeMethods.OpenNoFollow(
                validated.RootPath,
                NativeMethods.DeleteAccess |
                    NativeMethods.FileReadAttributes |
                    NativeMethods.FileReadData,
                FileShare.Read,
                out int rootError);
            if (rootHandle.IsInvalid)
            {
                if (rootError is NativeMethods.ErrorFileNotFound or
                    NativeMethods.ErrorPathNotFound)
                {
                    foreach (ValidatedObject item in validated.Objects)
                    {
                        context.Add(
                            item.Source.ObjectId,
                            item.RelativePath,
                            DeletionOutcomeStatus.AlreadyAbsent,
                            "Approved root and owned object are already absent.",
                            rootError);
                    }

                    rootHandle.Dispose();
                    rootHandle = null;
                    return context.CreateReport();
                }

                context.Add(
                    "approved-root",
                    string.Empty,
                    ClassifyOpenFailure(rootError),
                    "Unable to hold the approved root.",
                    rootError);
                rootHandle.Dispose();
                rootHandle = null;
                return context.CreateReport();
            }

            PathIdentitySnapshot rootIdentity = PathIdentity.Inspect(rootHandle);
            if (!IsSafeDirectoryIdentity(
                    rootIdentity,
                    validated.RootPath,
                    validated.RootPath) ||
                NativeMethods.HasUnexpectedDataStreams(
                    validated.RootPath,
                    directory: true) ||
                rootIdentity.VolumeSerialNumber != validated.VolumeSerialNumber ||
                !string.Equals(
                    rootIdentity.FileId,
                    validated.FileId,
                    StringComparison.Ordinal))
            {
                context.Add(
                    "approved-root",
                    string.Empty,
                    DeletionOutcomeStatus.Preserved,
                    "Approved root identity or final path changed.",
                    0);
                return context.CreateReport();
            }

            _raceProbe?.RootHeld(validated.RootPath);
            directories.Add(
                string.Empty,
                new DirectoryState(
                    objectId: "approved-root",
                    relativePath: string.Empty,
                    fullPath: validated.RootPath,
                    depth: 0,
                    rootHandle));
            rootHandle = null;

            OpenKnownDirectories(validated, directories, context);
            DiscoverUnknownEntries(validated, directories, context);
            DeleteKnownFiles(validated, directories, context);
            DeleteKnownDirectories(validated, directories, context);
            DeleteApprovedRoot(validated, directories[string.Empty], context);
            return context.CreateReport();
        }
        catch (Exception exception) when (
            exception is IOException or UnauthorizedAccessException or
                InvalidOperationException)
        {
            context.Add(
                "execution",
                string.Empty,
                DeletionOutcomeStatus.Failed,
                exception.Message,
                0);
            return context.CreateReport();
        }
        finally
        {
            rootHandle?.Dispose();
            foreach (DirectoryState directory in directories.Values)
            {
                directory.Dispose();
            }
        }
    }

    private void OpenKnownDirectories(
        ValidatedManifest manifest,
        Dictionary<string, DirectoryState> directories,
        ExecutionContext context)
    {
        foreach (ValidatedObject item in manifest.Objects
                     .Where(item => item.Source.Kind == OwnedObjectKind.Directory)
                     .OrderBy(item => item.Depth)
                     .ThenBy(item => item.RelativePath, StringComparer.Ordinal))
        {
            string parent = GetParent(item.RelativePath);
            if (!directories.TryGetValue(parent, out DirectoryState? parentState) ||
                !parentState.IsSafeAndPresent)
            {
                DeletionOutcomeStatus status = parentState?.Status == DirectoryStateStatus.Pending
                    ? DeletionOutcomeStatus.PendingReboot
                    : DeletionOutcomeStatus.Preserved;
                context.Add(
                    item.Source.ObjectId,
                    item.RelativePath,
                    status,
                    "The held parent directory is unavailable or unsafe.",
                    parentState?.Win32Code ?? 0);
                directories[item.RelativePath] = DirectoryState.Blocked(
                    item,
                    status == DeletionOutcomeStatus.PendingReboot
                        ? DirectoryStateStatus.Pending
                        : DirectoryStateStatus.Unsafe,
                    parentState?.Win32Code ?? 0);
                continue;
            }

            SafeFileHandle handle = NativeMethods.OpenNoFollow(
                item.FullPath,
                NativeMethods.DeleteAccess |
                    NativeMethods.FileReadAttributes |
                    NativeMethods.FileReadData,
                FileShare.Read,
                out int error);
            if (handle.IsInvalid)
            {
                handle.Dispose();
                if (error is NativeMethods.ErrorFileNotFound or
                    NativeMethods.ErrorPathNotFound)
                {
                    context.Add(
                        item.Source.ObjectId,
                        item.RelativePath,
                        DeletionOutcomeStatus.AlreadyAbsent,
                        "Directory is already absent.",
                        error);
                    directories[item.RelativePath] = DirectoryState.Blocked(
                        item,
                        DirectoryStateStatus.Absent,
                        error);
                }
                else
                {
                    DeletionOutcomeStatus outcome = ClassifyOpenFailure(error);
                    context.Add(
                        item.Source.ObjectId,
                        item.RelativePath,
                        outcome,
                        "Unable to hold the directory without following links.",
                        error);
                    directories[item.RelativePath] = DirectoryState.Blocked(
                        item,
                        outcome == DeletionOutcomeStatus.PendingReboot
                            ? DirectoryStateStatus.Pending
                            : DirectoryStateStatus.Unsafe,
                        error);
                }

                continue;
            }

            try
            {
                PathIdentitySnapshot identity = PathIdentity.Inspect(handle);
                if (!IsSafeDirectoryIdentity(
                        identity,
                        item.FullPath,
                        manifest.RootPath) ||
                    NativeMethods.HasUnexpectedDataStreams(
                        item.FullPath,
                        directory: true) ||
                    identity.VolumeSerialNumber != manifest.VolumeSerialNumber)
                {
                    context.Add(
                        item.Source.ObjectId,
                        item.RelativePath,
                        DeletionOutcomeStatus.Preserved,
                        "Directory identity, type, volume, or final path is unsafe.",
                        0);
                    handle.Dispose();
                    directories[item.RelativePath] = DirectoryState.Blocked(
                        item,
                        DirectoryStateStatus.Unsafe,
                        0);
                    continue;
                }

                _raceProbe?.ObjectHeld(item.RelativePath);
                directories[item.RelativePath] = new DirectoryState(
                    item.Source.ObjectId,
                    item.RelativePath,
                    item.FullPath,
                    item.Depth,
                    handle);
            }
            catch
            {
                handle.Dispose();
                throw;
            }
        }
    }

    private static void DiscoverUnknownEntries(
        ValidatedManifest manifest,
        IReadOnlyDictionary<string, DirectoryState> directories,
        ExecutionContext context)
    {
        var expectedChildren = new Dictionary<string, HashSet<string>>(
            StringComparer.OrdinalIgnoreCase);
        foreach (ValidatedObject item in manifest.Objects)
        {
            string parent = GetParent(item.RelativePath);
            if (!expectedChildren.TryGetValue(parent, out HashSet<string>? children))
            {
                children = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                expectedChildren.Add(parent, children);
            }

            children.Add(GetLeaf(item.RelativePath));
        }

        foreach ((string relativeDirectory, DirectoryState directory) in directories)
        {
            if (!directory.IsSafeAndPresent)
            {
                continue;
            }

            expectedChildren.TryGetValue(relativeDirectory, out HashSet<string>? expected);
            expected ??= new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (string actualPath in Directory.EnumerateFileSystemEntries(
                         directory.FullPath,
                         "*",
                         SearchOption.TopDirectoryOnly))
            {
                string leaf = Path.GetFileName(actualPath);
                if (expected.Contains(leaf))
                {
                    continue;
                }

                string relative = string.IsNullOrEmpty(relativeDirectory)
                    ? leaf
                    : relativeDirectory + Path.DirectorySeparatorChar + leaf;
                context.Add(
                    "unknown:" + relative.Replace('\\', '/'),
                    relative,
                    DeletionOutcomeStatus.Preserved,
                    "The object is not present in the authenticated ownership manifest.",
                    0);
            }
        }
    }

    private void DeleteKnownFiles(
        ValidatedManifest manifest,
        IReadOnlyDictionary<string, DirectoryState> directories,
        ExecutionContext context)
    {
        foreach (ValidatedObject item in manifest.Objects
                     .Where(item => item.Source.Kind != OwnedObjectKind.Directory)
                     .OrderByDescending(item => item.Depth)
                     .ThenBy(item => item.RelativePath, StringComparer.Ordinal))
        {
            string parent = GetParent(item.RelativePath);
            if (!directories.TryGetValue(parent, out DirectoryState? parentState) ||
                !parentState.IsSafeAndPresent)
            {
                if (parentState?.Status == DirectoryStateStatus.Absent)
                {
                    context.Add(
                        item.Source.ObjectId,
                        item.RelativePath,
                        DeletionOutcomeStatus.AlreadyAbsent,
                        "Parent directory and file are already absent.",
                        parentState.Win32Code);
                }
                else
                {
                    DeletionOutcomeStatus status =
                        parentState?.Status == DirectoryStateStatus.Pending
                            ? DeletionOutcomeStatus.PendingReboot
                            : DeletionOutcomeStatus.Preserved;
                    context.Add(
                        item.Source.ObjectId,
                        item.RelativePath,
                        status,
                        "The held parent directory is unavailable or unsafe.",
                        parentState?.Win32Code ?? 0);
                }

                continue;
            }

            DeleteKnownFile(item, manifest, context);
        }
    }

    private void DeleteKnownFile(
        ValidatedObject item,
        ValidatedManifest manifest,
        ExecutionContext context)
    {
        SafeFileHandle handle = NativeMethods.OpenNoFollow(
            item.FullPath,
            NativeMethods.DeleteAccess |
                NativeMethods.FileReadAttributes |
                NativeMethods.FileReadData,
            FileShare.Read,
            out int error);
        if (handle.IsInvalid)
        {
            handle.Dispose();
            if (error is NativeMethods.ErrorFileNotFound or NativeMethods.ErrorPathNotFound)
            {
                context.Add(
                    item.Source.ObjectId,
                    item.RelativePath,
                    DeletionOutcomeStatus.AlreadyAbsent,
                    "File is already absent.",
                    error);
            }
            else
            {
                context.Add(
                    item.Source.ObjectId,
                    item.RelativePath,
                    ClassifyOpenFailure(error),
                    "Unable to hold the file for identity-safe deletion.",
                    error);
            }

            return;
        }

        bool marked = false;
        try
        {
            PathIdentitySnapshot identity = PathIdentity.Inspect(handle);
            if (!IsSafeFileIdentity(identity, item.FullPath, manifest.RootPath) ||
                identity.VolumeSerialNumber != manifest.VolumeSerialNumber ||
                NativeMethods.HasUnexpectedDataStreams(
                    item.FullPath,
                    directory: false))
            {
                context.Add(
                    item.Source.ObjectId,
                    item.RelativePath,
                    DeletionOutcomeStatus.Preserved,
                    "File is a reparse point, hard link, directory, or changed path.",
                    0);
                return;
            }

            _raceProbe?.ObjectHeld(item.RelativePath);
            if (item.Source.Kind == OwnedObjectKind.DynamicFile &&
                (identity.VolumeSerialNumber != item.Source.VolumeSerialNumber ||
                    !string.Equals(
                        identity.FileId,
                        item.Source.FileId,
                        StringComparison.Ordinal)))
            {
                context.Add(
                    item.Source.ObjectId,
                    item.RelativePath,
                    DeletionOutcomeStatus.Preserved,
                    "Dynamic file identity changed after the prepared snapshot.",
                    0);
                return;
            }
            if (item.Source.Kind == OwnedObjectKind.ImmutableFile)
            {
                if (identity.Length != item.Source.Size ||
                    !string.Equals(
                        ComputeSha256(handle, identity.Length),
                        item.Source.Sha256,
                        StringComparison.Ordinal))
                {
                    context.Add(
                        item.Source.ObjectId,
                        item.RelativePath,
                        DeletionOutcomeStatus.Preserved,
                        "Immutable file size or SHA-256 no longer matches.",
                        0);
                    return;
                }
            }

            if (!NativeMethods.TryMarkDelete(handle, out int deleteError))
            {
                context.Add(
                    item.Source.ObjectId,
                    item.RelativePath,
                    ClassifyDeleteFailure(deleteError),
                    "The verified file could not be marked for deletion.",
                    deleteError);
                return;
            }

            marked = true;
        }
        finally
        {
            handle.Dispose();
        }

        if (marked && File.Exists(item.FullPath))
        {
            context.Add(
                item.Source.ObjectId,
                item.RelativePath,
                DeletionOutcomeStatus.PendingReboot,
                "The verified file remains visible after handle disposition.",
                NativeMethods.ErrorSharingViolation);
        }
        else if (marked)
        {
            context.Add(
                item.Source.ObjectId,
                item.RelativePath,
                DeletionOutcomeStatus.Deleted,
                "Verified file deleted by held handle.",
                0);
        }
    }

    private static void DeleteKnownDirectories(
        ValidatedManifest manifest,
        IReadOnlyDictionary<string, DirectoryState> directories,
        ExecutionContext context)
    {
        foreach (ValidatedObject item in manifest.Objects
                     .Where(item => item.Source.Kind == OwnedObjectKind.Directory)
                     .OrderByDescending(item => item.Depth)
                     .ThenByDescending(item => item.RelativePath, StringComparer.Ordinal))
        {
            DirectoryState state = directories[item.RelativePath];
            if (!state.IsSafeAndPresent || context.Contains(item.Source.ObjectId))
            {
                continue;
            }

            if (Directory.EnumerateFileSystemEntries(state.FullPath).Any())
            {
                context.Add(
                    item.Source.ObjectId,
                    item.RelativePath,
                    context.HasPending
                        ? DeletionOutcomeStatus.PendingReboot
                        : DeletionOutcomeStatus.Preserved,
                    "Directory is not empty after exact child processing.",
                    context.HasPending ? NativeMethods.ErrorDirNotEmpty : 0);
                continue;
            }

            if (!NativeMethods.TryMarkDelete(state.Handle!, out int error))
            {
                context.Add(
                    item.Source.ObjectId,
                    item.RelativePath,
                    ClassifyDeleteFailure(error),
                    "The verified empty directory could not be marked for deletion.",
                    error);
                continue;
            }

            state.Dispose();
            context.Add(
                item.Source.ObjectId,
                item.RelativePath,
                Directory.Exists(state.FullPath)
                    ? DeletionOutcomeStatus.PendingReboot
                    : DeletionOutcomeStatus.Deleted,
                "Verified empty directory processed by held handle.",
                Directory.Exists(state.FullPath)
                    ? NativeMethods.ErrorSharingViolation
                    : 0);
        }
    }

    private static void DeleteApprovedRoot(
        ValidatedManifest manifest,
        DirectoryState root,
        ExecutionContext context)
    {
        if (context.HasFailure || context.HasPending)
        {
            return;
        }

        if (Directory.EnumerateFileSystemEntries(manifest.RootPath).Any())
        {
            context.Add(
                "approved-root",
                string.Empty,
                DeletionOutcomeStatus.Preserved,
                "Approved root gained or retained an unowned object.",
                NativeMethods.ErrorDirNotEmpty);
            return;
        }

        if (!NativeMethods.TryMarkDelete(root.Handle!, out int error))
        {
            context.Add(
                "approved-root",
                string.Empty,
                ClassifyDeleteFailure(error),
                "The verified approved root could not be marked for deletion.",
                error);
            return;
        }

        root.Dispose();
        if (Directory.Exists(manifest.RootPath))
        {
            context.Add(
                "approved-root",
                string.Empty,
                DeletionOutcomeStatus.PendingReboot,
                "The approved root remains visible after handle disposition.",
                NativeMethods.ErrorSharingViolation);
        }
    }

    private static string ComputeSha256(SafeFileHandle handle, long expectedLength)
    {
        using IncrementalHash hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        byte[] buffer = new byte[64 * 1024];
        long offset = 0;
        while (offset < expectedLength)
        {
            int requested = (int)Math.Min(buffer.Length, expectedLength - offset);
            int read = RandomAccess.Read(handle, buffer.AsSpan(0, requested), offset);
            if (read == 0)
            {
                break;
            }

            hash.AppendData(buffer, 0, read);
            offset += read;
        }

        if (offset != expectedLength)
        {
            throw new IOException("File length changed while its held handle was hashed.");
        }

        return Convert.ToHexString(hash.GetHashAndReset()).ToLowerInvariant();
    }

    private static bool IsSafeDirectoryIdentity(
        PathIdentitySnapshot identity,
        string expectedPath,
        string rootPath) =>
        identity.IsDirectory &&
        (identity.FileAttributes & NativeMethods.FileAttributeReparsePoint) == 0 &&
        identity.ReparseTag == 0 &&
        PathIdentity.PathsEqual(identity.FinalPath, expectedPath) &&
        PathIdentity.IsWithin(identity.FinalPath, rootPath, allowEqual: true);

    private static bool IsSafeFileIdentity(
        PathIdentitySnapshot identity,
        string expectedPath,
        string rootPath) =>
        !identity.IsDirectory &&
        identity.NumberOfLinks == 1 &&
        (identity.FileAttributes & NativeMethods.FileAttributeReparsePoint) == 0 &&
        identity.ReparseTag == 0 &&
        PathIdentity.PathsEqual(identity.FinalPath, expectedPath) &&
        PathIdentity.IsWithin(identity.FinalPath, rootPath);

    private static DeletionOutcomeStatus ClassifyOpenFailure(int error) =>
        error is NativeMethods.ErrorSharingViolation or NativeMethods.ErrorLockViolation
            ? DeletionOutcomeStatus.PendingReboot
            : DeletionOutcomeStatus.Preserved;

    private static DeletionOutcomeStatus ClassifyDeleteFailure(int error) =>
        error is NativeMethods.ErrorSharingViolation or
            NativeMethods.ErrorLockViolation
            ? DeletionOutcomeStatus.PendingReboot
            : DeletionOutcomeStatus.Failed;

    private static ValidatedManifest ValidateManifest(ApprovedRootManifest manifest)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(manifest.CanonicalPath);
        string root = PathIdentity.NormalizePath(manifest.CanonicalPath);
        if (!Path.IsPathFullyQualified(root) || root.StartsWith(@"\\", StringComparison.Ordinal))
        {
            throw new InvalidDataException("Approved root must be a fully qualified local path.");
        }

        string? driveRoot = Path.GetPathRoot(root);
        if (driveRoot is null || new DriveInfo(driveRoot).DriveType != DriveType.Fixed)
        {
            throw new InvalidDataException("Approved root must be on a fixed local drive.");
        }

        if (!LowerFileIdPattern.IsMatch(manifest.FileId) || manifest.Objects is null)
        {
            throw new InvalidDataException("Approved root file identity is not canonical.");
        }

        var ids = new HashSet<string>(StringComparer.Ordinal);
        var paths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var items = new List<ValidatedObject>(manifest.Objects.Count);
        foreach (OwnedObject source in manifest.Objects)
        {
            if (source is null || !ObjectIdPattern.IsMatch(source.ObjectId) ||
                !ids.Add(source.ObjectId))
            {
                throw new InvalidDataException("Owned object IDs are invalid or duplicate.");
            }

            string relative = ValidateRelativePath(source.RelativePath);
            if (!paths.Add(relative))
            {
                throw new InvalidDataException("Owned object paths are duplicate.");
            }

            string fullPath = PathIdentity.NormalizePath(Path.Combine(root, relative));
            if (!PathIdentity.IsWithin(fullPath, root))
            {
                throw new InvalidDataException("Owned object escaped the approved root.");
            }

            switch (source.Kind)
            {
                case OwnedObjectKind.ImmutableFile:
                    if (source.Size is null or < 0 ||
                        source.Sha256 is null ||
                        !LowerSha256Pattern.IsMatch(source.Sha256) ||
                        source.ProductMarker is null ||
                        !ProductMarkerPattern.IsMatch(source.ProductMarker) ||
                        source.VolumeSerialNumber is not null ||
                        source.FileId is not null)
                    {
                        throw new InvalidDataException(
                            "Immutable file metadata is incomplete or noncanonical.");
                    }
                    break;
                case OwnedObjectKind.DynamicFile:
                    if (source.Size is not null || source.Sha256 is not null ||
                        source.ProductMarker is not null ||
                        !DynamicFileAllowList.Contains(relative) ||
                        source.VolumeSerialNumber is null ||
                        source.FileId is null ||
                        !LowerFileIdPattern.IsMatch(source.FileId))
                    {
                        throw new InvalidDataException(
                            "Dynamic file is not in the fixed exact allow-list.");
                    }
                    break;
                case OwnedObjectKind.Directory:
                    if (source.Size is not null || source.Sha256 is not null ||
                        source.ProductMarker is not null ||
                        source.VolumeSerialNumber is not null ||
                        source.FileId is not null)
                    {
                        throw new InvalidDataException(
                            "Directory metadata contains file-only identity fields.");
                    }
                    break;
                default:
                    throw new InvalidDataException("Owned object kind is unsupported.");
            }

            items.Add(new ValidatedObject(
                source,
                relative,
                fullPath,
                relative.Count(character => character == '\\') + 1));
        }

        var directoryPaths = new HashSet<string>(
            items.Where(item => item.Source.Kind == OwnedObjectKind.Directory)
                .Select(item => item.RelativePath),
            StringComparer.OrdinalIgnoreCase);
        foreach (ValidatedObject item in items)
        {
            string parent = GetParent(item.RelativePath);
            if (!string.IsNullOrEmpty(parent) && !directoryPaths.Contains(parent))
            {
                throw new InvalidDataException(
                    "Every nested object requires an authenticated parent directory record.");
            }
        }

        return new ValidatedManifest(
            root,
            manifest.VolumeSerialNumber,
            manifest.FileId,
            items);
    }

    private static string ValidateRelativePath(string path)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        if (Path.IsPathFullyQualified(path) || path.StartsWith('\\') ||
            path.Contains('/') || path.Contains(':') || path.Contains('*') ||
            path.Contains('?'))
        {
            throw new InvalidDataException("Owned object path is not an ordinary relative path.");
        }

        string[] segments = path.Split('\\');
        if (segments.Any(segment =>
                segment.Length == 0 || segment is "." or ".." ||
                segment.EndsWith(' ') || segment.EndsWith('.') ||
                segment.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0))
        {
            throw new InvalidDataException("Owned object path contains an unsafe segment.");
        }

        return string.Join(Path.DirectorySeparatorChar, segments);
    }

    private static string GetParent(string relativePath) =>
        Path.GetDirectoryName(relativePath) ?? string.Empty;

    private static string GetLeaf(string relativePath) => Path.GetFileName(relativePath);

    private sealed record ValidatedManifest(
        string RootPath,
        ulong VolumeSerialNumber,
        string FileId,
        IReadOnlyList<ValidatedObject> Objects);

    private sealed record ValidatedObject(
        OwnedObject Source,
        string RelativePath,
        string FullPath,
        int Depth);

    private enum DirectoryStateStatus
    {
        Present,
        Absent,
        Pending,
        Unsafe,
    }

    private sealed class DirectoryState : IDisposable
    {
        public DirectoryState(
            string objectId,
            string relativePath,
            string fullPath,
            int depth,
            SafeFileHandle handle)
        {
            ObjectId = objectId;
            RelativePath = relativePath;
            FullPath = fullPath;
            Depth = depth;
            Handle = handle;
            Status = DirectoryStateStatus.Present;
        }

        private DirectoryState(
            ValidatedObject item,
            DirectoryStateStatus status,
            int win32Code)
        {
            ObjectId = item.Source.ObjectId;
            RelativePath = item.RelativePath;
            FullPath = item.FullPath;
            Depth = item.Depth;
            Status = status;
            Win32Code = win32Code;
        }

        public string ObjectId { get; }
        public string RelativePath { get; }
        public string FullPath { get; }
        public int Depth { get; }
        public SafeFileHandle? Handle { get; private set; }
        public DirectoryStateStatus Status { get; }
        public int Win32Code { get; }
        public bool IsSafeAndPresent =>
            Status == DirectoryStateStatus.Present && Handle is { IsInvalid: false };

        public static DirectoryState Blocked(
            ValidatedObject item,
            DirectoryStateStatus status,
            int win32Code) => new(item, status, win32Code);

        public void Dispose()
        {
            Handle?.Dispose();
            Handle = null;
        }
    }

    private sealed class ExecutionContext
    {
        private readonly List<DeletionOutcome> _outcomes = [];
        private readonly HashSet<string> _objectIds = new(StringComparer.Ordinal);

        public bool HasFailure { get; private set; }
        public bool HasPending { get; private set; }

        public bool Contains(string objectId) => _objectIds.Contains(objectId);

        public void Add(
            string objectId,
            string relativePath,
            DeletionOutcomeStatus status,
            string reason,
            int win32Code)
        {
            if (!_objectIds.Add(objectId))
            {
                return;
            }

            _outcomes.Add(new DeletionOutcome(
                _outcomes.Count + 1,
                objectId,
                relativePath,
                status,
                reason,
                win32Code));
            HasFailure |= status is DeletionOutcomeStatus.Preserved or
                DeletionOutcomeStatus.Failed;
            HasPending |= status == DeletionOutcomeStatus.PendingReboot;
        }

        public DeletionReport CreateReport()
        {
            DeletionStatus status = HasFailure
                ? DeletionStatus.Failed
                : HasPending
                    ? DeletionStatus.PendingReboot
                    : DeletionStatus.Completed;
            return new DeletionReport(status, _outcomes.ToArray());
        }
    }
}
