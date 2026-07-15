using System.ComponentModel;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace CommMonitor.Service.Ipc;

[SupportedOSPlatform("windows")]
internal sealed class WindowsPipeClientIdentityProvider : IPipeClientIdentityProvider
{
    private const uint ProcessQueryLimitedInformation = 0x1000;
    private const uint TokenQuery = 0x0008;
    private const int TokenUserClass = 1;
    private const int TokenStatisticsClass = 10;

    public PipeClientIdentity GetIdentity(NamedPipeServerStream pipe)
    {
        ArgumentNullException.ThrowIfNull(pipe);
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException(
                "Named-pipe client identity verification requires Windows.");
        }

        if (!pipe.IsConnected)
        {
            throw new InvalidOperationException("The named pipe is not connected.");
        }

        if (!GetNamedPipeClientProcessId(pipe.SafePipeHandle, out uint processId))
        {
            throw NativeFailure("Unable to identify the named-pipe client process");
        }

        using SafeProcessHandle process = OpenProcess(
            ProcessQueryLimitedInformation,
            inheritHandle: false,
            processId);
        if (process.IsInvalid)
        {
            throw NativeFailure("Unable to open the named-pipe client process");
        }

        string imagePath = QueryImagePath(process);
        using SafeAccessTokenHandle token = OpenToken(process);
        string sid = QuerySid(token);
        ulong logonLuid = QueryLogonLuid(token);

        if (!GetNamedPipeClientProcessId(pipe.SafePipeHandle, out uint confirmedProcessId) ||
            confirmedProcessId != processId)
        {
            throw new UnauthorizedAccessException(
                "The named-pipe client identity changed during verification.");
        }

        string sha256;
        using (FileStream image = new(
                   imagePath,
                   FileMode.Open,
                   FileAccess.Read,
                   FileShare.Read | FileShare.Delete,
                   bufferSize: 128 * 1024,
                   FileOptions.SequentialScan))
        {
            sha256 = Convert.ToHexString(SHA256.HashData(image)).ToLowerInvariant();
        }

        return new PipeClientIdentity(
            checked((int)processId),
            sid,
            logonLuid,
            Path.GetFullPath(imagePath),
            sha256);
    }

    private static string QueryImagePath(SafeProcessHandle process)
    {
        int capacity = 32768;
        var buffer = new StringBuilder(capacity);
        if (!QueryFullProcessImageNameW(process, 0, buffer, ref capacity))
        {
            throw NativeFailure("Unable to resolve the named-pipe client image path");
        }

        return buffer.ToString();
    }

    private static SafeAccessTokenHandle OpenToken(SafeProcessHandle process)
    {
        if (!OpenProcessToken(process, TokenQuery, out SafeAccessTokenHandle token))
        {
            throw NativeFailure("Unable to open the named-pipe client token");
        }

        return token;
    }

    private static string QuerySid(SafeAccessTokenHandle token)
    {
        IntPtr buffer = QueryTokenInformation(token, TokenUserClass, out _);
        try
        {
            TokenUser tokenUser = Marshal.PtrToStructure<TokenUser>(buffer);
            return new SecurityIdentifier(tokenUser.User.Sid).Value;
        }
        finally
        {
            Marshal.FreeHGlobal(buffer);
        }
    }

    private static ulong QueryLogonLuid(SafeAccessTokenHandle token)
    {
        IntPtr buffer = QueryTokenInformation(token, TokenStatisticsClass, out _);
        try
        {
            TokenStatistics statistics = Marshal.PtrToStructure<TokenStatistics>(buffer);
            return statistics.AuthenticationId.ToUInt64();
        }
        finally
        {
            Marshal.FreeHGlobal(buffer);
        }
    }

    private static IntPtr QueryTokenInformation(
        SafeAccessTokenHandle token,
        int informationClass,
        out uint length)
    {
        _ = GetTokenInformation(token, informationClass, IntPtr.Zero, 0, out length);
        int error = Marshal.GetLastWin32Error();
        if (length == 0 || error != 122)
        {
            throw NativeFailure("Unable to size named-pipe client token information", error);
        }

        IntPtr buffer = Marshal.AllocHGlobal(checked((int)length));
        if (!GetTokenInformation(token, informationClass, buffer, length, out _))
        {
            error = Marshal.GetLastWin32Error();
            Marshal.FreeHGlobal(buffer);
            throw NativeFailure("Unable to read named-pipe client token information", error);
        }

        return buffer;
    }

    private static Win32Exception NativeFailure(string message) =>
        NativeFailure(message, Marshal.GetLastWin32Error());

    private static Win32Exception NativeFailure(string message, int error) =>
        new(error, $"{message}: {new Win32Exception(error).Message}");

    [StructLayout(LayoutKind.Sequential)]
    private readonly struct SidAndAttributes
    {
        public readonly IntPtr Sid;
        public readonly uint Attributes;
    }

    [StructLayout(LayoutKind.Sequential)]
    private readonly struct TokenUser
    {
        public readonly SidAndAttributes User;
    }

    [StructLayout(LayoutKind.Sequential)]
    private readonly struct Luid
    {
        public readonly uint LowPart;
        public readonly int HighPart;

        public ulong ToUInt64() =>
            ((ulong)unchecked((uint)HighPart) << 32) | LowPart;
    }

    [StructLayout(LayoutKind.Sequential)]
    private readonly struct TokenStatistics
    {
        public readonly Luid TokenId;
        public readonly Luid AuthenticationId;
        public readonly long ExpirationTime;
        public readonly int TokenType;
        public readonly int ImpersonationLevel;
        public readonly uint DynamicCharged;
        public readonly uint DynamicAvailable;
        public readonly uint GroupCount;
        public readonly uint PrivilegeCount;
        public readonly Luid ModifiedId;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetNamedPipeClientProcessId(
        SafePipeHandle pipe,
        out uint clientProcessId);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern SafeProcessHandle OpenProcess(
        uint desiredAccess,
        [MarshalAs(UnmanagedType.Bool)] bool inheritHandle,
        uint processId);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool QueryFullProcessImageNameW(
        SafeProcessHandle process,
        uint flags,
        StringBuilder executableName,
        ref int size);

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool OpenProcessToken(
        SafeProcessHandle process,
        uint desiredAccess,
        out SafeAccessTokenHandle token);

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetTokenInformation(
        SafeAccessTokenHandle token,
        int tokenInformationClass,
        IntPtr tokenInformation,
        uint tokenInformationLength,
        out uint returnLength);
}
