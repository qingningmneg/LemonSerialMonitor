using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace CommMonitor.Service.Ipc;

#pragma warning disable CA1416 // Construction is guarded by OperatingSystem.IsWindows().
internal sealed class ServiceStorageBoundary : IDisposable
{
    private readonly object _gate = new();
    private readonly Dictionary<string, DirectoryLease> _directoryLeases =
        new(StringComparer.OrdinalIgnoreCase);
    private readonly HashSet<SecurityIdentifier> _trustedOwners;
    private bool _disposed;

    private ServiceStorageBoundary(
        string managedRoot,
        string sessionRoot,
        string exportRoot)
    {
        ManagedRoot = Path.GetFullPath(managedRoot);
        SessionRoot = Path.GetFullPath(sessionRoot);
        ExportRoot = Path.GetFullPath(exportRoot);
        EnsureDirectoryIsContained(SessionRoot, ManagedRoot, nameof(sessionRoot));
        EnsureDirectoryIsContained(ExportRoot, ManagedRoot, nameof(exportRoot));

        SecurityIdentifier currentIdentity = WindowsIdentity.GetCurrent().User ??
            throw new IOException("The service process does not have a Windows user SID.");
        _trustedOwners =
        [
            currentIdentity,
            new SecurityIdentifier(WellKnownSidType.LocalSystemSid, domainSid: null),
            new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, domainSid: null),
        ];

