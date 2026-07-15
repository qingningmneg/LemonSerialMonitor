namespace CommMonitor.Service.Ports;

public interface IPortCatalog
{
    ValueTask<IReadOnlyList<PortInfo>> GetPortsAsync(
        CancellationToken cancellationToken);
}

public sealed record PortInfo(
    string Name,
    string FriendlyName,
    string PnpDeviceId,
    ulong DeviceIdHash);
