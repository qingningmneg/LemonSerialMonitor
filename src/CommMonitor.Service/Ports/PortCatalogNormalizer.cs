using System.ComponentModel;
using System.Globalization;
using System.Numerics;

namespace CommMonitor.Service.Ports;

public sealed class SetupApiInfrastructureException : IOException
{
    public SetupApiInfrastructureException(string message)
        : base(message)
    {
    }

    internal SetupApiInfrastructureException(string operation, int nativeErrorCode)
        : base(
            $"{operation} Native error code: {nativeErrorCode}.",
            new Win32Exception(nativeErrorCode))
    {
        NativeErrorCode = nativeErrorCode;
    }

    internal SetupApiInfrastructureException(string message, Exception innerException)
        : base(message, innerException)
    {
    }

    public int? NativeErrorCode { get; }
}

public sealed class PortCatalogIntegrityException : IOException
{
    public PortCatalogIntegrityException(string message)
        : base(message)
    {
    }
}

internal enum PortDisplayNameQuality
{
    PortName = 0,
    DeviceDescription = 1,
    FriendlyName = 2,
}

internal sealed record PortCandidate(
    string Name,
    string FriendlyName,
    string DeviceInstanceId,
    PortDisplayNameQuality DisplayNameQuality);

internal sealed class PortCatalogNormalizer
{
    private readonly Func<string, ulong> _hasher;

    internal PortCatalogNormalizer()
        : this(DeviceIdHasher.Compute)
    {
    }

    internal PortCatalogNormalizer(Func<string, ulong> hasher)
    {
        ArgumentNullException.ThrowIfNull(hasher);
        _hasher = hasher;
    }

    internal IReadOnlyList<PortInfo> Normalize(IEnumerable<PortCandidate> candidates)
    {
        ArgumentNullException.ThrowIfNull(candidates);

        var byIdentity = new Dictionary<string, NormalizedCandidate>(StringComparer.Ordinal);
        var identityByPort = new Dictionary<string, string>(StringComparer.Ordinal);
        var identityByHash = new Dictionary<ulong, string>();

        foreach (PortCandidate candidate in candidates)
        {
            ArgumentNullException.ThrowIfNull(candidate);

            if (!TryCanonicalizePortName(candidate.Name, out string canonicalPortName))
            {
                throw new PortCatalogIntegrityException(
                    "A port candidate contains an invalid COM name.");
            }

            if (!IsValidDeviceInstanceId(candidate.DeviceInstanceId))
            {
                throw new PortCatalogIntegrityException(
                    $"Port {canonicalPortName} has an invalid device instance identity.");
            }

            string canonicalIdentity = candidate.DeviceInstanceId.ToUpperInvariant();
            ulong hash = _hasher(canonicalIdentity);

            if (byIdentity.TryGetValue(canonicalIdentity, out NormalizedCandidate? existingIdentity))
            {
                if (!string.Equals(
                        existingIdentity.Name,
                        canonicalPortName,
                        StringComparison.Ordinal))
                {
                    throw new PortCatalogIntegrityException(
                        $"Device instance {canonicalIdentity} claims more than one COM name.");
                }

                byIdentity[canonicalIdentity] = ChooseDisplay(existingIdentity, candidate);
                continue;
            }

            if (identityByPort.TryGetValue(canonicalPortName, out string? existingPortIdentity) &&
                !string.Equals(existingPortIdentity, canonicalIdentity, StringComparison.Ordinal))
            {
                throw new PortCatalogIntegrityException(
                    $"COM name {canonicalPortName} is claimed by more than one device instance.");
            }

            if (identityByHash.TryGetValue(hash, out string? existingHashIdentity) &&
                !string.Equals(existingHashIdentity, canonicalIdentity, StringComparison.Ordinal))
            {
                throw new PortCatalogIntegrityException(
                    "Two different device instances produced the same 64-bit identity hash.");
            }

            if (string.IsNullOrWhiteSpace(candidate.FriendlyName))
            {
                throw new PortCatalogIntegrityException(
                    $"Port {canonicalPortName} has an invalid display name.");
            }

            var normalized = new NormalizedCandidate(
                canonicalPortName,
                candidate.FriendlyName,
                canonicalIdentity,
                hash,
                candidate.DisplayNameQuality);
            byIdentity.Add(canonicalIdentity, normalized);
            identityByPort.Add(canonicalPortName, canonicalIdentity);
            identityByHash.Add(hash, canonicalIdentity);
        }

        return byIdentity.Values
            .OrderBy(candidate => ParsePortNumber(candidate.Name))
            .ThenBy(candidate => candidate.Name, StringComparer.Ordinal)
            .ThenBy(candidate => candidate.DeviceInstanceId, StringComparer.Ordinal)
            .Select(candidate => new PortInfo(
                candidate.Name,
                candidate.FriendlyName,
                candidate.DeviceInstanceId,
                candidate.DeviceIdHash))
            .ToArray();
    }

    internal static bool TryCanonicalizePortName(
        string? value,
        out string canonicalPortName)
    {
        canonicalPortName = string.Empty;
        if (value is null ||
            value.Length <= 3 ||
            !value.StartsWith("COM", StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        for (int index = 3; index < value.Length; index++)
        {
            if (value[index] is < '0' or > '9')
            {
                return false;
            }
        }

        canonicalPortName = value.ToUpperInvariant();
        return true;
    }

    internal static bool IsValidDeviceInstanceId(string? value)
    {
        if (string.IsNullOrWhiteSpace(value) ||
            value.IndexOf('\0', StringComparison.Ordinal) >= 0)
        {
            return false;
        }

        return !char.IsWhiteSpace(value[0]) &&
               !char.IsWhiteSpace(value[^1]);
    }

    private static NormalizedCandidate ChooseDisplay(
        NormalizedCandidate existing,
        PortCandidate candidate)
    {
        if (string.IsNullOrWhiteSpace(candidate.FriendlyName))
        {
            throw new PortCatalogIntegrityException(
                $"Port {existing.Name} has an invalid display name.");
        }

        if (candidate.DisplayNameQuality > existing.DisplayNameQuality ||
            (candidate.DisplayNameQuality == existing.DisplayNameQuality &&
             StringComparer.Ordinal.Compare(candidate.FriendlyName, existing.FriendlyName) < 0))
        {
            return existing with
            {
                FriendlyName = candidate.FriendlyName,
                DisplayNameQuality = candidate.DisplayNameQuality,
            };
        }

        return existing;
    }

    private static BigInteger ParsePortNumber(string portName) =>
        BigInteger.Parse(portName.AsSpan(3), CultureInfo.InvariantCulture);

    private sealed record NormalizedCandidate(
        string Name,
        string FriendlyName,
        string DeviceInstanceId,
        ulong DeviceIdHash,
        PortDisplayNameQuality DisplayNameQuality);
}
