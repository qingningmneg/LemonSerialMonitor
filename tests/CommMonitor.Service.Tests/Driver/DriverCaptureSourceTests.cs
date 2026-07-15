using System.Buffers.Binary;
using System.Collections.Immutable;
using CommMonitor.Core.Models;
using CommMonitor.Core.Protocol;
using CommMonitor.Service.Capture;
using CommMonitor.Service.Driver;
using CommMonitor.Service.Ports;

namespace CommMonitor.Service.Tests.Driver;

public sealed class DriverCaptureSourceTests
{
    [Fact]
    public void Managed_control_protocol_matches_native_IOCTL_values()
    {
        Assert.Equal(0x0022E000U, DriverProtocol.GetVersionIoControlCode);
        Assert.Equal(0x0022E004U, DriverProtocol.SetConfigIoControlCode);
        Assert.Equal(0x0022E008U, DriverProtocol.GetBatchIoControlCode);
        Assert.Equal(0x0022E00CU, DriverProtocol.GetStatsIoControlCode);
        Assert.Equal(12, DriverProtocol.VersionInfoSize);
        Assert.Equal(64, DriverProtocol.MaxSelectedDevices);
    }

    [Fact]
    public async Task Configure_writes_sorted_exact_little_endian_hashes()
    {
        byte[]? configuration = null;
        var device = new ScriptedDriverDevice((code, input, output, _) =>
        {
            if (code == DriverProtocol.GetVersionIoControlCode)
            {
                return ValueTask.FromResult(WriteVersion(output));
            }

            Assert.Equal(DriverProtocol.SetConfigIoControlCode, code);
            configuration = input.ToArray();
            return ValueTask.FromResult(0);
        });
        await using var source = CreateSource(device);

        await source.ConfigureAsync(
            CaptureState.Running,
            new HashSet<ulong> { 9, 3 },
            CancellationToken.None);

        Assert.NotNull(configuration);
        Assert.Equal(24, configuration.Length);
        Assert.Equal((uint)CaptureState.Running, BinaryPrimitives.ReadUInt32LittleEndian(configuration));
        Assert.Equal(2U, BinaryPrimitives.ReadUInt32LittleEndian(configuration.AsSpan(4)));
        Assert.Equal(3UL, BinaryPrimitives.ReadUInt64LittleEndian(configuration.AsSpan(8)));
        Assert.Equal(9UL, BinaryPrimitives.ReadUInt64LittleEndian(configuration.AsSpan(16)));
    }

    [Fact]
    public async Task Configure_rejects_zero_and_more_than_64_hashes_before_native_IO()
    {
        var device = new ScriptedDriverDevice((_, _, _, _) =>
            throw new Xunit.Sdk.XunitException("Native I/O must not be reached."));
        await using var source = CreateSource(device);

        await Assert.ThrowsAsync<ArgumentException>(() => source.ConfigureAsync(
            CaptureState.Running,
            new HashSet<ulong> { 0 },
            CancellationToken.None).AsTask());
        await Assert.ThrowsAsync<ArgumentException>(() => source.ConfigureAsync(
            CaptureState.Running,
            Enumerable.Range(1, 65).Select(value => (ulong)value).ToHashSet(),
            CancellationToken.None).AsTask());
    }

    [Fact]
    public async Task Configure_accepts_the_exact_64_device_boundary()
    {
        byte[]? configuration = null;
        var device = new ScriptedDriverDevice((code, input, output, _) =>
        {
            if (code == DriverProtocol.GetVersionIoControlCode)
            {
                return ValueTask.FromResult(WriteVersion(output));
            }

            configuration = input.ToArray();
            return ValueTask.FromResult(0);
        });
        await using var source = CreateSource(device);

        await source.ConfigureAsync(
            CaptureState.Running,
            Enumerable.Range(1, DriverProtocol.MaxSelectedDevices)
                .Select(value => (ulong)value)
                .ToHashSet(),
            CancellationToken.None);

        Assert.NotNull(configuration);
        Assert.Equal(
            DriverProtocol.ConfigPrefixSize +
                (DriverProtocol.MaxSelectedDevices * sizeof(ulong)),
            configuration.Length);
        Assert.Equal(
            64UL,
            BinaryPrimitives.ReadUInt64LittleEndian(configuration.AsSpan(
                configuration.Length - sizeof(ulong))));
    }

