using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace CommMonitor.Service.Ports;

[Flags]
internal enum SetupApiGetClassDevicesFlags : uint
{
    Present = 0x00000002,
}

internal enum SetupApiRegistryProperty : uint
{
    DeviceDescription = 0x00000000,
    FriendlyName = 0x0000000C,
}

[StructLayout(LayoutKind.Sequential)]
internal struct SetupApiDeviceInfoData
{
    internal uint Size;
    internal Guid ClassGuid;
    internal uint DeviceInstance;
    internal IntPtr Reserved;

    internal static SetupApiDeviceInfoData Create() => new()
    {
        Size = checked((uint)Marshal.SizeOf<SetupApiDeviceInfoData>()),
    };
}

internal sealed class SafeDeviceInfoSetHandle : SafeHandleZeroOrMinusOneIsInvalid
{
    private readonly Action<IntPtr> _release;

    internal SafeDeviceInfoSetHandle(IntPtr handle, Action<IntPtr> release)
        : base(ownsHandle: true)
    {
        ArgumentNullException.ThrowIfNull(release);
        _release = release;
        SetHandle(handle);
    }

    protected override bool ReleaseHandle()
    {
        _release(handle);
        return true;
    }
}

internal sealed class SafeDeviceRegistryKeyHandle : SafeHandleZeroOrMinusOneIsInvalid
{
    private readonly Action<IntPtr> _release;

    internal SafeDeviceRegistryKeyHandle(IntPtr handle, Action<IntPtr> release)
        : base(ownsHandle: true)
    {
        ArgumentNullException.ThrowIfNull(release);
        _release = release;
        SetHandle(handle);
    }

    protected override bool ReleaseHandle()
    {
        _release(handle);
        return true;
    }
}

internal interface ISetupApiCalls
{
    SafeDeviceInfoSetHandle GetClassDevices(
        Guid classGuid,
        SetupApiGetClassDevicesFlags flags,
        out int error);

    bool EnumDeviceInfo(
        SafeDeviceInfoSetHandle deviceInfoSet,
        uint memberIndex,
        ref SetupApiDeviceInfoData deviceInfoData,
        out int error);

    SafeDeviceRegistryKeyHandle OpenDeviceRegistryKey(
        SafeDeviceInfoSetHandle deviceInfoSet,
        ref SetupApiDeviceInfoData deviceInfoData,
        out int error);

    int QueryRegistryValue(
        SafeDeviceRegistryKeyHandle key,
        string valueName,
        byte[]? buffer,
        ref uint byteCount,
        out uint type);

    bool GetDeviceInstanceId(
        SafeDeviceInfoSetHandle deviceInfoSet,
        ref SetupApiDeviceInfoData deviceInfoData,
        char[]? buffer,
        uint bufferCharacters,
        out uint requiredCharacters,
        out int error);

    bool GetDeviceRegistryProperty(
        SafeDeviceInfoSetHandle deviceInfoSet,
        ref SetupApiDeviceInfoData deviceInfoData,
        SetupApiRegistryProperty property,
        byte[]? buffer,
        ref uint requiredBytes,
        out uint type,
        out int error);
}

internal sealed class SetupApiCalls : ISetupApiCalls
{
    private const uint DeviceRegistryGlobal = 0x00000001;
    private const uint DeviceRegistryKey = 0x00000001;
    private const uint KeyQueryValue = 0x0001;

    public SafeDeviceInfoSetHandle GetClassDevices(
        Guid classGuid,
        SetupApiGetClassDevicesFlags flags,
        out int error)
    {
        IntPtr rawHandle = NativeMethods.SetupDiGetClassDevsW(
            ref classGuid,
            null,
            IntPtr.Zero,
            (uint)flags);
        int capturedError = Marshal.GetLastPInvokeError();
        error = rawHandle == new IntPtr(-1)
            ? capturedError
            : 0;
        return new SafeDeviceInfoSetHandle(
            rawHandle,
            handle => _ = NativeMethods.SetupDiDestroyDeviceInfoList(handle));
    }

    public bool EnumDeviceInfo(
        SafeDeviceInfoSetHandle deviceInfoSet,
        uint memberIndex,
        ref SetupApiDeviceInfoData deviceInfoData,
        out int error)
    {
        bool success = NativeMethods.SetupDiEnumDeviceInfo(
            deviceInfoSet,
            memberIndex,
            ref deviceInfoData);
        error = success ? 0 : Marshal.GetLastPInvokeError();
        return success;
    }

