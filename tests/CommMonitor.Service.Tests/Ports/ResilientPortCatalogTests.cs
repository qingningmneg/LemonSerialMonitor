using CommMonitor.Service.Ports;
using Microsoft.Extensions.Logging;

namespace CommMonitor.Service.Tests.Ports;

public sealed class ResilientPortCatalogTests
{
    [Fact]
    public async Task SetupAPI_successful_empty_result_never_calls_WMI()
    {
        var setup = new StubCatalog([]);
        var wmi = new StubCatalog([], new InvalidOperationException("must not run"));
        var logger = new RecordingLogger();
        var catalog = new ResilientPortCatalog(setup, wmi, logger);

        IReadOnlyList<PortInfo> ports = await catalog.GetPortsAsync(CancellationToken.None);

        Assert.Empty(ports);
        Assert.Equal(1, setup.CallCount);
        Assert.Equal(0, wmi.CallCount);
        Assert.Empty(logger.Warnings);
    }

    [Theory]
    [MemberData(nameof(NonFallbackErrors))]
    public async Task Integrity_cancellation_and_unexpected_errors_do_not_call_WMI(Exception failure)
    {
        var setup = new StubCatalog([], failure);
        var wmi = new StubCatalog([]);
        var catalog = new ResilientPortCatalog(setup, wmi, new RecordingLogger());

        Exception actual = await Assert.ThrowsAnyAsync<Exception>(() =>
            catalog.GetPortsAsync(CancellationToken.None).AsTask());

        Assert.Same(failure, actual);
        Assert.Equal(0, wmi.CallCount);
    }

    public static IEnumerable<object[]> NonFallbackErrors()
    {
        yield return [new PortCatalogIntegrityException("conflict")];
        yield return [new OperationCanceledException("cancel")];
        yield return [new InvalidOperationException("bug")];
    }

    [Fact]
    public async Task Infrastructure_failure_logs_once_then_returns_WMI_result()
    {
        var setupFailure = new SetupApiInfrastructureException("native unavailable");
        PortInfo expected = new("COM3", "Device", "USB\\ID", 7);
        var setup = new StubCatalog([], setupFailure);
        var wmi = new StubCatalog([expected]);
        var logger = new RecordingLogger();
        var catalog = new ResilientPortCatalog(setup, wmi, logger);

        IReadOnlyList<PortInfo> ports = await catalog.GetPortsAsync(CancellationToken.None);

        Assert.Same(expected, Assert.Single(ports));
        Assert.Equal(1, wmi.CallCount);
        Assert.Single(logger.Warnings);
        Assert.Same(setupFailure, logger.Warnings[0]);
    }

    [Fact]
    public async Task WMI_cancellation_after_fallback_propagates_unchanged()
    {
        var setup = new StubCatalog([], new SetupApiInfrastructureException("native unavailable"));
        var cancellation = new OperationCanceledException("wmi cancelled");
        var wmi = new StubCatalog([], cancellation);
        var catalog = new ResilientPortCatalog(setup, wmi, new RecordingLogger());

        OperationCanceledException actual = await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            catalog.GetPortsAsync(CancellationToken.None).AsTask());

        Assert.Same(cancellation, actual);
    }

    [Fact]
    public async Task Dual_failure_retains_both_original_exceptions_and_an_aggregate_inner()
    {
        var setupFailure = new SetupApiInfrastructureException("native unavailable");
        var wmiFailure = new IOException("WMI unavailable");
        var setup = new StubCatalog([], setupFailure);
        var wmi = new StubCatalog([], wmiFailure);
        var catalog = new ResilientPortCatalog(setup, wmi, new RecordingLogger());

        PortDiscoveryException error = await Assert.ThrowsAsync<PortDiscoveryException>(() =>
            catalog.GetPortsAsync(CancellationToken.None).AsTask());

        Assert.Same(setupFailure, error.SetupApiException);
        Assert.Same(wmiFailure, error.WmiException);
        AggregateException aggregate = Assert.IsType<AggregateException>(error.InnerException);
        Assert.Collection(
            aggregate.InnerExceptions,
            first => Assert.Same(setupFailure, first),
            second => Assert.Same(wmiFailure, second));
    }

    private sealed class StubCatalog(
        IReadOnlyList<PortInfo> ports,
        Exception? failure = null) : IPortCatalog
    {
        public int CallCount { get; private set; }

        public ValueTask<IReadOnlyList<PortInfo>> GetPortsAsync(
            CancellationToken cancellationToken)
        {
            CallCount++;
            if (failure is not null)
            {
                return ValueTask.FromException<IReadOnlyList<PortInfo>>(failure);
            }

            return ValueTask.FromResult(ports);
        }
    }

    private sealed class RecordingLogger : ILogger<ResilientPortCatalog>
    {
        public List<Exception?> Warnings { get; } = [];

        public IDisposable? BeginScope<TState>(TState state) where TState : notnull => null;

        public bool IsEnabled(LogLevel logLevel) => true;

        public void Log<TState>(
            LogLevel logLevel,
            EventId eventId,
            TState state,
            Exception? exception,
            Func<TState, Exception?, string> formatter)
        {
            if (logLevel == LogLevel.Warning)
            {
                Warnings.Add(exception);
            }
        }
    }
}
