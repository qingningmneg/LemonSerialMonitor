namespace CommMonitor.Service.Ports;

internal interface ISetupApiRowSource
{
    IReadOnlyList<SetupApiPortRow> QueryRows(CancellationToken cancellationToken);
}

internal sealed record SetupApiPortRow(
    string? PortName,
    string? FriendlyName,
    string? DeviceDescription,
    string? DeviceInstanceId);

public sealed class SetupApiPortCatalog : IPortCatalog
{
    private readonly ISetupApiRowSource _rowSource;
    private readonly PortCatalogNormalizer _normalizer;

    internal SetupApiPortCatalog(
        ISetupApiRowSource rowSource,
        PortCatalogNormalizer normalizer)
    {
        ArgumentNullException.ThrowIfNull(rowSource);
        ArgumentNullException.ThrowIfNull(normalizer);
        _rowSource = rowSource;
        _normalizer = normalizer;
    }

    public async ValueTask<IReadOnlyList<PortInfo>> GetPortsAsync(
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        IReadOnlyList<SetupApiPortRow> rows = await Task.Run(
                () => _rowSource.QueryRows(cancellationToken),
                cancellationToken)
            .ConfigureAwait(false);
        cancellationToken.ThrowIfCancellationRequested();

        var candidates = new List<PortCandidate>(rows.Count);
        foreach (SetupApiPortRow row in rows)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (!PortCatalogNormalizer.TryCanonicalizePortName(
                    row.PortName,
                    out string canonicalPortName))
            {
                continue;
            }

            if (!PortCatalogNormalizer.IsValidDeviceInstanceId(row.DeviceInstanceId))
            {
                throw new PortCatalogIntegrityException(
                    $"Port {canonicalPortName} has an invalid device instance identity.");
            }

            (string displayName, PortDisplayNameQuality quality) =
                SelectDisplayName(row, canonicalPortName);
            candidates.Add(new PortCandidate(
                canonicalPortName,
                displayName,
                row.DeviceInstanceId!,
                quality));
        }

        return _normalizer.Normalize(candidates);
    }

    private static (string Name, PortDisplayNameQuality Quality) SelectDisplayName(
        SetupApiPortRow row,
        string canonicalPortName)
    {
        if (!string.IsNullOrWhiteSpace(row.FriendlyName))
        {
            return (row.FriendlyName, PortDisplayNameQuality.FriendlyName);
        }

        if (!string.IsNullOrWhiteSpace(row.DeviceDescription))
        {
            return (row.DeviceDescription, PortDisplayNameQuality.DeviceDescription);
        }

        return (canonicalPortName, PortDisplayNameQuality.PortName);
    }
}
