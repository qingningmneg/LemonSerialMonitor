using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace Lemon.UninstallHelper.Security;

internal static class NativeMethods
{
    internal const uint DeleteAccess = 0x00010000;
    internal const uint FileReadData = 0x00000001;
    internal const uint FileReadAttributes = 0x00000080;
    internal const uint FileAttributeDirectory = 0x00000010;
    internal const uint FileAttributeReparsePoint = 0x00000400;
    internal const int ErrorFileNotFound = 2;
    internal const int ErrorPathNotFound = 3;
    internal const int ErrorAccessDenied = 5;
    internal const int ErrorNotSupported = 50;
    internal const int ErrorInvalidParameter = 87;
    internal const int ErrorSharingViolation = 32;
    internal const int ErrorLockViolation = 33;
    internal const int ErrorDirNotEmpty = 145;
    internal const int ErrorHandleEof = 38;

    private const uint OpenExisting = 3;
    private const uint FileFlagOpenReparsePoint = 0x00200000;
    private const uint FileFlagBackupSemantics = 0x02000000;
    private const uint FileNameNormalized = 0;
    private const uint VolumeNameDos = 0;
    private const uint FileDispositionDelete = 0x00000001;
    private const uint FileDispositionIgnoreReadonlyAttribute = 0x00000010;

    internal static SafeFileHandle OpenNoFollow(
        string path,
        uint desiredAccess,
        FileShare share,
        out int error)
    {
        SafeFileHandle handle = CreateFileW(
            path,
            desiredAccess,
            share,
            IntPtr.Zero,
            OpenExisting,
            FileFlagOpenReparsePoint | FileFlagBackupSemantics,
            IntPtr.Zero);
        error = handle.IsInvalid ? Marshal.GetLastWin32Error() : 0;
        return handle;
    }

    internal static FileAttributeTagInfo GetAttributeTagInfo(SafeFileHandle handle)
    {
        if (!GetFileInformationByHandleExAttribute(
                handle,
                FileInfoByHandleClass.FileAttributeTagInfo,
                out FileAttributeTagInfo value,
                (uint)Marshal.SizeOf<FileAttributeTagInfo>()))
        {
            throw Win32("Unable to query file attributes", Marshal.GetLastWin32Error());
        }

        return value;
    }

    internal static ByHandleFileInformation GetBasicInformation(SafeFileHandle handle)
    {
        if (!GetFileInformationByHandle(handle, out ByHandleFileInformation value))
        {
            throw Win32("Unable to query file identity", Marshal.GetLastWin32Error());
        }

        return value;
    }

    internal static unsafe (ulong VolumeSerialNumber, string FileId) GetFileId(
        SafeFileHandle handle)
    {
        if (!GetFileInformationByHandleExId(
                handle,
                FileInfoByHandleClass.FileIdInfo,
                out FileIdInfo value,
                (uint)sizeof(FileIdInfo)))
        {
            throw Win32("Unable to query the 128-bit file identity", Marshal.GetLastWin32Error());
        }

        Span<byte> bytes = stackalloc byte[16];
        for (int index = 0; index < bytes.Length; index++)
        {
            bytes[index] = value.FileId[index];
        }

        return (value.VolumeSerialNumber, Convert.ToHexString(bytes).ToLowerInvariant());
    }

