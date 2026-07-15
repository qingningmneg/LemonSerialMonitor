using System.Buffers.Binary;
using CommMonitor.Core.Models;
using CommMonitor.Core.Protocol;
using CommMonitor.Service.Capture;
using CommMonitor.Service.Driver;
using CommMonitor.Service.Ports;

namespace CommMonitor.Service.Tests.Driver;

public sealed class DriverStatisticsTests
{
    [Fact]
    public async Task GetStatisticsAsync_decodes_the_exact_native_layout_without_narrowing_counters()
    {
        DateTimeOffset sampledAt = new(2026, 7, 13, 12, 0, 0, TimeSpan.Zero);
        var device = new ScriptedDriverDevice((code, _, output, _) =>
        {
            if (code == DriverProtocol.GetVersionIoControlCode)
            {
                return ValueTask.FromResult(WriteVersion(output));
            }

            Assert.Equal(DriverProtocol.GetStatsIoControlCode, code);
            byte[] bytes = new byte[24];
            BinaryPrimitives.WriteUInt32LittleEndian(bytes, 7);
            BinaryPrimitives.WriteUInt32LittleEndian(
                bytes.AsSpan(4),
                (uint)CaptureState.Running);
            BinaryPrimitives.WriteUInt64LittleEndian(bytes.AsSpan(8), ulong.MaxValue - 1);
            BinaryPrimitives.WriteUInt64LittleEndian(bytes.AsSpan(16), ulong.MaxValue);
            bytes.CopyTo(output);
            return ValueTask.FromResult(bytes.Length);
        });
        await using var source = CreateSource(device, sampledAt);

        CaptureSourceStatistics stats = await source.GetStatisticsAsync(default);

        Assert.True(stats.StatsKnown);
        Assert.Equal(7U, stats.Queued);
        Assert.Equal(CaptureState.Running, stats.State);
        Assert.Equal(ulong.MaxValue - 1, stats.Dropped);
        Assert.Equal(ulong.MaxValue, stats.Sequence);
        Assert.Equal(sampledAt, stats.SampledAtUtc);
        Assert.Null(stats.UnavailableReason);
    }

    [Theory]
    [InlineData(23)]
    [InlineData(25)]
    public async Task GetStatisticsAsync_rejects_any_reply_that_is_not_exactly_24_bytes(
        int returnedBytes)
    {
        var device = new ScriptedDriverDevice((code, _, output, _) =>
        {
            if (code == DriverProtocol.GetVersionIoControlCode)
            {
                return ValueTask.FromResult(WriteVersion(output));
            }

            Assert.Equal(DriverProtocol.GetStatsIoControlCode, code);
            output.Span.Clear();
            return ValueTask.FromResult(returnedBytes);
        });
        await using var source = CreateSource(device, DateTimeOffset.UnixEpoch);

        InvalidDataException exception = await Assert.ThrowsAsync<InvalidDataException>(
            () => source.GetStatisticsAsync(default).AsTask());

        Assert.Contains("24", exception.Message, StringComparison.Ordinal);
        Assert.Equal(
            CaptureSourceStatusKind.ProtocolMismatch,
            (await source.GetStatusAsync(default)).Kind);
    }

    [Fact]
    public async Task GetStatisticsAsync_rejects_an_undefined_capture_state()
    {
        var device = new ScriptedDriverDevice((code, _, output, _) =>
        {
            if (code == DriverProtocol.GetVersionIoControlCode)
            {
                return ValueTask.FromResult(WriteVersion(output));
            }

            Assert.Equal(DriverProtocol.GetStatsIoControlCode, code);
            output.Span.Clear();
            BinaryPrimitives.WriteUInt32LittleEndian(output.Span[4..], uint.MaxValue);
            return ValueTask.FromResult(24);
        });
        await using var source = CreateSource(device, DateTimeOffset.UnixEpoch);

        InvalidDataException exception = await Assert.ThrowsAsync<InvalidDataException>(
            () => source.GetStatisticsAsync(default).AsTask());

        Assert.Contains("state", exception.Message, StringComparison.OrdinalIgnoreCase);
        Assert.Equal(
            CaptureSourceStatusKind.ProtocolMismatch,
            (await source.GetStatusAsync(default)).Kind);
    }

    [Fact]
    public async Task Fake_capture_source_reports_statistics_as_unknown_not_zero_known()
    {
        await using var source = new FakeCaptureSource();

        CaptureSourceStatistics stats = await source.GetStatisticsAsync(default);

        Assert.False(stats.StatsKnown);
        Assert.NotNull(stats.UnavailableReason);
    }

    private static DriverCaptureSource CreateSource(
        IDriverDevice device,
        DateTimeOffset sampledAt) =>
        new(
            new SingleDriverDeviceFactory(device),
            new StaticPortCatalog(),
            new FixedQpcClock(sampledAt),
            new ImmediateCaptureDelay());

    private static int WriteVersion(Memory<byte> output)
    {
        BinaryPrimitives.WriteUInt32LittleEndian(output.Span, DriverProtocol.Version);
        BinaryPrimitives.WriteUInt32LittleEndian(output.Span[4..], DriverProtocol.HeaderSize);
        BinaryPrimitives.WriteUInt32LittleEndian(output.Span[8..], DriverProtocol.MaxPayload);
        return DriverProtocol.VersionInfoSize;
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

    private sealed class StaticPortCatalog : IPortCatalog
    {
        public ValueTask<IReadOnlyList<PortInfo>> GetPortsAsync(
            CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            return ValueTask.FromResult<IReadOnlyList<PortInfo>>([]);
        }
    }

    private sealed class FixedQpcClock(DateTimeOffset utcNow) : IQpcClock
    {
        public long GetTimestamp() => 0;
        public DateTimeOffset UtcNow => utcNow;
        public long Frequency => 10_000_000;
    }

    private sealed class ImmediateCaptureDelay : ICaptureDelay
    {
        public ValueTask DelayAsync(TimeSpan delay, CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            return ValueTask.CompletedTask;
        }
    }
}
