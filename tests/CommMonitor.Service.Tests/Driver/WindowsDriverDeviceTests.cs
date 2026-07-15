using System.ComponentModel;
using Microsoft.Win32.SafeHandles;
using CommMonitor.Service.Driver;

namespace CommMonitor.Service.Tests.Driver;

public sealed class WindowsDriverDeviceTests
{
    [Fact]
    public async Task Factory_opens_the_control_device_with_exact_overlapped_flags()
    {
        var api = new FakeWindowsDriverApi();
        var binding = new FakeOverlappedBinding();
        var factory = new WindowsDriverDeviceFactory(
            api,
            new FakeOverlappedBindingFactory(binding));

        IDriverDevice device = await factory.OpenAsync(CancellationToken.None);

        Assert.Equal(@"\\.\Global\CommMonitorFilter", api.OpenPath);
        Assert.Equal(
            NativeMethods.GenericRead | NativeMethods.GenericWrite,
            api.DesiredAccess);
        Assert.Equal(
            NativeMethods.FileShareRead | NativeMethods.FileShareWrite,
            api.ShareMode);
        Assert.Equal(NativeMethods.OpenExisting, api.CreationDisposition);
        Assert.Equal(NativeMethods.FileFlagOverlapped, api.FlagsAndAttributes);

        await device.DisposeAsync();

        Assert.True(binding.IsDisposed);
        Assert.True(api.Handle.IsClosed);
    }

    [Theory]
    [InlineData(NativeMethods.ErrorFileNotFound)]
    [InlineData(NativeMethods.ErrorPathNotFound)]
    public async Task Factory_maps_only_missing_control_device_errors_to_unavailable(
        int errorCode)
    {
        var api = new FakeWindowsDriverApi
        {
            OpenResult = new DriverHandleOpenResult(
                new SafeFileHandle(new IntPtr(-1), ownsHandle: false),
                errorCode),
        };
        var bindingFactory = new FakeOverlappedBindingFactory(
            new FakeOverlappedBinding());
        var factory = new WindowsDriverDeviceFactory(api, bindingFactory);

        DriverUnavailableException error = await Assert.ThrowsAsync<DriverUnavailableException>(
            () => factory.OpenAsync(CancellationToken.None).AsTask());

        Assert.StartsWith(
            "Cannot open the Lemon serial monitor driver control device",
            error.Message,
            StringComparison.Ordinal);
        Assert.Contains("CommMonitorFilter", error.Message, StringComparison.Ordinal);
        Assert.Equal(0, bindingFactory.BindCount);
    }

    [Fact]
    public async Task Factory_preserves_access_denied_as_a_fatal_win32_error()
    {
        var api = new FakeWindowsDriverApi
        {
            OpenResult = new DriverHandleOpenResult(
                new SafeFileHandle(new IntPtr(-1), ownsHandle: false),
                NativeMethods.ErrorAccessDenied),
        };
        var factory = new WindowsDriverDeviceFactory(
            api,
            new FakeOverlappedBindingFactory(new FakeOverlappedBinding()));

        Win32Exception error = await Assert.ThrowsAsync<Win32Exception>(
            () => factory.OpenAsync(CancellationToken.None).AsTask());

        Assert.Equal(NativeMethods.ErrorAccessDenied, error.NativeErrorCode);
    }

