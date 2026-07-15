using System.Management;
using System.Text.RegularExpressions;

namespace CommMonitor.Service.Ports;

public sealed partial class WmiPortCatalog : IPortCatalog
{
    private readonly Func<CancellationToken, IReadOnlyList<WmiPortRow>> _queryRows;

    public WmiPortCatalog()
        : this(QueryRows)
    {
    }

    internal WmiPortCatalog(
        Func<CancellationToken, IReadOnlyList<WmiPortRow>> queryRows)
    {
        ArgumentNullException.ThrowIfNull(queryRows);
        _queryRows = queryRows;
    }

    public async ValueTask<IReadOnlyList<PortInfo>> GetPortsAsync(
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();

        IReadOnlyList<WmiPortRow> rows;
        try
        {
            rows = await Task.Run(
                    () => _queryRows(cancellationToken),
                    cancellationToken)
                .ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception error)
        {
            throw new IOException(
                "Unable to query serial ports through WMI.",
                error);
        }

        return ParseRows(rows);
    }

    internal static IReadOnlyList<PortInfo> ParseRows(IEnumerable<WmiPortRow> rows)
    {
        ArgumentNullException.ThrowIfNull(rows);

        var candidates = rows
            .Select(row => TryParseCandidate(row, out PortCandidate? candidate)
                ? candidate
                : null)
            .OfType<PortCandidate>();
        return new PortCatalogNormalizer().Normalize(candidates);
    }

    internal static bool TryParseRow(WmiPortRow row, out PortInfo? port)
    {
        ArgumentNullException.ThrowIfNull(row);

        port = null;
        if (!TryParseCandidate(row, out PortCandidate? candidate))
        {
            return false;
        }

        port = AssertSingle(new PortCatalogNormalizer().Normalize([candidate!]));
        return true;
    }

    private static bool TryParseCandidate(
        WmiPortRow row,
        out PortCandidate? candidate)
    {
        candidate = null;
        if (string.IsNullOrWhiteSpace(row.Name) ||
            !PortCatalogNormalizer.IsValidDeviceInstanceId(row.PnpDeviceId))
        {
            return false;
        }

        Match match = FinalComSuffix().Match(row.Name);
        if (!match.Success)
        {
            return false;
        }

        string portName = match.Groups[1].Value.ToUpperInvariant();
        candidate = new PortCandidate(
            portName,
            row.Name,
            row.PnpDeviceId!,
            PortDisplayNameQuality.FriendlyName);
        return true;
    }

    private static PortInfo AssertSingle(IReadOnlyList<PortInfo> ports)
    {
        if (ports.Count != 1)
        {
            throw new PortCatalogIntegrityException(
                "A valid WMI row did not normalize to exactly one port.");
        }

        return ports[0];
    }

    private static IReadOnlyList<WmiPortRow> QueryRows(
        CancellationToken cancellationToken)
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException(
                "Serial-port discovery through WMI is available only on Windows.");
        }

        var rows = new List<WmiPortRow>();
        using var searcher = new ManagementObjectSearcher(
            "root\\CIMV2",
            "SELECT Name, PNPDeviceID FROM Win32_PnPEntity " +
            "WHERE Name LIKE '%(COM%'");
        using ManagementObjectCollection results = searcher.Get();

        foreach (ManagementBaseObject result in results)
        {
            cancellationToken.ThrowIfCancellationRequested();
            rows.Add(new WmiPortRow(
                result["Name"] as string,
                result["PNPDeviceID"] as string));
        }

        return rows;
    }

    [GeneratedRegex(
        @"\((COM[0-9]+)\)$",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex FinalComSuffix();
}

public sealed record WmiPortRow(string? Name, string? PnpDeviceId);
