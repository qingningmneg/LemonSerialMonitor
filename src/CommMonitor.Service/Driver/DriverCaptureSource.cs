using System.Buffers.Binary;
using System.Runtime.CompilerServices;
using CommMonitor.Core.Models;
using CommMonitor.Core.Protocol;
using CommMonitor.Service.Capture;
using CommMonitor.Service.Ports;

namespace CommMonitor.Service.Driver;

internal sealed class DriverCaptureSource :
    ICaptureSource,
    ICaptureSourceStatusProvider,
    ICaptureSourceStatisticsProvider
{
    private static readonly TimeSpan EmptyBatchDelay = TimeSpan.FromMilliseconds(10);
    private const int StatisticsSize = 24;

    private readonly IDriverDeviceFactory _deviceFactory;
    private readonly IPortCatalog _portCatalog;
    private readonly IQpcClock _clock;
    private readonly ICaptureDelay _delay;
    private readonly SemaphoreSlim _initializationGate = new(1, 1);
    private readonly long _calibrationQpc;
    private readonly DateTimeOffset _calibrationUtc;
    private IDriverDevice? _device;
    private IReadOnlyDictionary<ulong, string> _portNames =
        new Dictionary<ulong, string>();
    private CaptureSourceStatus _status = new(
        CaptureSourceStatusKind.DriverUnavailable,
        "The Lemon serial monitor driver has not been checked yet.");
    private volatile bool _disposed;

    public DriverCaptureSource(
        IDriverDeviceFactory deviceFactory,
        IPortCatalog portCatalog,
        IQpcClock clock,
        ICaptureDelay delay)
    {
        _deviceFactory = deviceFactory ?? throw new ArgumentNullException(nameof(deviceFactory));
        _portCatalog = portCatalog ?? throw new ArgumentNullException(nameof(portCatalog));
        _clock = clock ?? throw new ArgumentNullException(nameof(clock));
        _delay = delay ?? throw new ArgumentNullException(nameof(delay));
        if (_clock.Frequency <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(clock), "QPC frequency must be positive.");
        }

        _calibrationQpc = _clock.GetTimestamp();
        _calibrationUtc = _clock.UtcNow;
    }

    public async ValueTask ConfigureAsync(
        CaptureState state,
        IReadOnlySet<ulong> deviceIds,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(deviceIds);
        ThrowIfDisposed();
        cancellationToken.ThrowIfCancellationRequested();

        if (!Enum.IsDefined(state))
        {
            throw new ArgumentOutOfRangeException(nameof(state));
        }

        if (deviceIds.Count > DriverProtocol.MaxSelectedDevices || deviceIds.Contains(0))
        {
            throw new ArgumentException(
                $"Device IDs must be non-zero and contain no more than " +
                $"{DriverProtocol.MaxSelectedDevices} entries.",
                nameof(deviceIds));
        }

        ulong[] sortedDeviceIds = deviceIds.Order().ToArray();
        byte[] configuration = new byte[
            DriverProtocol.ConfigPrefixSize + (sortedDeviceIds.Length * sizeof(ulong))];
        BinaryPrimitives.WriteUInt32LittleEndian(configuration, (uint)state);
        BinaryPrimitives.WriteUInt32LittleEndian(
            configuration.AsSpan(sizeof(uint)),
            checked((uint)sortedDeviceIds.Length));
        for (int index = 0; index < sortedDeviceIds.Length; index++)
        {
            BinaryPrimitives.WriteUInt64LittleEndian(
                configuration.AsSpan(DriverProtocol.ConfigPrefixSize + (index * sizeof(ulong))),
                sortedDeviceIds[index]);
        }

        IDriverDevice device = await EnsureDeviceAsync(cancellationToken).ConfigureAwait(false);
        if (state == CaptureState.Running)
        {
            await RefreshPortNamesAsync(cancellationToken).ConfigureAwait(false);
        }

        try
        {
            int bytesReturned = await device.DeviceIoControlAsync(
                DriverProtocol.SetConfigIoControlCode,
                configuration,
                Memory<byte>.Empty,
                cancellationToken).ConfigureAwait(false);
            if (bytesReturned != 0)
            {
                SetStatus(
                    CaptureSourceStatusKind.ProtocolMismatch,
                    "The driver returned unexpected data for SET_CONFIG.");
                throw new InvalidDataException(
                    "The driver returned unexpected data for SET_CONFIG.");
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (InvalidDataException)
        {
            throw;
        }
        catch (Exception exception)
        {
            SetStatus(CaptureSourceStatusKind.Faulted, exception.Message);
            throw;
        }
    }

    public async IAsyncEnumerable<CaptureEvent> ReadAllAsync(
        [EnumeratorCancellation] CancellationToken cancellationToken)
    {
        ThrowIfDisposed();
        IDriverDevice device = await EnsureDeviceAsync(cancellationToken).ConfigureAwait(false);
        byte[] batch = new byte[DriverProtocol.MaxBatchBytes];

        while (true)
        {
            cancellationToken.ThrowIfCancellationRequested();
            ThrowIfDisposed();

            int bytesReturned;
            try
            {
                bytesReturned = await device.DeviceIoControlAsync(
                    DriverProtocol.GetBatchIoControlCode,
                    ReadOnlyMemory<byte>.Empty,
                    batch,
                    cancellationToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                throw;
            }
            catch (Exception exception)
            {
                SetStatus(CaptureSourceStatusKind.Faulted, exception.Message);
                throw;
            }

            if ((uint)bytesReturned > (uint)batch.Length)
            {
                SetStatus(
                    CaptureSourceStatusKind.ProtocolMismatch,
                    "The driver returned a capture byte count outside the supplied buffer.");
                throw new InvalidDataException(
                    "The driver returned a capture byte count outside the supplied buffer.");
            }

            if (bytesReturned == 0)
            {
                await _delay.DelayAsync(EmptyBatchDelay, cancellationToken).ConfigureAwait(false);
                continue;
            }

            IReadOnlyList<CaptureEvent> events;
            try
            {
                events = DriverEventCodec.DecodeBatch(batch.AsSpan(0, bytesReturned));
            }
            catch (InvalidDataException exception)
            {
                SetStatus(CaptureSourceStatusKind.ProtocolMismatch, exception.Message);
                throw;
            }

            IReadOnlyDictionary<ulong, string> portNames = Volatile.Read(ref _portNames);

            foreach (CaptureEvent captureEvent in events)
            {
                yield return captureEvent with
                {
                    PortName = portNames.GetValueOrDefault(captureEvent.DeviceId, string.Empty),
                    Timestamp = ToUtcTimestamp(captureEvent.QpcTicks),
                };
            }
        }
    }

    public async ValueTask<CaptureSourceStatus> GetStatusAsync(
        CancellationToken cancellationToken)
    {
        ThrowIfDisposed();
        try
        {
            await EnsureDeviceAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (DriverUnavailableException exception)
        {
            SetStatus(CaptureSourceStatusKind.DriverUnavailable, exception.Message);
        }
        catch (InvalidDataException exception)
        {
            SetStatus(CaptureSourceStatusKind.ProtocolMismatch, exception.Message);
        }
        catch (Exception exception)
        {
            SetStatus(CaptureSourceStatusKind.Faulted, exception.Message);
        }

        return Volatile.Read(ref _status);
    }

    public async ValueTask<CaptureSourceStatistics> GetStatisticsAsync(
        CancellationToken cancellationToken)
    {
        ThrowIfDisposed();
        cancellationToken.ThrowIfCancellationRequested();
        IDriverDevice device = await EnsureDeviceAsync(cancellationToken).ConfigureAwait(false);
        byte[] statistics = new byte[StatisticsSize];

        try
        {
            int bytesReturned = await device.DeviceIoControlAsync(
                DriverProtocol.GetStatsIoControlCode,
                ReadOnlyMemory<byte>.Empty,
                statistics,
                cancellationToken).ConfigureAwait(false);
            if (bytesReturned != StatisticsSize)
            {
                string message =
                    $"The driver returned {bytesReturned} statistics bytes; " +
                    $"expected exactly {StatisticsSize}.";
                SetStatus(CaptureSourceStatusKind.ProtocolMismatch, message);
                throw new InvalidDataException(message);
            }

            uint queued = BinaryPrimitives.ReadUInt32LittleEndian(statistics);
            uint rawState = BinaryPrimitives.ReadUInt32LittleEndian(statistics.AsSpan(4));
            CaptureState state = (CaptureState)rawState;
            if (!Enum.IsDefined(state))
            {
                string message =
                    $"The driver returned undefined capture state {rawState} in GET_STATS.";
                SetStatus(CaptureSourceStatusKind.ProtocolMismatch, message);
                throw new InvalidDataException(message);
            }

            return new CaptureSourceStatistics(
                true,
                queued,
                state,
                BinaryPrimitives.ReadUInt64LittleEndian(statistics.AsSpan(8)),
                BinaryPrimitives.ReadUInt64LittleEndian(statistics.AsSpan(16)),
                _clock.UtcNow,
                null);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (InvalidDataException)
        {
            throw;
        }
        catch (Exception exception)
        {
            SetStatus(CaptureSourceStatusKind.Faulted, exception.Message);
            throw;
        }
    }

    public async ValueTask DisposeAsync()
    {
        IDriverDevice? device = null;
        await _initializationGate.WaitAsync().ConfigureAwait(false);
        try
        {
            if (_disposed)
            {
                return;
            }

            _disposed = true;
            device = _device;
            _device = null;
        }
        finally
        {
            _initializationGate.Release();
        }

        if (device is not null)
        {
            await device.DisposeAsync().ConfigureAwait(false);
        }
    }

    private async ValueTask<IDriverDevice> EnsureDeviceAsync(
        CancellationToken cancellationToken)
    {
        IDriverDevice? existing = Volatile.Read(ref _device);
        if (existing is not null)
        {
            return existing;
        }

        await _initializationGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            ThrowIfDisposed();
            if (_device is not null)
            {
                return _device;
            }

            IDriverDevice candidate;
            try
            {
                candidate = await _deviceFactory
                    .OpenAsync(cancellationToken)
                    .ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                throw;
            }
            catch (DriverUnavailableException exception)
            {
                SetStatus(CaptureSourceStatusKind.DriverUnavailable, exception.Message);
                throw;
            }
            catch (Exception exception)
            {
                SetStatus(CaptureSourceStatusKind.Faulted, exception.Message);
                throw;
            }

            try
            {
                await ValidateProtocolAsync(candidate, cancellationToken).ConfigureAwait(false);
            }
            catch (InvalidDataException exception)
            {
                SetStatus(CaptureSourceStatusKind.ProtocolMismatch, exception.Message);
                await candidate.DisposeAsync().ConfigureAwait(false);
                throw;
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                await candidate.DisposeAsync().ConfigureAwait(false);
                throw;
            }
            catch (Exception exception)
            {
                SetStatus(CaptureSourceStatusKind.Faulted, exception.Message);
                await candidate.DisposeAsync().ConfigureAwait(false);
                throw;
            }

            _device = candidate;
            SetStatus(
                CaptureSourceStatusKind.Ready,
                $"Lemon serial monitor driver protocol {DriverProtocol.Version} is ready.");
            return candidate;
        }
        finally
        {
            _initializationGate.Release();
        }
    }

    private static async ValueTask ValidateProtocolAsync(
        IDriverDevice device,
        CancellationToken cancellationToken)
    {
        byte[] versionInfo = new byte[DriverProtocol.VersionInfoSize];
        int bytesReturned = await device.DeviceIoControlAsync(
            DriverProtocol.GetVersionIoControlCode,
            ReadOnlyMemory<byte>.Empty,
            versionInfo,
            cancellationToken).ConfigureAwait(false);
        if (bytesReturned != DriverProtocol.VersionInfoSize)
        {
            throw new InvalidDataException(
                $"The driver returned {bytesReturned} version bytes; " +
                $"expected {DriverProtocol.VersionInfoSize}.");
        }

        uint version = BinaryPrimitives.ReadUInt32LittleEndian(versionInfo);
        uint headerSize = BinaryPrimitives.ReadUInt32LittleEndian(versionInfo.AsSpan(4));
        uint maxPayload = BinaryPrimitives.ReadUInt32LittleEndian(versionInfo.AsSpan(8));
        if (version != DriverProtocol.Version ||
            headerSize != DriverProtocol.HeaderSize ||
            maxPayload != DriverProtocol.MaxPayload)
        {
            throw new InvalidDataException(
                $"Driver protocol mismatch: version={version}, header={headerSize}, " +
                $"payload={maxPayload}; expected version={DriverProtocol.Version}, " +
                $"header={DriverProtocol.HeaderSize}, payload={DriverProtocol.MaxPayload}.");
        }
    }

    private async ValueTask RefreshPortNamesAsync(
        CancellationToken cancellationToken)
    {
        try
        {
            IReadOnlyList<PortInfo> ports = await _portCatalog
                .GetPortsAsync(cancellationToken)
                .ConfigureAwait(false);
            IReadOnlyDictionary<ulong, string> portNames = ports
                .GroupBy(port => port.DeviceIdHash)
                .ToDictionary(group => group.Key, group => group.First().Name);
            Volatile.Write(ref _portNames, portNames);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch
        {
            // Port-name enrichment is optional; captured bytes must keep flowing.
            Volatile.Write(
                ref _portNames,
                new Dictionary<ulong, string>());
        }
    }

    private DateTimeOffset ToUtcTimestamp(long qpcTicks)
    {
        double elapsedSeconds = (qpcTicks - (double)_calibrationQpc) / _clock.Frequency;
        return _calibrationUtc + TimeSpan.FromSeconds(elapsedSeconds);
    }

    private void SetStatus(CaptureSourceStatusKind kind, string message) =>
        Volatile.Write(ref _status, new CaptureSourceStatus(kind, message));

    private void ThrowIfDisposed() =>
        ObjectDisposedException.ThrowIf(_disposed, this);
}