    [Fact]
    public async Task Valid_batch_is_decoded_timestamped_and_enriched_with_COM_name()
    {
        byte[] batch = CreateBatch(
                sequence: 7,
                qpcTicks: 2_500,
                deviceId: 17,
                payload: [1, 2, 3])
            .Concat(CreateBatch(
                sequence: 8,
                qpcTicks: 3_500,
                deviceId: 17,
                payload: [4]))
            .ToArray();
        var device = new ScriptedDriverDevice((code, _, output, _) =>
        {
            if (code == DriverProtocol.GetVersionIoControlCode)
            {
                return ValueTask.FromResult(WriteVersion(output));
            }
            if (code == DriverProtocol.SetConfigIoControlCode)
            {
                return ValueTask.FromResult(0);
            }

            Assert.Equal(DriverProtocol.GetBatchIoControlCode, code);
            batch.CopyTo(output);
            return ValueTask.FromResult(batch.Length);
        });
        var catalog = new StaticPortCatalog([
            new PortInfo("COM7", "USB serial (COM7)", "USB\\VID_TEST", 17),
        ]);
        await using var source = CreateSource(
            device,
            catalog,
            new FixedQpcClock(1_000, DateTimeOffset.UnixEpoch, 1_000));
        await source.ConfigureAsync(
            CaptureState.Running,
            new HashSet<ulong> { 17 },
            CancellationToken.None);

        using var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(2));
        await using IAsyncEnumerator<CaptureEvent> reader = source
            .ReadAllAsync(cancellation.Token)
            .GetAsyncEnumerator(cancellation.Token);
        Assert.True(await reader.MoveNextAsync());
        CaptureEvent item = reader.Current;

        Assert.Equal(7, item.Sequence);
        Assert.Equal("COM7", item.PortName);
        Assert.Equal(DateTimeOffset.UnixEpoch.AddSeconds(1.5), item.Timestamp);
        Assert.Equal(ImmutableArray.Create<byte>(1, 2, 3), item.Payload);