    internal static string GetFinalPath(SafeFileHandle handle)
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
                throw Win32("Unable to resolve the final handle path", Marshal.GetLastWin32Error());
            }

            if (length < buffer.Capacity)
            {
                return buffer.ToString();
            }

            buffer.Capacity = checked((int)length + 1);
        }
    }

    internal static bool TryMarkDelete(SafeFileHandle handle, out int error)
    {
        var extended = new FileDispositionInfoEx
        {
            Flags = FileDispositionDelete | FileDispositionIgnoreReadonlyAttribute,
        };
        if (SetFileInformationByHandleDispositionEx(
                handle,
                FileInfoByHandleClass.FileDispositionInfoEx,
                ref extended,
                (uint)Marshal.SizeOf<FileDispositionInfoEx>()))
        {
            error = 0;
            return true;
        }

        error = Marshal.GetLastWin32Error();
        if (error is not (ErrorInvalidParameter or ErrorNotSupported))
        {
            return false;
        }

        var basic = new FileDispositionInfo { DeleteFile = 1 };
        if (SetFileInformationByHandleDisposition(
                handle,
                FileInfoByHandleClass.FileDispositionInfo,
                ref basic,
                (uint)Marshal.SizeOf<FileDispositionInfo>()))
        {
            error = 0;
            return true;
        }

        error = Marshal.GetLastWin32Error();
        return false;
    }

    internal static bool HasUnexpectedDataStreams(string path, bool directory)
    {
        SafeFindHandle search = FindFirstStreamW(
            path,
            StreamInfoLevels.FindStreamInfoStandard,
            out Win32FindStreamData stream,
            0);
        if (search.IsInvalid)
        {
            int error = Marshal.GetLastWin32Error();
            search.Dispose();
            if (error is ErrorHandleEof or ErrorInvalidParameter)
            {
                return false;
            }

            throw Win32("Unable to enumerate data streams", error);
        }

        using (search)
        {
            do
            {
                if (directory || !string.Equals(
                        stream.StreamName,
                        "::$DATA",
                        StringComparison.Ordinal))
                {
                    return true;
                }
            }
            while (FindNextStreamW(search, out stream));

            int error = Marshal.GetLastWin32Error();
            if (error != ErrorHandleEof)
            {
                throw Win32("Unable to complete data stream enumeration", error);
            }
        }

        return false;
    }

    internal static IOException Win32(string message, int error) =>
        new(message, new System.ComponentModel.Win32Exception(error));

    internal enum FileInfoByHandleClass
    {
        FileDispositionInfo = 4,
        FileAttributeTagInfo = 9,
        FileIdInfo = 18,
        FileDispositionInfoEx = 21,
    }

    internal enum StreamInfoLevels
    {
        FindStreamInfoStandard = 0,
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct FileAttributeTagInfo
    {
        public uint FileAttributes;
        public uint ReparseTag;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct NativeFileTime
    {
        public uint LowDateTime;
        public uint HighDateTime;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct ByHandleFileInformation
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

        public long Length => checked(((long)FileSizeHigh << 32) | FileSizeLow);
    }

    [StructLayout(LayoutKind.Sequential)]
    internal unsafe struct FileIdInfo
    {
        public ulong VolumeSerialNumber;
        public fixed byte FileId[16];
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct FileDispositionInfoEx
    {
        public uint Flags;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    internal struct FileDispositionInfo
    {
        public byte DeleteFile;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    internal struct Win32FindStreamData
    {
        public long StreamSize;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 296)]
        public string StreamName;
    }

    internal sealed class SafeFindHandle : SafeHandleZeroOrMinusOneIsInvalid
    {
        private SafeFindHandle()
            : base(ownsHandle: true)
        {
        }

        protected override bool ReleaseHandle() => FindClose(handle);
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFileW(
        string fileName,
        uint desiredAccess,
        FileShare shareMode,
        IntPtr securityAttributes,
        uint creationDisposition,
        uint flagsAndAttributes,
        IntPtr templateFile);

    [DllImport("kernel32.dll", EntryPoint = "GetFileInformationByHandleEx", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileInformationByHandleExAttribute(
        SafeFileHandle file,
        FileInfoByHandleClass fileInformationClass,
        out FileAttributeTagInfo fileInformation,
        uint bufferSize);

    [DllImport("kernel32.dll", EntryPoint = "GetFileInformationByHandleEx", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileInformationByHandleExId(
        SafeFileHandle file,
        FileInfoByHandleClass fileInformationClass,
        out FileIdInfo fileInformation,
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

    [DllImport("kernel32.dll", EntryPoint = "SetFileInformationByHandle", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetFileInformationByHandleDispositionEx(
        SafeFileHandle file,
        FileInfoByHandleClass fileInformationClass,
        ref FileDispositionInfoEx fileInformation,
        uint bufferSize);

    [DllImport("kernel32.dll", EntryPoint = "SetFileInformationByHandle", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetFileInformationByHandleDisposition(
        SafeFileHandle file,
        FileInfoByHandleClass fileInformationClass,
        ref FileDispositionInfo fileInformation,
        uint bufferSize);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFindHandle FindFirstStreamW(
        string fileName,
        StreamInfoLevels infoLevel,
        out Win32FindStreamData findStreamData,
        uint flags);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool FindNextStreamW(
        SafeFindHandle findStream,
        out Win32FindStreamData findStreamData);

    [DllImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool FindClose(IntPtr findFile);
}