        try
        {
            EnsureNoReparsePointsInExistingChain(ManagedRoot);
            EnsureDirectoryTree(
                ManagedRoot,
                managedBoundary: null,
                DirectoryAclProfile.ManagedRoot,
                DirectoryAclProfile.ManagedRoot);
            string resolvedManagedRoot = GetRequiredLease(ManagedRoot).ResolvedPath;
            if (!PathsEqual(resolvedManagedRoot, ManagedRoot))
            {
                throw new IOException(
                    $"The managed storage root resolves outside its configured path: {ManagedRoot}");
            }

            EnsureDirectoryTree(
                SessionRoot,
                ManagedRoot,
                DirectoryAclProfile.Private,
                DirectoryAclProfile.Private);
            EnsureDirectoryTree(
                ExportRoot,
                ManagedRoot,
                DirectoryAclProfile.ExportRead,
                DirectoryAclProfile.Traverse);
            VerifyDirectoryLeases();
        }
        catch
        {
            Dispose();
            throw;
        }
    }

    public string ManagedRoot { get; }

    public string SessionRoot { get; }

    public string ExportRoot { get; }

    public static ServiceStorageBoundary Open(
        string managedRoot,
        string sessionRoot,
        string exportRoot)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(managedRoot);
        ArgumentException.ThrowIfNullOrWhiteSpace(sessionRoot);
        ArgumentException.ThrowIfNullOrWhiteSpace(exportRoot);
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException(
                "CommMonitor service storage hardening requires Windows.");
        }

        return new ServiceStorageBoundary(managedRoot, sessionRoot, exportRoot);
    }

    public void VerifySessionPath(string path)
    {
        lock (_gate)
        {
            ThrowIfDisposed();
            VerifyDirectoryLeases();
            EnsureFileIsDirectChild(path, SessionRoot, nameof(path));
            ValidateExistingFile(path, SessionRoot, publicRead: false);
            ValidateExistingFile(path + "-wal", SessionRoot, publicRead: false);
            ValidateExistingFile(path + "-shm", SessionRoot, publicRead: false);
            ValidateExistingFile(path + "-journal", SessionRoot, publicRead: false);
        }
    }

    public void VerifyExportPath(string path)
    {
        lock (_gate)
        {
            ThrowIfDisposed();
            VerifyDirectoryLeases();
            EnsureFileIsDirectChild(path, ExportRoot, nameof(path));
            ValidateExistingFile(path, ExportRoot, publicRead: true);
        }
    }

    public void Dispose()
    {
        lock (_gate)
        {
            if (_disposed)
            {
                return;
            }

            _disposed = true;
            foreach (DirectoryLease lease in _directoryLeases.Values.Reverse())
            {
                lease.Dispose();
            }

            _directoryLeases.Clear();
        }
    }

    private void EnsureDirectoryTree(
        string targetPath,
        string? managedBoundary,
        DirectoryAclProfile targetProfile,
        DirectoryAclProfile intermediateProfile)
    {
        string canonicalTarget = Path.GetFullPath(targetPath);
        string startPath;
        if (managedBoundary is null)
        {
            string root = Path.GetPathRoot(canonicalTarget) ??
                throw new IOException($"The path does not have a filesystem root: {canonicalTarget}");
            if (PathsEqual(root, canonicalTarget))
            {
                throw new IOException("A filesystem root cannot be used as managed service storage.");
            }

            startPath = root;
        }
        else
        {
            startPath = Path.GetFullPath(managedBoundary);
            EnsureDirectoryIsContained(canonicalTarget, startPath, nameof(targetPath));
        }

        string relative = Path.GetRelativePath(startPath, canonicalTarget);
        string current = startPath;
        foreach (string component in relative.Split(
                     [Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar],
                     StringSplitOptions.RemoveEmptyEntries))
        {
            current = Path.Combine(current, component);
            if (managedBoundary is null && !PathsEqual(current, canonicalTarget))
            {
                continue;
            }

            EnsureSecureDirectory(
                current,
                PathsEqual(current, canonicalTarget) ? targetProfile : intermediateProfile);
        }

        if (!_directoryLeases.ContainsKey(canonicalTarget))
        {
            EnsureSecureDirectory(canonicalTarget, targetProfile);
        }
    }

    private void EnsureSecureDirectory(string path, DirectoryAclProfile profile)
    {
        string canonicalPath = Path.GetFullPath(path);
        if (_directoryLeases.ContainsKey(canonicalPath))
        {
            return;
        }

        CreateDirectoryWithProtectedAcl(canonicalPath, profile);
        DirectoryLease lease = OpenDirectoryLease(canonicalPath);
        try
        {
            ValidateTrustedOwner(canonicalPath, isDirectory: true);
            ApplyProtectedAcl(lease.Handle, CreateProtectedDirectorySecurity(profile));
            VerifyDirectoryLease(lease);

            if (_directoryLeases.Count > 0)
            {
                string resolvedManaged = GetRequiredLease(ManagedRoot).ResolvedPath;
                EnsureDirectoryIsContained(
                    lease.ResolvedPath,
                    resolvedManaged,
                    nameof(path),
                    allowEqual: true);
            }

            _directoryLeases.Add(canonicalPath, lease);
        }
        catch
        {
            lease.Dispose();
            throw;
        }
    }

    private void CreateDirectoryWithProtectedAcl(
        string path,
        DirectoryAclProfile profile)
    {
        if (Directory.Exists(path))
        {
            return;
        }

        DirectorySecurity security = CreateProtectedDirectorySecurity(profile);
        byte[] descriptor = security.GetSecurityDescriptorBinaryForm();
        GCHandle descriptorHandle = GCHandle.Alloc(descriptor, GCHandleType.Pinned);
        try
        {
            var attributes = new SecurityAttributes
            {
                Length = Marshal.SizeOf<SecurityAttributes>(),
                SecurityDescriptor = descriptorHandle.AddrOfPinnedObject(),
                InheritHandle = false,
            };
            if (!CreateDirectoryW(path, ref attributes))
            {
                int error = Marshal.GetLastWin32Error();
                if (error != ErrorAlreadyExists)
                {
                    throw CreateIoException($"Unable to create secure directory {path}.", error);
                }
            }
        }
        finally
        {
            descriptorHandle.Free();
        }
    }

    private DirectorySecurity CreateProtectedDirectorySecurity(DirectoryAclProfile profile)
    {
        var security = new DirectorySecurity();
        security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        security.SetOwner(WindowsIdentity.GetCurrent().User!);
        foreach (SecurityIdentifier sid in _trustedOwners)
        {
            security.AddAccessRule(new FileSystemAccessRule(
                sid,
                FileSystemRights.FullControl,
                InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit,
                PropagationFlags.None,
                AccessControlType.Allow));
        }

        if (profile != DirectoryAclProfile.Private)
        {
            FileSystemRights rights = profile == DirectoryAclProfile.ExportRead
                ? FileSystemRights.ReadAndExecute
                : FileSystemRights.Traverse |
                  FileSystemRights.ReadAttributes |
                  FileSystemRights.ReadExtendedAttributes |
                  FileSystemRights.ReadPermissions;
            InheritanceFlags inheritance = profile == DirectoryAclProfile.ExportRead
                ? InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit
                : InheritanceFlags.None;
            security.AddAccessRule(new FileSystemAccessRule(
                new SecurityIdentifier(WellKnownSidType.BuiltinUsersSid, domainSid: null),
                rights,
                inheritance,
                PropagationFlags.None,
                AccessControlType.Allow));
        }

        return security;
    }

    private FileSecurity CreateProtectedFileSecurity(bool publicRead)
    {
        var security = new FileSecurity();
        security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        security.SetOwner(WindowsIdentity.GetCurrent().User!);
        foreach (SecurityIdentifier sid in _trustedOwners)
        {
            security.AddAccessRule(new FileSystemAccessRule(
                sid,
                FileSystemRights.FullControl,
                AccessControlType.Allow));
        }

        if (publicRead)
        {
            security.AddAccessRule(new FileSystemAccessRule(
                new SecurityIdentifier(WellKnownSidType.BuiltinUsersSid, domainSid: null),
                FileSystemRights.Read,
                AccessControlType.Allow));
        }

        return security;
    }

    private DirectoryLease OpenDirectoryLease(string path)
    {
        SafeFileHandle handle = CreateFileW(
            path,
            ReadControl | WriteDac | FileReadAttributes,
            FileShare.Read,
            IntPtr.Zero,
            OpenExisting,
            FileFlagOpenReparsePoint | FileFlagBackupSemantics,
            IntPtr.Zero);
        if (handle.IsInvalid)
        {
            int error = Marshal.GetLastWin32Error();
            handle.Dispose();
            throw CreateIoException($"Unable to lock managed directory {path}.", error);
        }

        FileAttributeTagInfo attributes = GetAttributeTagInfo(handle, path);
        if ((attributes.FileAttributes & FileAttributeReparsePoint) != 0)
        {
            handle.Dispose();
            throw new IOException($"Managed directory is a reparse point: {path}");
        }

        if ((attributes.FileAttributes & FileAttributeDirectory) == 0)
        {
            handle.Dispose();
            throw new IOException($"Managed storage path is not a directory: {path}");
        }

        return new DirectoryLease(path, NormalizeFinalPath(GetFinalPath(handle)), handle);
    }

    private void ValidateTrustedOwner(string path, bool isDirectory)
    {
        FileSystemSecurity security = isDirectory
            ? new DirectoryInfo(path).GetAccessControl(AccessControlSections.Owner)
            : new FileInfo(path).GetAccessControl(AccessControlSections.Owner);
        SecurityIdentifier? owner = security.GetOwner(typeof(SecurityIdentifier)) as SecurityIdentifier;
        if (owner is null || !_trustedOwners.Contains(owner))
        {
            throw new IOException(
                $"Managed storage path has an untrusted owner and will not be used: {path}");
        }
    }

    private void ValidateExistingFile(
        string path,
        string expectedRoot,
        bool publicRead)
    {
        SafeFileHandle handle = CreateFileW(
            path,
            ReadControl | WriteDac | FileReadAttributes,
            FileShare.Read,
            IntPtr.Zero,
            OpenExisting,
            FileFlagOpenReparsePoint,
            IntPtr.Zero);
        if (handle.IsInvalid)
        {
            int error = Marshal.GetLastWin32Error();
            handle.Dispose();
            if (error is ErrorFileNotFound or ErrorPathNotFound)
            {
                return;
            }

            throw CreateIoException($"Unable to lock managed file {path}.", error);
        }

        using (handle)
        {
            FileAttributeTagInfo attributes = GetAttributeTagInfo(handle, path);
            if ((attributes.FileAttributes & FileAttributeReparsePoint) != 0)
            {
                throw new IOException(
                    $"Managed file is a reparse link and will not be used: {path}");
            }

            if ((attributes.FileAttributes & FileAttributeDirectory) != 0)
            {
                throw new IOException($"Managed file path is a directory: {path}");
            }

            if (!GetFileInformationByHandle(handle, out ByHandleFileInformation information))
            {
                throw CreateIoException(
                    $"Unable to inspect managed file {path}.",
                    Marshal.GetLastWin32Error());
            }

            if (information.NumberOfLinks != 1)
            {
                throw new IOException(
                    $"Managed file is a hard link and will not be written: {path}");
            }

            string resolvedPath = NormalizeFinalPath(GetFinalPath(handle));
            EnsureFileIsDirectChild(resolvedPath, expectedRoot, nameof(path));
            if (!PathsEqual(resolvedPath, path))
            {
                throw new IOException(
                    $"Managed file resolves to a different path and will not be used: {path}");
            }

            ValidateTrustedOwner(path, isDirectory: false);
            ApplyProtectedAcl(handle, CreateProtectedFileSecurity(publicRead));
        }
    }

    private static void ApplyProtectedAcl(
        SafeFileHandle handle,
        FileSystemSecurity security)
    {
        var descriptor = new RawSecurityDescriptor(
            security.GetSecurityDescriptorBinaryForm(),
            0);
        GenericAcl dacl = descriptor.DiscretionaryAcl ??
            throw new IOException("The managed storage ACL is missing its DACL.");
        byte[] daclBytes = new byte[dacl.BinaryLength];
        dacl.GetBinaryForm(daclBytes, 0);
        GCHandle daclHandle = GCHandle.Alloc(daclBytes, GCHandleType.Pinned);
        try
        {
            uint result = SetSecurityInfo(
                handle,
                SecurityObjectType.FileObject,
                SecurityInformation.Dacl | SecurityInformation.ProtectedDacl,
                IntPtr.Zero,
                IntPtr.Zero,
                daclHandle.AddrOfPinnedObject(),
                IntPtr.Zero);
            if (result != ErrorSuccess)
            {
                throw CreateIoException("Unable to protect a managed storage ACL.", (int)result);
            }
        }
        finally
        {
            daclHandle.Free();
        }
    }

    private void EnsureNoReparsePointsInExistingChain(string path)
    {
        string canonicalPath = Path.GetFullPath(path);
        string root = Path.GetPathRoot(canonicalPath) ??
            throw new IOException($"The path does not have a filesystem root: {canonicalPath}");
        string relative = Path.GetRelativePath(root, canonicalPath);
        string current = root;

        foreach (string component in relative.Split(
                     [Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar],
                     StringSplitOptions.RemoveEmptyEntries))
        {
            current = Path.Combine(current, component);
            if (!Directory.Exists(current) && !File.Exists(current))
            {
                break;
            }

            FileAttributes attributes = File.GetAttributes(current);
            if ((attributes & FileAttributes.ReparsePoint) != 0)
            {
                throw new IOException($"Managed storage path contains a reparse point: {current}");
            }

            if ((attributes & FileAttributes.Directory) == 0)
            {
                throw new IOException($"Managed storage path component is not a directory: {current}");
            }
        }
    }

    private void VerifyDirectoryLeases()
    {
        foreach (DirectoryLease lease in _directoryLeases.Values)
        {
            VerifyDirectoryLease(lease);
        }
    }

    private static void VerifyDirectoryLease(DirectoryLease lease)
    {
        FileAttributeTagInfo attributes = GetAttributeTagInfo(lease.Handle, lease.Path);
        if ((attributes.FileAttributes & FileAttributeReparsePoint) != 0 ||
            (attributes.FileAttributes & FileAttributeDirectory) == 0)
        {
            throw new IOException(
                $"Managed directory changed into an unsafe filesystem object: {lease.Path}");
        }

        string resolvedPath = NormalizeFinalPath(GetFinalPath(lease.Handle));
        if (!PathsEqual(resolvedPath, lease.ResolvedPath))
        {
            throw new IOException($"Managed directory resolved path changed: {lease.Path}");
        }
    }

    private static FileAttributeTagInfo GetAttributeTagInfo(
        SafeFileHandle handle,
        string displayPath)
    {
        if (!GetFileInformationByHandleEx(
                handle,
                FileInfoByHandleClass.FileAttributeTagInfo,
                out FileAttributeTagInfo attributes,
                (uint)Marshal.SizeOf<FileAttributeTagInfo>()))
        {
            throw CreateIoException(
                $"Unable to inspect managed storage path {displayPath}.",
                Marshal.GetLastWin32Error());
        }

        return attributes;
    }

    private static string GetFinalPath(SafeFileHandle handle)
    {
        var buffer = new StringBuilder(512);
        while (true)
        {
            uint length = GetFinalPathNameByHandleW(
                handle,
                buffer,
                (uint)buffer.Capacity,
                FileNameNormalized | VolumeNameDos);
            if (length == 0)
            {
                throw CreateIoException(
                    "Unable to resolve a managed storage path.",
                    Marshal.GetLastWin32Error());
            }

            if (length < buffer.Capacity)
            {
                return buffer.ToString();
            }

            buffer.Capacity = checked((int)length + 1);
        }
    }

    private static string NormalizeFinalPath(string path)
    {
        const string uncPrefix = @"\\?\UNC\";
        const string devicePrefix = @"\\?\";
        string normalized = path.StartsWith(uncPrefix, StringComparison.OrdinalIgnoreCase)
            ? @"\\" + path[uncPrefix.Length..]
            : path.StartsWith(devicePrefix, StringComparison.OrdinalIgnoreCase)
                ? path[devicePrefix.Length..]
                : path;
        return Path.TrimEndingDirectorySeparator(Path.GetFullPath(normalized));
    }

    private static void EnsureFileIsDirectChild(
        string path,
        string root,
        string parameterName)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        string canonicalPath = Path.GetFullPath(path);
        string? parent = Path.GetDirectoryName(canonicalPath);
        if (parent is null || !PathsEqual(parent, root))
        {
            throw new ArgumentException(
                "The file must be a direct child of its managed storage directory.",
                parameterName);
        }
    }

    private static void EnsureDirectoryIsContained(
        string path,
        string root,
        string parameterName,
        bool allowEqual = true)
    {
        string canonicalPath = Path.TrimEndingDirectorySeparator(Path.GetFullPath(path));
        string canonicalRoot = Path.TrimEndingDirectorySeparator(Path.GetFullPath(root));
        if (allowEqual && PathsEqual(canonicalPath, canonicalRoot))
        {
            return;
        }

        string rootPrefix = canonicalRoot + Path.DirectorySeparatorChar;
        if (!canonicalPath.StartsWith(rootPrefix, StringComparison.OrdinalIgnoreCase))
        {
            throw new ArgumentException(
                "Managed storage directories must remain inside the storage root.",
                parameterName);
        }
    }

    private DirectoryLease GetRequiredLease(string path) =>
        _directoryLeases[Path.GetFullPath(path)];

    private static bool PathsEqual(string left, string right) =>
        string.Equals(
            Path.TrimEndingDirectorySeparator(Path.GetFullPath(left)),
            Path.TrimEndingDirectorySeparator(Path.GetFullPath(right)),
            StringComparison.OrdinalIgnoreCase);

    private void ThrowIfDisposed()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
    }

    private static IOException CreateIoException(string message, int error) =>
        new(message, new Win32Exception(error));

    private sealed class DirectoryLease(
        string path,
        string resolvedPath,
        SafeFileHandle handle) : IDisposable
    {
        public string Path { get; } = path;
        public string ResolvedPath { get; } = resolvedPath;
        public SafeFileHandle Handle { get; } = handle;

        public void Dispose() => Handle.Dispose();
    }

    private const int ErrorSuccess = 0;
    private const int ErrorFileNotFound = 2;
    private const int ErrorPathNotFound = 3;
    private const int ErrorAlreadyExists = 183;
    private const uint ReadControl = 0x00020000;
    private const uint WriteDac = 0x00040000;
    private const uint FileReadAttributes = 0x00000080;
    private const uint OpenExisting = 3;
    private const uint FileAttributeDirectory = 0x00000010;
    private const uint FileAttributeReparsePoint = 0x00000400;
    private const uint FileFlagOpenReparsePoint = 0x00200000;
    private const uint FileFlagBackupSemantics = 0x02000000;
    private const uint FileNameNormalized = 0x0;
    private const uint VolumeNameDos = 0x0;

    [Flags]
    private enum SecurityInformation : uint
    {
        Dacl = 0x00000004,
        ProtectedDacl = 0x80000000,
    }

    private enum SecurityObjectType
    {
        FileObject = 1,
    }

    private enum FileInfoByHandleClass
    {
        FileAttributeTagInfo = 9,
    }

    private enum DirectoryAclProfile
    {
        Private,
        ManagedRoot,
        Traverse,
        ExportRead,
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct SecurityAttributes
    {
        public int Length;
        public IntPtr SecurityDescriptor;

        [MarshalAs(UnmanagedType.Bool)]
        public bool InheritHandle;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct FileAttributeTagInfo
    {
        public uint FileAttributes;
        public uint ReparseTag;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeFileTime
    {
        public uint LowDateTime;
        public uint HighDateTime;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ByHandleFileInformation
    {
        public uint FileAttributes;
        public NativeFileTime CreationTime;
        public NativeFileTime LastAccessTime;
        public NativeFileTime LastWriteTime;
        public uint VolumeSerialNumber;
        public uint FileSizeHigh;
        public uint FileSizeLow;
        public uint NumberOfLinks;
        public uint FileIndexHigh;
        public uint FileIndexLow;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CreateDirectoryW(
        string path,
        ref SecurityAttributes securityAttributes);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFileW(
        string fileName,
        uint desiredAccess,
        FileShare shareMode,
        IntPtr securityAttributes,
        uint creationDisposition,
        uint flagsAndAttributes,
        IntPtr templateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileInformationByHandleEx(
        SafeFileHandle file,
        FileInfoByHandleClass fileInformationClass,
        out FileAttributeTagInfo fileInformation,
        uint bufferSize);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileInformationByHandle(
        SafeFileHandle file,
        out ByHandleFileInformation fileInformation);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetFinalPathNameByHandleW(
        SafeFileHandle file,
        StringBuilder filePath,
        uint filePathLength,
        uint flags);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern uint SetSecurityInfo(
        SafeFileHandle handle,
        SecurityObjectType objectType,
        SecurityInformation securityInformation,
        IntPtr owner,
        IntPtr group,
        IntPtr dacl,
        IntPtr sacl);
}
#pragma warning restore CA1416
