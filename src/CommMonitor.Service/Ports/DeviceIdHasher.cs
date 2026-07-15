namespace CommMonitor.Service.Ports;

public static class DeviceIdHasher
{
    private const ulong Offset = 14695981039346656037UL;
    private const ulong Prime = 1099511628211UL;

    public static ulong Compute(string deviceInstanceId)
    {
        ArgumentNullException.ThrowIfNull(deviceInstanceId);

        unchecked
        {
            ulong hash = Offset;
            foreach (char value in deviceInstanceId)
            {
                char codeUnit = char.ToUpperInvariant(value);
                hash ^= (byte)codeUnit;
                hash *= Prime;
                hash ^= (byte)(codeUnit >> 8);
                hash *= Prime;
            }

            return hash;
        }
    }
}