    [Fact]
    public async Task Factory_preserves_binding_failure_as_fatal()
    {
        var failure = new IOException("binding failed");
        var api = new FakeWindowsDriverApi();
        var factory = new WindowsDriverDeviceFactory(
            api,
            new ThrowingOverlappedBindingFactory(failure));

        InvalidOperationException error = await Assert.ThrowsAsync<InvalidOperationException>(
            () => factory.OpenAsync(CancellationToken.None).AsTask());

        Assert.Same(failure, error.InnerException);
        Assert.True(api.Handle.IsClosed);
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task Successful_and_pending_calls_both_wait_for_the_IOCP_callback(
        bool nativeReturnedSuccess)
    {
        var api = new FakeWindowsDriverApi
        {
            IoResult = nativeReturnedSuccess
                ? new NativeIoCallResult(true, NativeMethods.ErrorSuccess)
                : new NativeIoCallResult(false, NativeMethods.ErrorIoPending),
            OnDeviceIoControl = (_, output) => output[0] = 0xA5,
        };
        var binding = new FakeOverlappedBinding();
        await using IDriverDevice device = await OpenDeviceAsync(api, binding);
        byte[] output = new byte[4];

        Task<int> pending = device.DeviceIoControlAsync(
            0x1234,
            new byte[] { 1, 2, 3 },
            output,
            CancellationToken.None).AsTask();

        Assert.False(pending.IsCompleted);
        Assert.Equal(0, binding.FreeCount);
        Assert.Equal(0, output[0]);
        object[] pinnedBuffers = Assert.IsType<object[]>(binding.LastPinData);
        Assert.Same(api.LastInput, pinnedBuffers[0]);
        Assert.Same(api.LastOutput, pinnedBuffers[1]);

        binding.Complete(NativeMethods.ErrorSuccess, 1);

        Assert.Equal(1, await pending);
        Assert.Equal(0xA5, output[0]);
        Assert.Equal(1, binding.FreeCount);
    }

    [Fact]
    public async Task Immediate_non_pending_failure_frees_without_waiting_for_a_callback()
    {
        var api = new FakeWindowsDriverApi
        {
            IoResult = new NativeIoCallResult(false, NativeMethods.ErrorAccessDenied),
        };
        var binding = new FakeOverlappedBinding();
        await using IDriverDevice device = await OpenDeviceAsync(api, binding);

        Win32Exception error = await Assert.ThrowsAsync<Win32Exception>(() =>
            device.DeviceIoControlAsync(
                0x1234,
                ReadOnlyMemory<byte>.Empty,
                Memory<byte>.Empty,
                CancellationToken.None).AsTask());

        Assert.Equal(NativeMethods.ErrorAccessDenied, error.NativeErrorCode);
        Assert.Equal(1, binding.FreeCount);
    }

    [Fact]
    public async Task Cancellation_targets_the_exact_overlapped_and_waits_for_final_completion()
    {
        var api = new FakeWindowsDriverApi
        {
            IoResult = new NativeIoCallResult(false, NativeMethods.ErrorIoPending),
        };
        var binding = new FakeOverlappedBinding();
        await using IDriverDevice device = await OpenDeviceAsync(api, binding);
        using var cancellation = new CancellationTokenSource();
        Task<int> pending = device.DeviceIoControlAsync(
            0x1234,
            ReadOnlyMemory<byte>.Empty,
            new byte[8],
            cancellation.Token).AsTask();

        cancellation.Cancel();

        Assert.Equal(new[] { binding.Pointer }, api.CancelPointers);
        Assert.False(pending.IsCompleted);
        Assert.Equal(0, binding.FreeCount);

        binding.Complete(NativeMethods.ErrorOperationAborted, 0);

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => pending);
        Assert.Equal(1, binding.FreeCount);
    }

    [Fact]
    public async Task Cancel_ERROR_NOT_FOUND_is_a_normal_completion_race()
    {
        var api = new FakeWindowsDriverApi
        {
            IoResult = new NativeIoCallResult(false, NativeMethods.ErrorIoPending),
            CancelResult = new NativeCancelResult(false, NativeMethods.ErrorNotFound),
        };
        var binding = new FakeOverlappedBinding();
        await using IDriverDevice device = await OpenDeviceAsync(api, binding);
        using var cancellation = new CancellationTokenSource();
        Task<int> pending = device.DeviceIoControlAsync(
            0x1234,
            ReadOnlyMemory<byte>.Empty,
            new byte[8],
            cancellation.Token).AsTask();

        cancellation.Cancel();
        binding.Complete(NativeMethods.ErrorSuccess, 3);

        Assert.Equal(3, await pending);
        Assert.Equal(1, binding.FreeCount);
    }