    public SafeDeviceRegistryKeyHandle OpenDeviceRegistryKey(
        SafeDeviceInfoSetHandle deviceInfoSet,
        ref SetupApiDeviceInfoData deviceInfoData,
        out int error)
    {
        IntPtr rawHandle = NativeMethods.SetupDiOpenDevRegKey(
            deviceInfoSet,
            ref deviceInfoData,
            DeviceRegistryGlobal,
            0,
            DeviceRegistryKey,
            KeyQueryValue);
        int capturedError = Marshal.GetLastPInvokeError();
        error = rawHandle == new IntPtr(-1)
            ? capturedError
            : 0;
        return new SafeDeviceRegistryKeyHandle(
            rawHandle,
            handle => _ = NativeMethods.RegCloseKey(handle));
    }

    public int QueryRegistryValue(
        SafeDeviceRegistryKeyHandle key,
        string valueName,
        byte[]? buffer,
        ref uint byteCount,
        out uint type) => NativeMethods.RegQueryValueExW(
            key,
            valueName,
            IntPtr.Zero,
            out type,
            buffer,
            ref byteCount);

    public bool GetDeviceInstanceId(
        SafeDeviceInfoSetHandle deviceInfoSet,
        ref SetupApiDeviceInfoData deviceInfoData,
        char[]? buffer,
        uint bufferCharacters,
        out uint requiredCharacters,
        out int error)
    {
        bool success = NativeMethods.SetupDiGetDeviceInstanceIdW(
            deviceInfoSet,
            ref deviceInfoData,
            buffer,
            bufferCharacters,
            out requiredCharacters);
        error = success ? 0 : Marshal.GetLastPInvokeError();
        return success;
    }

    public bool GetDeviceRegistryProperty(
        SafeDeviceInfoSetHandle deviceInfoSet,
        ref SetupApiDeviceInfoData deviceInfoData,
        SetupApiRegistryProperty property,
        byte[]? buffer,
        ref uint requiredBytes,
        out uint type,
        out int error)
    {
        bool success = NativeMethods.SetupDiGetDeviceRegistryPropertyW(
            deviceInfoSet,
            ref deviceInfoData,
            (uint)property,
            out type,
            buffer,
            requiredBytes,
            out requiredBytes);
        error = success ? 0 : Marshal.GetLastPInvokeError();
        return success;
    }

