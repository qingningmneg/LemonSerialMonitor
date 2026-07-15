using System.ComponentModel;
using Microsoft.Win32.SafeHandles;

namespace CommMonitor.Service.Driver;

internal interface IDriverDevice : IAsyncDisposable
{
    ValueTask<int> DeviceIoControlAsync(
        uint ioControlCode,
        ReadOnlyMemory<byte> input,
        Memory<byte> output,
        CancellationToken cancellationToken);
}

internal interface IDriverDeviceFactory
{
    ValueTask<IDriverDevice> OpenAsync(CancellationToken cancellationToken);
}

internal sealed class WindowsDriverDeviceFactory : IDriverDeviceFactory
{
    internal const string DevicePath = @"\\.\Global\CommMonitorFilter";

    private readonly IWindowsDriverApi _nativeApi;
    private readonly IOverlappedBindingFactory _bindingFactory;

    public WindowsDriverDeviceFactory()
        : this(new WindowsDriverApi(), new ThreadPoolOverlappedBindingFactory())
    {
    }

    internal WindowsDriverDeviceFactory(
        IWindowsDriverApi nativeApi,
        IOverlappedBindingFactory bindingFactory)
    {
        _nativeApi = nativeApi;
        _bindingFactory = bindingFactory;
    }

    public ValueTask<IDriverDevice> OpenAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();

        DriverHandleOpenResult openResult = _nativeApi.OpenDriver(
            DevicePath,
            NativeMethods.GenericRead | NativeMethods.GenericWrite,
            NativeMethods.FileShareRead | NativeMethods.FileShareWrite,
            NativeMethods.OpenExisting,
            NativeMethods.FileFlagOverlapped);
        SafeFileHandle handle = openResult.Handle;

        if (handle.IsInvalid)
        {
            handle.Dispose();
            var nativeError = new Win32Exception(openResult.ErrorCode);
            throw new DriverUnavailableException(
                $"Cannot open the CommMonitor driver control device '{DevicePath}': " +
                nativeError.Message,
                nativeError);
        }

        try
        {
            IOverlappedBinding binding = _bindingFactory.Bind(handle);
            return ValueTask.FromResult<IDriverDevice>(
                new WindowsDriverDevice(handle, binding, _nativeApi));
        }
        catch (Exception error) when (
            error is ArgumentException or IOException or Win32Exception)
        {
            handle.Dispose();
            throw new DriverUnavailableException(
                $"Cannot bind overlapped I/O for the CommMonitor driver control device " +
                $"'{DevicePath}'.",
                error);
        }
    }
}

internal sealed class WindowsDriverDevice : IDriverDevice
{
    private readonly object _sync = new();
    private readonly SafeFileHandle _handle;
    private readonly IOverlappedBinding _binding;
    private readonly IWindowsDriverApi _nativeApi;
    private readonly HashSet<PendingOperation> _activeOperations = [];

    private bool _disposeStarted;
    private Task? _disposeTask;

    internal WindowsDriverDevice(
        SafeFileHandle handle,
        IOverlappedBinding binding,
        IWindowsDriverApi nativeApi)
    {
        _handle = handle;
        _binding = binding;
        _nativeApi = nativeApi;
    }

    public ValueTask<int> DeviceIoControlAsync(
        uint ioControlCode,
        ReadOnlyMemory<byte> input,
        Memory<byte> output,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        return new ValueTask<int>(DeviceIoControlCoreAsync(
            ioControlCode,
            input,
            output,
            cancellationToken));
    }

    public ValueTask DisposeAsync()
    {
        lock (_sync)
        {
            if (_disposeTask is not null)
            {
                return new ValueTask(_disposeTask);
            }

            _disposeStarted = true;
            PendingOperation[] operations = [.. _activeOperations];
            _disposeTask = DisposeCoreAsync(operations);
            return new ValueTask(_disposeTask);
        }
    }