    [Fact]
    public async Task Dispose_rejects_new_calls_cancels_active_IO_and_waits_for_rundown()
    {
        var api = new FakeWindowsDriverApi
        {
            IoResult = new NativeIoCallResult(false, NativeMethods.ErrorIoPending),
        };
        var binding = new FakeOverlappedBinding();
        IDriverDevice device = await OpenDeviceAsync(api, binding);
        Task<int> pending = device.DeviceIoControlAsync(
            0x1234,
            ReadOnlyMemory<byte>.Empty,
            new byte[8],
            CancellationToken.None).AsTask();

        Task disposing = device.DisposeAsync().AsTask();

        Assert.False(disposing.IsCompleted);
        Assert.Equal(new[] { binding.Pointer }, api.CancelPointers);
        Assert.False(binding.IsDisposed);
        Assert.False(api.Handle.IsClosed);
        await Assert.ThrowsAsync<ObjectDisposedException>(() =>
            device.DeviceIoControlAsync(
                0x1234,
                ReadOnlyMemory<byte>.Empty,
                Memory<byte>.Empty,
                CancellationToken.None).AsTask());

        binding.Complete(NativeMethods.ErrorOperationAborted, 0);

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => pending);
        await disposing;
        Assert.Equal(new[] { "free", "binding-dispose" }, binding.Lifecycle);
        Assert.True(api.Handle.IsClosed);
    }

    private static async ValueTask<IDriverDevice> OpenDeviceAsync(
        FakeWindowsDriverApi api,
        FakeOverlappedBinding binding)
    {
        var factory = new WindowsDriverDeviceFactory(
            api,
            new FakeOverlappedBindingFactory(binding));
        return await factory.OpenAsync(CancellationToken.None);
    }

    private sealed class FakeWindowsDriverApi : IWindowsDriverApi
    {
        public SafeFileHandle Handle { get; } =
            new(new IntPtr(0x1234), ownsHandle: false);

        public DriverHandleOpenResult? OpenResult { get; init; }
        public NativeIoCallResult IoResult { get; init; } =
            new(true, NativeMethods.ErrorSuccess);
        public NativeCancelResult CancelResult { get; init; } =
            new(true, NativeMethods.ErrorSuccess);
        public Action<byte[], byte[]>? OnDeviceIoControl { get; init; }

        public string? OpenPath { get; private set; }
        public uint DesiredAccess { get; private set; }
        public uint ShareMode { get; private set; }
        public uint CreationDisposition { get; private set; }
        public uint FlagsAndAttributes { get; private set; }
        public byte[]? LastInput { get; private set; }
        public byte[]? LastOutput { get; private set; }
        public List<nint> CancelPointers { get; } = [];

        public DriverHandleOpenResult OpenDriver(
            string path,
            uint desiredAccess,
            uint shareMode,
            uint creationDisposition,
            uint flagsAndAttributes)
        {
            OpenPath = path;
            DesiredAccess = desiredAccess;
            ShareMode = shareMode;
            CreationDisposition = creationDisposition;
            FlagsAndAttributes = flagsAndAttributes;
            return OpenResult ?? new DriverHandleOpenResult(Handle, NativeMethods.ErrorSuccess);
        }

        public NativeIoCallResult DeviceIoControl(
            SafeFileHandle handle,
            uint ioControlCode,
            byte[] input,
            byte[] output,
            nint overlapped)
        {
            Assert.Same(Handle, handle);
            LastInput = input;
            LastOutput = output;
            OnDeviceIoControl?.Invoke(input, output);
            return IoResult;
        }

        public NativeCancelResult CancelIoEx(
            SafeFileHandle handle,
            nint overlapped)
        {
            Assert.Same(Handle, handle);
            CancelPointers.Add(overlapped);
            return CancelResult;
        }
    }

    private sealed class FakeOverlappedBindingFactory(FakeOverlappedBinding binding)
        : IOverlappedBindingFactory
    {
        public int BindCount { get; private set; }

        public IOverlappedBinding Bind(SafeFileHandle handle)
        {
            BindCount++;
            return binding;
        }
    }

    private sealed class ThrowingOverlappedBindingFactory(IOException exception)
        : IOverlappedBindingFactory
    {
        public IOverlappedBinding Bind(SafeFileHandle handle) => throw exception;
    }

    private sealed class FakeOverlappedBinding : IOverlappedBinding
    {
        private Action<uint, uint, nint>? _callback;

        public nint Pointer { get; } = new(0x4321);
        public object? LastPinData { get; private set; }
        public int FreeCount { get; private set; }
        public bool IsDisposed { get; private set; }
        public List<string> Lifecycle { get; } = [];

        public nint Allocate(
            Action<uint, uint, nint> callback,
            object? pinData)
        {
            _callback = callback;
            LastPinData = pinData;
            return Pointer;
        }

        public void Free(nint overlapped)
        {
            Assert.Equal(Pointer, overlapped);
            FreeCount++;
            Lifecycle.Add("free");
        }

        public void Complete(uint errorCode, uint bytesTransferred)
        {
            Assert.NotNull(_callback);
            _callback(errorCode, bytesTransferred, Pointer);
        }

        public void Dispose()
        {
            IsDisposed = true;
            Lifecycle.Add("binding-dispose");
        }
    }
}