    private static class NativeMethods
    {
        [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        internal static extern IntPtr SetupDiGetClassDevsW(
            ref Guid classGuid,
            string? enumerator,
            IntPtr parentWindow,
            uint flags);

        [DllImport("setupapi.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool SetupDiEnumDeviceInfo(
            SafeDeviceInfoSetHandle deviceInfoSet,
            uint memberIndex,
            ref SetupApiDeviceInfoData deviceInfoData);

        [DllImport("setupapi.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool SetupDiDestroyDeviceInfoList(IntPtr deviceInfoSet);

        [DllImport("setupapi.dll", SetLastError = true)]
        internal static extern IntPtr SetupDiOpenDevRegKey(
            SafeDeviceInfoSetHandle deviceInfoSet,
            ref SetupApiDeviceInfoData deviceInfoData,
            uint scope,
            uint hardwareProfile,
            uint keyType,
            uint desiredAccess);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode)]
        internal static extern int RegQueryValueExW(
            SafeDeviceRegistryKeyHandle key,
            string valueName,
            IntPtr reserved,
            out uint type,
            [Out] byte[]? data,
            ref uint dataLength);

        [DllImport("advapi32.dll")]
        internal static extern int RegCloseKey(IntPtr key);

        [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool SetupDiGetDeviceInstanceIdW(
            SafeDeviceInfoSetHandle deviceInfoSet,
            ref SetupApiDeviceInfoData deviceInfoData,
            [Out] char[]? deviceInstanceId,
            uint deviceInstanceIdSize,
            out uint requiredSize);

        [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool SetupDiGetDeviceRegistryPropertyW(
            SafeDeviceInfoSetHandle deviceInfoSet,
            ref SetupApiDeviceInfoData deviceInfoData,
            uint property,
            out uint propertyRegistryDataType,
            [Out] byte[]? propertyBuffer,
            uint propertyBufferSize,
            out uint requiredSize);
    }
}

internal sealed class SetupApiNative : ISetupApiRowSource
{
    private static readonly Guid PortsClassGuid =
        new("4D36E978-E325-11CE-BFC1-08002BE10318");

    private const int ErrorFileNotFound = 2;
    private const int ErrorPathNotFound = 3;
    private const int ErrorInvalidData = 13;
    private const int ErrorInsufficientBuffer = 122;
    private const int ErrorMoreData = 234;
    private const int ErrorNoMoreItems = 259;
    private const uint RegistryString = 1;
    private const int MaxPortNameCodeUnits = 256;
    private const int MaxIdentityCodeUnits = 4096;
    private const int MaxDisplayNameCodeUnits = 4096;
    private const int MaxSizeRaceRetries = 3;

    private readonly ISetupApiCalls _calls;

    internal SetupApiNative(ISetupApiCalls calls)
    {
        ArgumentNullException.ThrowIfNull(calls);
        _calls = calls;
    }

    public IReadOnlyList<SetupApiPortRow> QueryRows(CancellationToken cancellationToken)
    {
        try
        {
            return QueryRowsCore(cancellationToken);
        }
        catch (Exception error) when (
            error is DllNotFoundException or
                EntryPointNotFoundException or
                BadImageFormatException)
        {
            throw new SetupApiInfrastructureException(
                "The Windows SetupAPI or registry native facility is unavailable.",
                error);
        }
    }

    private IReadOnlyList<SetupApiPortRow> QueryRowsCore(
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        using SafeDeviceInfoSetHandle deviceInfoSet = _calls.GetClassDevices(
            PortsClassGuid,
            SetupApiGetClassDevicesFlags.Present,
            out int classDevicesError);
        cancellationToken.ThrowIfCancellationRequested();
        if (deviceInfoSet.IsInvalid)
        {
            throw Infrastructure(
                "Unable to open the present Ports setup class.",
                classDevicesError);
        }

        var rows = new List<SetupApiPortRow>();
        for (uint index = 0; ; index++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            SetupApiDeviceInfoData deviceInfoData = SetupApiDeviceInfoData.Create();
            bool found = _calls.EnumDeviceInfo(
                deviceInfoSet,
                index,
                ref deviceInfoData,
                out int enumerationError);
            cancellationToken.ThrowIfCancellationRequested();
            if (!found)
            {
                if (enumerationError == ErrorNoMoreItems)
                {
                    break;
                }

                throw Infrastructure(
                    "Unable to enumerate a present Ports-class device.",
                    enumerationError);
            }

            cancellationToken.ThrowIfCancellationRequested();
            using SafeDeviceRegistryKeyHandle registryKey = _calls.OpenDeviceRegistryKey(
                deviceInfoSet,
                ref deviceInfoData,
                out int openRegistryError);
            cancellationToken.ThrowIfCancellationRequested();
            if (registryKey.IsInvalid)
            {
                if (IsMissingData(openRegistryError))
                {
                    continue;
                }

                throw Infrastructure(
                    "Unable to open a Ports-class device registry key.",
                    openRegistryError);
            }

            string? portName = ReadRegistryString(
                registryKey,
                "PortName",
                MaxPortNameCodeUnits,
                cancellationToken);
            if (!PortCatalogNormalizer.TryCanonicalizePortName(
                    portName,
                    out string canonicalPortName))
            {
                continue;
            }

            string identity = ReadDeviceInstanceId(
                deviceInfoSet,
                ref deviceInfoData,
                cancellationToken);
            string? friendlyName = ReadDevicePropertyString(
                deviceInfoSet,
                ref deviceInfoData,
                SetupApiRegistryProperty.FriendlyName,
                cancellationToken);
            string? description = string.IsNullOrWhiteSpace(friendlyName)
                ? ReadDevicePropertyString(
                    deviceInfoSet,
                    ref deviceInfoData,
                    SetupApiRegistryProperty.DeviceDescription,
                    cancellationToken)
                : null;

            rows.Add(new SetupApiPortRow(
                canonicalPortName,
                friendlyName,
                description,
                identity));
        }

        return rows;
    }

    private string? ReadRegistryString(
        SafeDeviceRegistryKeyHandle key,
        string valueName,
        int maximumCodeUnits,
        CancellationToken cancellationToken)
    {
        uint requiredBytes = 0;
        int result = _calls.QueryRegistryValue(
            key,
            valueName,
            null,
            ref requiredBytes,
            out uint type);
        cancellationToken.ThrowIfCancellationRequested();

        if (IsMissingData(result))
        {
            return null;
        }

        if (result is not 0 and not ErrorMoreData)
        {
            throw Infrastructure(
                $"Unable to query device registry value {valueName}.",
                result);
        }

        if (type != RegistryString)
        {
            return null;
        }

        ValidateByteSize(requiredBytes, maximumCodeUnits, valueName);
        int sizeRaceRetries = 0;
        while (true)
        {
            byte[] buffer = new byte[checked((int)requiredBytes)];
            uint returnedBytes = requiredBytes;
            result = _calls.QueryRegistryValue(
                key,
                valueName,
                buffer,
                ref returnedBytes,
                out type);
            cancellationToken.ThrowIfCancellationRequested();

            if (IsMissingData(result))
            {
                return null;
            }

            if (result == 0)
            {
                if (type != RegistryString)
                {
                    return null;
                }

                ValidateByteSize(returnedBytes, maximumCodeUnits, valueName);
                if (returnedBytes > buffer.Length)
                {
                    throw Integrity($"The {valueName} length exceeded its allocated buffer.");
                }

                return ParseUtf16Bytes(buffer, returnedBytes, valueName);
            }

            if (result != ErrorMoreData)
            {
                throw Infrastructure(
                    $"Unable to read device registry value {valueName}.",
                    result);
            }

            if (type != RegistryString)
            {
                return null;
            }

            ValidateByteSize(returnedBytes, maximumCodeUnits, valueName);
            if (sizeRaceRetries == MaxSizeRaceRetries)
            {
                throw Integrity($"The {valueName} length did not stabilize.");
            }

            sizeRaceRetries++;
            requiredBytes = returnedBytes;
        }
    }

    private string ReadDeviceInstanceId(
        SafeDeviceInfoSetHandle deviceInfoSet,
        ref SetupApiDeviceInfoData deviceInfoData,
        CancellationToken cancellationToken)
    {
        bool success = _calls.GetDeviceInstanceId(
            deviceInfoSet,
            ref deviceInfoData,
            null,
            0,
            out uint requiredCharacters,
            out int error);
        cancellationToken.ThrowIfCancellationRequested();

        if (!success && IsMissingData(error))
        {
            throw Integrity("A COM device is missing its device instance identity.");
        }

        if (!success && error != ErrorInsufficientBuffer)
        {
            throw Infrastructure("Unable to query a device instance identity.", error);
        }

        ValidateCharacterSize(requiredCharacters, MaxIdentityCodeUnits, "device instance ID");
        int sizeRaceRetries = 0;
        while (true)
        {
            char[] buffer = new char[checked((int)requiredCharacters)];
            success = _calls.GetDeviceInstanceId(
                deviceInfoSet,
                ref deviceInfoData,
                buffer,
                checked((uint)buffer.Length),
                out uint returnedCharacters,
                out error);
            cancellationToken.ThrowIfCancellationRequested();

            if (success)
            {
                ValidateCharacterSize(
                    returnedCharacters,
                    MaxIdentityCodeUnits,
                    "device instance ID");
                if (returnedCharacters > buffer.Length)
                {
                    throw Integrity(
                        "The device instance ID length exceeded its allocated buffer.");
                }

                string identity = ParseUtf16Characters(
                    buffer,
                    checked((int)returnedCharacters),
                    "device instance ID");
                if (!PortCatalogNormalizer.IsValidDeviceInstanceId(identity))
                {
                    throw Integrity("A COM device has an invalid device instance identity.");
                }

                return identity.ToUpperInvariant();
            }

            if (IsMissingData(error))
            {
                throw Integrity("A COM device is missing its device instance identity.");
            }

            if (error != ErrorInsufficientBuffer)
            {
                throw Infrastructure("Unable to read a device instance identity.", error);
            }

            ValidateCharacterSize(
                returnedCharacters,
                MaxIdentityCodeUnits,
                "device instance ID");
            if (sizeRaceRetries == MaxSizeRaceRetries)
            {
                throw Integrity("The device instance ID length did not stabilize.");
            }

            sizeRaceRetries++;
            requiredCharacters = returnedCharacters;
        }
    }

    private string? ReadDevicePropertyString(
        SafeDeviceInfoSetHandle deviceInfoSet,
        ref SetupApiDeviceInfoData deviceInfoData,
        SetupApiRegistryProperty property,
        CancellationToken cancellationToken)
    {
        uint requiredBytes = 0;
        bool success = _calls.GetDeviceRegistryProperty(
            deviceInfoSet,
            ref deviceInfoData,
            property,
            null,
            ref requiredBytes,
            out uint type,
            out int error);
        cancellationToken.ThrowIfCancellationRequested();

        if (!success && IsMissingData(error))
        {
            return null;
        }

        if (!success && error != ErrorInsufficientBuffer)
        {
            throw Infrastructure($"Unable to query device property {property}.", error);
        }

        if (type != RegistryString)
        {
            throw Integrity($"The {property} property is not REG_SZ text.");
        }

        ValidateByteSize(requiredBytes, MaxDisplayNameCodeUnits, property.ToString());
        int sizeRaceRetries = 0;
        while (true)
        {
            byte[] buffer = new byte[checked((int)requiredBytes)];
            uint returnedBytes = requiredBytes;
            success = _calls.GetDeviceRegistryProperty(
                deviceInfoSet,
                ref deviceInfoData,
                property,
                buffer,
                ref returnedBytes,
                out type,
                out error);
            cancellationToken.ThrowIfCancellationRequested();

            if (!success && IsMissingData(error))
            {
                return null;
            }

            if (success)
            {
                if (type != RegistryString)
                {
                    throw Integrity($"The {property} property is not REG_SZ text.");
                }

                ValidateByteSize(returnedBytes, MaxDisplayNameCodeUnits, property.ToString());
                if (returnedBytes > buffer.Length)
                {
                    throw Integrity($"The {property} length exceeded its allocated buffer.");
                }

                return ParseUtf16Bytes(buffer, returnedBytes, property.ToString());
            }

            if (error != ErrorInsufficientBuffer)
            {
                throw Infrastructure($"Unable to read device property {property}.", error);
            }

            if (type != RegistryString)
            {
                throw Integrity($"The {property} property is not REG_SZ text.");
            }

            ValidateByteSize(returnedBytes, MaxDisplayNameCodeUnits, property.ToString());
            if (sizeRaceRetries == MaxSizeRaceRetries)
            {
                throw Integrity($"The {property} length did not stabilize.");
            }

            sizeRaceRetries++;
            requiredBytes = returnedBytes;
        }
    }

    private static void ValidateByteSize(
        uint requiredBytes,
        int maximumCodeUnits,
        string fieldName)
    {
        uint maximumBytes = checked((uint)maximumCodeUnits * sizeof(char));
        if (requiredBytes < sizeof(char) ||
            (requiredBytes & 1) != 0 ||
            requiredBytes > maximumBytes)
        {
            throw Integrity($"The {fieldName} byte length is outside its allowed bound.");
        }
    }

    private static void ValidateCharacterSize(
        uint requiredCharacters,
        int maximumCodeUnits,
        string fieldName)
    {
        if (requiredCharacters == 0 || requiredCharacters > maximumCodeUnits)
        {
            throw Integrity($"The {fieldName} length is outside its allowed bound.");
        }
    }

    private static string ParseUtf16Bytes(
        byte[] buffer,
        uint byteCount,
        string fieldName)
    {
        int characterCount = checked((int)(byteCount / sizeof(char)));
        var characters = MemoryMarshal.Cast<byte, char>(
            buffer.AsSpan(0, checked((int)byteCount)));
        return ParseUtf16Characters(characters, characterCount, fieldName);
    }

    private static string ParseUtf16Characters(
        ReadOnlySpan<char> characters,
        int characterCount,
        string fieldName)
    {
        if (characterCount <= 0 ||
            characters.Length < characterCount ||
            characters[characterCount - 1] != '\0')
        {
            throw Integrity($"The {fieldName} is missing its final NUL terminator.");
        }

        ReadOnlySpan<char> value = characters[..(characterCount - 1)];
        if (value.IndexOf('\0') >= 0)
        {
            throw Integrity($"The {fieldName} contains an embedded NUL.");
        }

        return new string(value);
    }

    private static bool IsMissingData(int error) =>
        error is ErrorFileNotFound or ErrorPathNotFound or ErrorInvalidData;

    private static SetupApiInfrastructureException Infrastructure(
        string operation,
        int nativeErrorCode) => new(operation, nativeErrorCode);

    private static PortCatalogIntegrityException Integrity(string message) => new(message);
}
