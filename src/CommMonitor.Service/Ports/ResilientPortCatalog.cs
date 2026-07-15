using Microsoft.Extensions.Logging;

namespace CommMonitor.Service.Ports;

public sealed class PortDiscoveryException : IOException
{
    internal PortDiscoveryException(
        SetupApiInfrastructureException setupApiException,
        Exception wmiException)
        : base(
            "Serial-port discovery failed through both SetupAPI and WMI.",
            new AggregateException(setupApiException, wmiException))
    {
        SetupApiException = setupApiException;
        WmiException = wmiException;
    }

    public SetupApiInfrastructureException SetupApiException { get; }

    public Exception WmiException { get; }
}

public sealed class ResilientPortCatalog : IPortCatalog
{
    private readonly IPortCatalog _setupApiCatalog;
    private readonly IPortCatalog _wmiCatalog;
    private readonly ILogger<ResilientPortCatalog> _logger;

    internal ResilientPortCatalog(
        IPortCatalog setupApiCatalog,
        IPortCatalog wmiCatalog,
        ILogger<ResilientPortCatalog> logger)
    {
        ArgumentNullException.ThrowIfNull(setupApiCatalog);
        ArgumentNullException.ThrowIfNull(wmiCatalog);
        ArgumentNullException.ThrowIfNull(logger);
        _setupApiCatalog = setupApiCatalog;
        _wmiCatalog = wmiCatalog;
        _logger = logger;
    }

    public async ValueTask<IReadOnlyList<PortInfo>> GetPortsAsync(
        CancellationToken cancellationToken)
    {
        try
        {
            return await _setupApiCatalog.GetPortsAsync(cancellationToken)
                .ConfigureAwait(false);
        }
        catch (SetupApiInfrastructureException setupApiError)
        {
            _logger.LogWarning(
                setupApiError,
                "SetupAPI serial-port discovery failed; trying WMI.");

            try
            {
                return await _wmiCatalog.GetPortsAsync(cancellationToken)
                    .ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                throw;
            }
            catch (Exception wmiError)
            {
                throw new PortDiscoveryException(setupApiError, wmiError);
            }
        }
    }
}
