using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using Microsoft.Win32.SafeHandles;

namespace CommMonitor.Service.Driver;

internal static class NativeMethods
{
    internal const uint GenericRead = 0x80000000;
    internal const uint GenericWrite = 0x40000000;
    internal const uint FileShareRead = 0x00000001;
    internal const uint FileShareWrite = 0x00000002;
    internal const uint OpenExisting = 3;
    internal const uint FileFlagOverlapped = 0x40000000;

    internal const int ErrorSuccess = 0;
    internal const int ErrorFileNotFound = 2;
    internal const int ErrorAccessDenied = 5;
    internal const int ErrorOperationAborted = 995;
    internal const int ErrorIoPending = 997;
    internal const int ErrorNotFound = 1168;

    [DllImport("kernel32.dll", EntryPoint = "CreateFileW", CharSet = CharSet.Unicode,
        SetLastError = true)]
    internal static extern SafeFileHandle CreateFile(
        string fileName,
        uint desiredAccess,
        uint shareMode,
        nint securityAttributes,
        uint creationDisposition,
        uint flagsAndAttributes,
        nint templateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern unsafe bool DeviceIoControl(
        SafeFileHandle device,
        uint ioControlCode,
        void* inputBuffer,
        uint inputBufferSize,
        void* outputBuffer,
        uint outputBufferSize,
        out uint bytesReturned,
        nint overlapped);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool CancelIoEx(
        SafeFileHandle file,
        nint overlapped);
}

internal readonly record struct DriverHandleOpenResult(
    SafeFileHandle Handle,
    int ErrorCode);

internal readonly record struct NativeIoCallResult(
    bool Succeeded,
    int ErrorCode);

internal readonly record struct NativeCancelResult(
    bool Succeeded,
    int ErrorCode);

internal interface IWindowsDriverApi
{
    DriverHandleOpenResult OpenDriver(
        string path,
        uint desiredAccess,
        uint shareMode,
        uint creationDisposition,
        uint flagsAndAttributes);

    NativeIoCallResult DeviceIoControl(
        SafeFileHandle handle,
        uint ioControlCode,
        byte[] input,
        byte[] output,
        nint overlapped);

    NativeCancelResult CancelIoEx(
        SafeFileHandle handle,
        nint overlapped);
}

internal sealed class WindowsDriverApi : IWindowsDriverApi
{
    public DriverHandleOpenResult OpenDriver(
        string path,
        uint desiredAccess,
        uint shareMode,
        uint creationDisposition,
        uint flagsAndAttributes)
    {
        SafeFileHandle handle = NativeMethods.CreateFile(
            path,
            desiredAccess,
            shareMode,
            0,
            creationDisposition,
            flagsAndAttributes,
            0);
        int errorCode = handle.IsInvalid
            ? Marshal.GetLastWin32Error()
            : NativeMethods.ErrorSuccess;
        return new DriverHandleOpenResult(handle, errorCode);
    }

    public unsafe NativeIoCallResult DeviceIoControl(
        SafeFileHandle handle,
        uint ioControlCode,
        byte[] input,
        byte[] output,
        nint overlapped)
    {
        fixed (byte* inputPointer = input)
        fixed (byte* outputPointer = output)
        {
            bool succeeded = NativeMethods.DeviceIoControl(
                handle,
                ioControlCode,
                input.Length == 0 ? null : inputPointer,
                checked((uint)input.Length),
                output.Length == 0 ? null : outputPointer,
                checked((uint)output.Length),
                out _,
                overlapped);
            int errorCode = succeeded
                ? NativeMethods.ErrorSuccess
                : Marshal.GetLastWin32Error();
            return new NativeIoCallResult(succeeded, errorCode);
        }
    }

    public NativeCancelResult CancelIoEx(
        SafeFileHandle handle,
        nint overlapped)
    {
        bool succeeded = NativeMethods.CancelIoEx(handle, overlapped);
        int errorCode = succeeded
            ? NativeMethods.ErrorSuccess
            : Marshal.GetLastWin32Error();
        return new NativeCancelResult(succeeded, errorCode);
    }
}

internal interface IOverlappedBindingFactory
{
    IOverlappedBinding Bind(SafeFileHandle handle);
}

internal interface IOverlappedBinding : IDisposable
{
    nint Allocate(
        Action<uint, uint, nint> callback,
        object? pinData);

    void Free(nint overlapped);
}

internal sealed class ThreadPoolOverlappedBindingFactory : IOverlappedBindingFactory
{
    public IOverlappedBinding Bind(SafeFileHandle handle)
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException(
                "The CommMonitor driver transport requires Windows.");
        }

        return new ThreadPoolOverlappedBinding(
            ThreadPoolBoundHandle.BindHandle(handle));
    }
}

[SupportedOSPlatform("windows")]
internal sealed unsafe class ThreadPoolOverlappedBinding : IOverlappedBinding
{
    private static readonly IOCompletionCallback CompletionCallback = Complete;
    private readonly ThreadPoolBoundHandle _boundHandle;

    public ThreadPoolOverlappedBinding(ThreadPoolBoundHandle boundHandle) =>
        _boundHandle = boundHandle;

    public nint Allocate(
        Action<uint, uint, nint> callback,
        object? pinData)
    {
        ArgumentNullException.ThrowIfNull(callback);
        var state = new CompletionState(callback);
        NativeOverlapped* overlapped = _boundHandle.AllocateNativeOverlapped(
            CompletionCallback,
            state,
            pinData);
        return (nint)overlapped;
    }

    public void Free(nint overlapped) =>
        _boundHandle.FreeNativeOverlapped((NativeOverlapped*)overlapped);

    public void Dispose() => _boundHandle.Dispose();

    private static void Complete(
        uint errorCode,
        uint bytesTransferred,
        NativeOverlapped* overlapped)
    {
        var state = (CompletionState?)ThreadPoolBoundHandle.GetNativeOverlappedState(
            overlapped);
        state?.Callback(errorCode, bytesTransferred, (nint)overlapped);
    }

    private sealed record CompletionState(Action<uint, uint, nint> Callback);
}