    private async Task<int> DeviceIoControlCoreAsync(
        uint ioControlCode,
        ReadOnlyMemory<byte> input,
        Memory<byte> output,
        CancellationToken cancellationToken)
    {
        byte[] inputBuffer = input.ToArray();
        byte[] outputBuffer = new byte[output.Length];
        var operation = new PendingOperation(_handle, _nativeApi);

        lock (_sync)
        {
            ObjectDisposedException.ThrowIf(_disposeStarted, this);
            _activeOperations.Add(operation);
        }

        nint overlapped = 0;
        CancellationTokenRegistration cancellationRegistration = default;
        CompletionResult completion = default;
        Exception? cleanupError = null;

        try
        {
            overlapped = _binding.Allocate(
                operation.Complete,
                new object[] { inputBuffer, outputBuffer });
            operation.SetOverlapped(overlapped);

            NativeIoCallResult nativeResult = _nativeApi.DeviceIoControl(
                _handle,
                ioControlCode,
                inputBuffer,
                outputBuffer,
                overlapped);
            if (!nativeResult.Succeeded &&
                nativeResult.ErrorCode != NativeMethods.ErrorIoPending)
            {
                throw new Win32Exception(nativeResult.ErrorCode);
            }

            operation.MarkSubmitted();
            cancellationRegistration = cancellationToken.Register(
                static state => ((PendingOperation)state!).RequestCancel(),
                operation);

            completion = await operation.Completion.ConfigureAwait(false);
        }
        finally
        {
            try
            {
                cancellationRegistration.Dispose();
            }
            catch (Exception error)
            {
                cleanupError = error;
            }

            if (overlapped != 0)
            {
                try
                {
                    _binding.Free(overlapped);
                }
                catch (Exception error)
                {
                    cleanupError ??= error;
                }
            }

            lock (_sync)
            {
                _activeOperations.Remove(operation);
            }
            operation.MarkCleanedUp();
        }

        if (cleanupError is not null)
        {
            throw cleanupError;
        }

        if (completion.ErrorCode == NativeMethods.ErrorOperationAborted)
        {
            throw new OperationCanceledException(
                "The driver I/O operation was canceled.",
                cancellationToken);
        }

        if (completion.ErrorCode != NativeMethods.ErrorSuccess)
        {
            throw new Win32Exception(checked((int)completion.ErrorCode));
        }

        if (operation.CancellationFailure is not null)
        {
            throw operation.CancellationFailure;
        }

        if (completion.BytesTransferred > outputBuffer.Length)
        {
            throw new InvalidDataException(
                $"The driver returned {completion.BytesTransferred} bytes for a " +
                $"{outputBuffer.Length}-byte output buffer.");
        }

        int bytesTransferred = checked((int)completion.BytesTransferred);
        outputBuffer.AsMemory(0, bytesTransferred).CopyTo(output);
        return bytesTransferred;
    }

    private async Task DisposeCoreAsync(PendingOperation[] operations)
    {
        foreach (PendingOperation operation in operations)
        {
            operation.RequestCancel();
        }

        try
        {
            await Task.WhenAll(operations.Select(operation => operation.Cleanup))
                .ConfigureAwait(false);
        }
        finally
        {
            _binding.Dispose();
            _handle.Dispose();
        }
    }

    private sealed class PendingOperation
    {
        private readonly object _sync = new();
        private readonly SafeFileHandle _handle;
        private readonly IWindowsDriverApi _nativeApi;
        private readonly TaskCompletionSource<CompletionResult> _completion =
            new(TaskCreationOptions.RunContinuationsAsynchronously);
        private readonly TaskCompletionSource _cleanup =
            new(TaskCreationOptions.RunContinuationsAsynchronously);

        private nint _overlapped;
        private bool _submitted;
        private bool _cancelRequested;
        private bool _cancelIssued;
        private Exception? _cancellationFailure;

        internal PendingOperation(
            SafeFileHandle handle,
            IWindowsDriverApi nativeApi)
        {
            _handle = handle;
            _nativeApi = nativeApi;
        }

        internal Task<CompletionResult> Completion => _completion.Task;

        internal Task Cleanup => _cleanup.Task;

        internal Exception? CancellationFailure
        {
            get
            {
                lock (_sync)
                {
                    return _cancellationFailure;
                }
            }
        }

        internal void SetOverlapped(nint overlapped)
        {
            if (overlapped == 0)
            {
                throw new InvalidOperationException(
                    "The bound handle returned a null native OVERLAPPED pointer.");
            }

            lock (_sync)
            {
                _overlapped = overlapped;
            }
        }

        internal void MarkSubmitted()
        {
            nint pointerToCancel = 0;
            lock (_sync)
            {
                _submitted = true;
                if (_cancelRequested && !_cancelIssued)
                {
                    _cancelIssued = true;
                    pointerToCancel = _overlapped;
                }
            }

            if (pointerToCancel != 0)
            {
                IssueCancel(pointerToCancel);
            }
        }

        internal void RequestCancel()
        {
            nint pointerToCancel = 0;
            lock (_sync)
            {
                _cancelRequested = true;
                if (_submitted && !_cancelIssued)
                {
                    _cancelIssued = true;
                    pointerToCancel = _overlapped;
                }
            }

            if (pointerToCancel != 0)
            {
                IssueCancel(pointerToCancel);
            }
        }

        internal void Complete(
            uint errorCode,
            uint bytesTransferred,
            nint overlapped)
        {
            lock (_sync)
            {
                if (overlapped != _overlapped)
                {
                    return;
                }
            }

            _completion.TrySetResult(new CompletionResult(
                errorCode,
                bytesTransferred));
        }

        internal void MarkCleanedUp() => _cleanup.TrySetResult();

        private void IssueCancel(nint overlapped)
        {
            NativeCancelResult result = _nativeApi.CancelIoEx(_handle, overlapped);
            if (result.Succeeded || result.ErrorCode == NativeMethods.ErrorNotFound)
            {
                return;
            }

            lock (_sync)
            {
                _cancellationFailure ??= new Win32Exception(result.ErrorCode);
            }
        }
    }

    private readonly record struct CompletionResult(
        uint ErrorCode,
        uint BytesTransferred);
}