        Assert.True(await reader.MoveNextAsync());
        Assert.Equal(8, reader.Current.Sequence);
        Assert.Equal("COM7", reader.Current.PortName);
        Assert.Equal(DateTimeOffset.UnixEpoch.AddSeconds(2.5), reader.Current.Timestamp);
        Assert.Equal(ImmutableArray.Create<byte>(4), reader.Current.Payload);
    }

    [Fact]
    public async Task Protocol_mismatch_is_reported_and_does_not_become_ready()
    {
        var device = new ScriptedDriverDevice((code, _, output, _) =>
        {
            Assert.Equal(DriverProtocol.GetVersionIoControlCode, code);
            BinaryPrimitives.WriteUInt32LittleEndian(output.Span, 999);
            BinaryPrimitives.WriteUInt32LittleEndian(output.Span[4..], DriverProtocol.HeaderSize);
            BinaryPrimitives.WriteUInt32LittleEndian(output.Span[8..], DriverProtocol.MaxPayload);
            return ValueTask.FromResult(DriverProtocol.VersionInfoSize);
        });
        await using var source = CreateSource(device);

        CaptureSourceStatus status = await source.GetStatusAsync(CancellationToken.None);

        Assert.Equal(CaptureSourceStatusKind.ProtocolMismatch, status.Kind);
        await Assert.ThrowsAsync<InvalidDataException>(() => source.ConfigureAsync(
            CaptureState.Running,
            new HashSet<ulong> { 17 },
            CancellationToken.None).AsTask());
    }

    [Fact]
    public async Task Ready_status_uses_the_public_product_name()
    {
        var device = new ScriptedDriverDevice((code, _, output, _) =>
        {
            Assert.Equal(DriverProtocol.GetVersionIoControlCode, code);
            return ValueTask.FromResult(WriteVersion(output));
        });
        await using var source = CreateSource(device);

        CaptureSourceStatus status = await source.GetStatusAsync(CancellationToken.None);

        Assert.Equal(CaptureSourceStatusKind.Ready, status.Kind);
        Assert.Equal(
            $"Lemon serial monitor driver protocol {DriverProtocol.Version} is ready.",
            status.Message);
    }

    [Fact]
    public async Task Missing_control_device_maps_to_DriverUnavailable_status()
    {
        await using var source = new DriverCaptureSource(
            new ThrowingDriverDeviceFactory(new DriverUnavailableException("driver missing")),
            new StaticPortCatalog([]),
            new FixedQpcClock(0, DateTimeOffset.UnixEpoch, 10_000_000),
            new ImmediateCaptureDelay());

        CaptureSourceStatus status = await source.GetStatusAsync(CancellationToken.None);

        Assert.Equal(CaptureSourceStatusKind.DriverUnavailable, status.Kind);
        Assert.Contains("missing", status.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task Missing_control_device_is_retried_on_the_next_status_request()
    {
        var device = new ScriptedDriverDevice((code, _, output, _) =>
        {
            Assert.Equal(DriverProtocol.GetVersionIoControlCode, code);
            return ValueTask.FromResult(WriteVersion(output));
        });
        var factory = new RecoveringDriverDeviceFactory(device);
        await using var source = new DriverCaptureSource(
            factory,
            new StaticPortCatalog([]),
            new FixedQpcClock(0, DateTimeOffset.UnixEpoch, 10_000_000),
            new ImmediateCaptureDelay());

        CaptureSourceStatus first = await source.GetStatusAsync(CancellationToken.None);
        CaptureSourceStatus second = await source.GetStatusAsync(CancellationToken.None);

        Assert.Equal(CaptureSourceStatusKind.DriverUnavailable, first.Kind);
        Assert.Equal(CaptureSourceStatusKind.Ready, second.Kind);
        Assert.Equal(2, factory.OpenCalls);
    }

    [Fact]
    public async Task Returned_count_larger_than_buffer_is_a_protocol_error()
    {
        var device = new ScriptedDriverDevice((code, _, output, _) =>
        {
            if (code == DriverProtocol.GetVersionIoControlCode)
            {
                return ValueTask.FromResult(WriteVersion(output));
            }
            if (code == DriverProtocol.SetConfigIoControlCode)
            {
                return ValueTask.FromResult(0);
            }
            return ValueTask.FromResult(output.Length + 1);
        });
        await using var source = CreateSource(device);
        await source.ConfigureAsync(
            CaptureState.Running,
            new HashSet<ulong> { 17 },
            CancellationToken.None);
        using var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(2));
        await using IAsyncEnumerator<CaptureEvent> reader = source
            .ReadAllAsync(cancellation.Token)
            .GetAsyncEnumerator(cancellation.Token);

        await Assert.ThrowsAsync<InvalidDataException>(() => reader.MoveNextAsync().AsTask());
        Assert.Equal(
            CaptureSourceStatusKind.ProtocolMismatch,
            (await source.GetStatusAsync(CancellationToken.None)).Kind);
    }

    [Fact]
    public async Task Empty_batch_uses_cancellable_delay_without_busy_spin()
    {
        var delay = new BlockingCaptureDelay();
        var device = new ScriptedDriverDevice((code, _, output, _) =>
        {
            if (code == DriverProtocol.GetVersionIoControlCode)
            {
                return ValueTask.FromResult(WriteVersion(output));
            }
            if (code == DriverProtocol.SetConfigIoControlCode)
            {
                return ValueTask.FromResult(0);
            }
            return ValueTask.FromResult(0);
        });
        await using var source = CreateSource(device, delay: delay);
        await source.ConfigureAsync(
            CaptureState.Running,
            new HashSet<ulong> { 17 },
            CancellationToken.None);
        using var cancellation = new CancellationTokenSource();
        await using IAsyncEnumerator<CaptureEvent> reader = source
            .ReadAllAsync(cancellation.Token)
            .GetAsyncEnumerator(cancellation.Token);

        Task<bool> pending = reader.MoveNextAsync().AsTask();
        await delay.Entered.WaitAsync(TimeSpan.FromSeconds(2));
        cancellation.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => pending);
        Assert.Equal(TimeSpan.FromMilliseconds(10), delay.LastDelay);
        Assert.Equal(1, delay.CallCount);
    }

    [Fact]
    public async Task Truncated_wire_batch_is_rejected_by_the_shared_decoder()
    {
        byte[] batch = CreateBatch(1, 1, 17, [0xAA]);
        Array.Resize(ref batch, batch.Length - 1);
        var device = new ScriptedDriverDevice((code, _, output, _) =>
        {
            if (code == DriverProtocol.GetVersionIoControlCode)
            {
                return ValueTask.FromResult(WriteVersion(output));
            }
            if (code == DriverProtocol.SetConfigIoControlCode)
            {
                return ValueTask.FromResult(0);
            }
            batch.CopyTo(output);
            return ValueTask.FromResult(batch.Length);
        });
        await using var source = CreateSource(device);
        await source.ConfigureAsync(
            CaptureState.Running,
            new HashSet<ulong> { 17 },
            CancellationToken.None);
        using var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(2));
        await using IAsyncEnumerator<CaptureEvent> reader = source
            .ReadAllAsync(cancellation.Token)
            .GetAsyncEnumerator(cancellation.Token);

        await Assert.ThrowsAsync<InvalidDataException>(() => reader.MoveNextAsync().AsTask());
    }

    private static DriverCaptureSource CreateSource(
        IDriverDevice device,
        IPortCatalog? catalog = null,
        IQpcClock? clock = null,
        ICaptureDelay? delay = null) =>
        new(
            new SingleDriverDeviceFactory(device),
            catalog ?? new StaticPortCatalog([]),
            clock ?? new FixedQpcClock(0, DateTimeOffset.UnixEpoch, 10_000_000),
            delay ?? new ImmediateCaptureDelay());

    private static int WriteVersion(Memory<byte> output)
    {
        BinaryPrimitives.WriteUInt32LittleEndian(output.Span, DriverProtocol.Version);
        BinaryPrimitives.WriteUInt32LittleEndian(output.Span[4..], DriverProtocol.HeaderSize);
        BinaryPrimitives.WriteUInt32LittleEndian(output.Span[8..], DriverProtocol.MaxPayload);
        return DriverProtocol.VersionInfoSize;
    }

    private static byte[] CreateBatch(long sequence, long qpcTicks, ulong deviceId, byte[] payload)
    {
        byte[] bytes = new byte[DriverProtocol.HeaderSize + payload.Length];
        BinaryPrimitives.WriteUInt32LittleEndian(bytes, DriverProtocol.Magic);
        BinaryPrimitives.WriteUInt16LittleEndian(bytes.AsSpan(4), DriverProtocol.Version);
        BinaryPrimitives.WriteUInt16LittleEndian(bytes.AsSpan(6), DriverProtocol.HeaderSize);
        BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(8), (uint)bytes.Length);
        BinaryPrimitives.WriteUInt64LittleEndian(bytes.AsSpan(12), unchecked((ulong)sequence));
        BinaryPrimitives.WriteInt64LittleEndian(bytes.AsSpan(20), qpcTicks);
        BinaryPrimitives.WriteUInt64LittleEndian(bytes.AsSpan(28), deviceId);
        BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(36), 42);
        BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(40), (uint)CaptureKind.Read);
        BinaryPrimitives.WriteInt32LittleEndian(bytes.AsSpan(48), 0);
        BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(52), (uint)payload.Length);
        BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(56), (uint)payload.Length);
        BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(60), (uint)payload.Length);
        payload.CopyTo(bytes.AsSpan(DriverProtocol.HeaderSize));
        return bytes;
    }

    private sealed class ScriptedDriverDevice(
        Func<uint, ReadOnlyMemory<byte>, Memory<byte>, CancellationToken, ValueTask<int>> handler)
        : IDriverDevice
    {
        public ValueTask<int> DeviceIoControlAsync(
            uint ioControlCode,
            ReadOnlyMemory<byte> input,
            Memory<byte> output,
            CancellationToken cancellationToken) =>
            handler(ioControlCode, input, output, cancellationToken);

        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }

    private sealed class SingleDriverDeviceFactory(IDriverDevice device) : IDriverDeviceFactory
    {
        public ValueTask<IDriverDevice> OpenAsync(CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            return ValueTask.FromResult(device);
        }
    }

    private sealed class ThrowingDriverDeviceFactory(Exception exception) : IDriverDeviceFactory
    {
        public ValueTask<IDriverDevice> OpenAsync(CancellationToken cancellationToken) =>
            ValueTask.FromException<IDriverDevice>(exception);
    }

    private sealed class RecoveringDriverDeviceFactory(IDriverDevice device)
        : IDriverDeviceFactory
    {
        public int OpenCalls { get; private set; }

        public ValueTask<IDriverDevice> OpenAsync(CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            OpenCalls++;
            return OpenCalls == 1
                ? ValueTask.FromException<IDriverDevice>(
                    new DriverUnavailableException("driver missing"))
                : ValueTask.FromResult(device);
        }
    }

    private sealed class StaticPortCatalog(IReadOnlyList<PortInfo> ports) : IPortCatalog
    {
        public ValueTask<IReadOnlyList<PortInfo>> GetPortsAsync(CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            return ValueTask.FromResult(ports);
        }
    }

    private sealed class FixedQpcClock(long timestamp, DateTimeOffset utcNow, long frequency)
        : IQpcClock
    {
        public long GetTimestamp() => timestamp;
        public DateTimeOffset UtcNow => utcNow;
        public long Frequency => frequency;
    }

    private sealed class ImmediateCaptureDelay : ICaptureDelay
    {
        public ValueTask DelayAsync(TimeSpan delay, CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            return ValueTask.CompletedTask;
        }
    }

    private sealed class BlockingCaptureDelay : ICaptureDelay
    {
        private readonly TaskCompletionSource _entered =
            new(TaskCreationOptions.RunContinuationsAsynchronously);

        public Task Entered => _entered.Task;
        public int CallCount { get; private set; }
        public TimeSpan LastDelay { get; private set; }

        public async ValueTask DelayAsync(TimeSpan delay, CancellationToken cancellationToken)
        {
            CallCount++;
            LastDelay = delay;
            _entered.TrySetResult();
            await Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken);
        }
    }
}
