using System.ComponentModel;
using System.Runtime.InteropServices;
using CommMonitor.Service.Ports;

namespace CommMonitor.Service.Tests.Ports;

public sealed class SetupApiPortCatalogTests
{
    private static readonly Guid PortsClassGuid =
        new("4D36E978-E325-11CE-BFC1-08002BE10318");

    [Fact]
    public void Native_queries_present_devices_from_the_Ports_class()
    {
        var calls = new ScriptedSetupApiCalls();
        var source = new SetupApiNative(calls);

        IReadOnlyList<SetupApiPortRow> rows = source.QueryRows(CancellationToken.None);

        Assert.Empty(rows);
        Assert.Equal(PortsClassGuid, calls.RequestedClassGuid);
        Assert.Equal(SetupApiGetClassDevicesFlags.Present, calls.RequestedFlags);
        Assert.Equal(1, calls.DeviceInfoSetReleaseCount);
    }

    [Fact]
    public void Native_Windows_interop_can_open_the_Ports_class()
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        var calls = new SetupApiCalls();
        using SafeDeviceInfoSetHandle handle = calls.GetClassDevices(
            PortsClassGuid,
            SetupApiGetClassDevicesFlags.Present,
            out int error);

        Assert.False(handle.IsInvalid, $"SetupDiGetClassDevsW failed with {error}.");
        SetupApiDeviceInfoData device = SetupApiDeviceInfoData.Create();
        bool found = calls.EnumDeviceInfo(handle, 0, ref device, out error);
        Assert.True(found || error == 259, $"SetupDiEnumDeviceInfo failed with {error}.");
    }

    [Fact]
    public void Native_treats_only_no_more_items_as_normal_completion()
    {
        bool lastErrorWasContaminated = false;
        var calls = new ScriptedSetupApiCalls
        {
            EnumerationTerminalError = 5,
            AfterEnumCall = () =>
            {
                Marshal.SetLastPInvokeError(87);
                lastErrorWasContaminated = true;
            },
        };
        var source = new SetupApiNative(calls);

        SetupApiInfrastructureException error = Assert.Throws<SetupApiInfrastructureException>(
            () => source.QueryRows(CancellationToken.None));

        Assert.Equal(5, error.NativeErrorCode);
        Assert.Equal(5, Assert.IsType<Win32Exception>(error.InnerException).NativeErrorCode);
        Assert.True(lastErrorWasContaminated);
        Assert.Equal(1, calls.DeviceInfoSetReleaseCount);
    }

    [Fact]
    public void Native_classifies_an_unavailable_native_library_as_infrastructure_failure()
    {
        var nativeFailure = new DllNotFoundException("setupapi unavailable");
        var calls = new ScriptedSetupApiCalls { GetClassDevicesFailure = nativeFailure };
        var source = new SetupApiNative(calls);

        SetupApiInfrastructureException error = Assert.Throws<SetupApiInfrastructureException>(
            () => source.QueryRows(CancellationToken.None));

        Assert.Same(nativeFailure, error.InnerException);
    }

    [Fact]
    public void Native_preserves_cancellation_during_terminal_enumeration()
    {
        using var cancellation = new CancellationTokenSource();
        var calls = new ScriptedSetupApiCalls { AfterEnumCall = cancellation.Cancel };
        var source = new SetupApiNative(calls);

        Assert.ThrowsAny<OperationCanceledException>(
            () => source.QueryRows(cancellation.Token));
        Assert.Equal(1, calls.DeviceInfoSetReleaseCount);
    }

    [Theory]
    [InlineData("LPT1")]
    [InlineData("COM")]
    [InlineData("COM1 ")]
    [InlineData("XCOM1")]
    [InlineData("COM-1")]
    [InlineData("")]
    public async Task Catalog_filters_non_COM_names_without_demanding_an_identity(string portName)
    {
        var source = new StubRowSource([
            new SetupApiPortRow(portName, null, null, null),
        ]);
        var catalog = new SetupApiPortCatalog(source, new PortCatalogNormalizer());

        IReadOnlyList<PortInfo> ports = await catalog.GetPortsAsync(CancellationToken.None);

        Assert.Empty(ports);
    }

    [Fact]
    public void Native_skips_LPT_before_reading_the_instance_id()
    {
        var calls = new ScriptedSetupApiCalls();
        calls.Devices.Add(new NativeDevice("LPT1", null, null, null));
        var source = new SetupApiNative(calls);

        IReadOnlyList<SetupApiPortRow> rows = source.QueryRows(CancellationToken.None);

        Assert.Empty(rows);
        Assert.Equal(0, calls.InstanceIdCallCount);
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData(" USB\\DEVICE")]
    [InlineData("USB\\DEVICE ")]
    [InlineData("USB\0DEVICE")]
    public async Task Valid_COM_rows_require_an_exact_instance_identity(string? identity)
    {
        var source = new StubRowSource([
            new SetupApiPortRow("COM7", "Device", null, identity),
        ]);
        var catalog = new SetupApiPortCatalog(source, new PortCatalogNormalizer());

        await Assert.ThrowsAsync<PortCatalogIntegrityException>(() =>
            catalog.GetPortsAsync(CancellationToken.None).AsTask());
    }

    [Fact]
    public async Task Catalog_canonicalizes_names_and_identity_and_uses_display_fallback_order()
    {
        var source = new StubRowSource([
            new SetupApiPortRow("com10", "Friendly", "Description", "usb\\z"),
            new SetupApiPortRow("COM2", null, "Description 2", "usb\\b"),
            new SetupApiPortRow("COM001", "", "", "usb\\a"),
        ]);
        var catalog = new SetupApiPortCatalog(source, new PortCatalogNormalizer());

        IReadOnlyList<PortInfo> ports = await catalog.GetPortsAsync(CancellationToken.None);

        Assert.Equal(["COM001", "COM2", "COM10"], ports.Select(port => port.Name));
        Assert.Equal(["COM001", "Description 2", "Friendly"], ports.Select(port => port.FriendlyName));
        Assert.Equal(["USB\\A", "USB\\B", "USB\\Z"], ports.Select(port => port.PnpDeviceId));
    }

    [Fact]
    public async Task Normalizer_folds_only_the_same_instance_and_COM()
    {
        var normalizer = new PortCatalogNormalizer();
        IReadOnlyList<PortInfo> ports = normalizer.Normalize([
            new PortCandidate("COM4", "Zulu", "usb\\id", PortDisplayNameQuality.FriendlyName),
            new PortCandidate("com4", "Alpha", "USB\\ID", PortDisplayNameQuality.FriendlyName),
        ]);

        PortInfo port = Assert.Single(ports);
        Assert.Equal("COM4", port.Name);
        Assert.Equal("USB\\ID", port.PnpDeviceId);
        Assert.Equal("Alpha", port.FriendlyName);
        Assert.Equal(DeviceIdHasher.Compute("USB\\ID"), port.DeviceIdHash);
        await Task.CompletedTask;
    }

    [Fact]
    public void Normalizer_rejects_one_instance_claiming_two_COM_names()
    {
        var normalizer = new PortCatalogNormalizer();

        Assert.Throws<PortCatalogIntegrityException>(() => normalizer.Normalize([
            new PortCandidate("COM1", "One", "USB\\ID", PortDisplayNameQuality.FriendlyName),
            new PortCandidate("COM2", "Two", "USB\\ID", PortDisplayNameQuality.FriendlyName),
        ]));
    }

    [Fact]
    public void Normalizer_rejects_one_COM_name_claimed_by_two_instances()
    {
        var normalizer = new PortCatalogNormalizer();

        Assert.Throws<PortCatalogIntegrityException>(() => normalizer.Normalize([
            new PortCandidate("COM1", "One", "USB\\A", PortDisplayNameQuality.FriendlyName),
            new PortCandidate("COM1", "Two", "USB\\B", PortDisplayNameQuality.FriendlyName),
        ]));
    }

    [Fact]
    public void Normalizer_rejects_a_hash_collision_between_different_instances()
    {
        var normalizer = new PortCatalogNormalizer(_ => 42UL);

        Assert.Throws<PortCatalogIntegrityException>(() => normalizer.Normalize([
            new PortCandidate("COM1", "One", "USB\\A", PortDisplayNameQuality.FriendlyName),
            new PortCandidate("COM2", "Two", "USB\\B", PortDisplayNameQuality.FriendlyName),
        ]));
    }

    [Fact]
    public void Duplicate_display_selection_is_quality_then_ordinal_and_order_independent()
    {
        PortCandidate[] rows = [
            new("COM8", "COM8", "USB\\ID", PortDisplayNameQuality.PortName),
            new("COM8", "Zulu description", "USB\\ID", PortDisplayNameQuality.DeviceDescription),
            new("COM8", "Zulu friendly", "USB\\ID", PortDisplayNameQuality.FriendlyName),
            new("COM8", "Alpha friendly", "USB\\ID", PortDisplayNameQuality.FriendlyName),
        ];
        var normalizer = new PortCatalogNormalizer();

        string forward = Assert.Single(normalizer.Normalize(rows)).FriendlyName;
        string reverse = Assert.Single(normalizer.Normalize(rows.Reverse())).FriendlyName;

        Assert.Equal("Alpha friendly", forward);
        Assert.Equal(forward, reverse);
    }

    [Theory]
    [InlineData(0u)]
    [InlineData(3u)]
    [InlineData(514u)]
    [InlineData(uint.MaxValue)]
    public void Native_rejects_invalid_PortName_byte_sizes(uint requiredBytes)
    {
        var calls = OneDeviceCalls();
        calls.RegistryReplies.Enqueue(RegistryReply.Size(requiredBytes));
        var source = new SetupApiNative(calls);

        Assert.Throws<PortCatalogIntegrityException>(
            () => source.QueryRows(CancellationToken.None));
        Assert.Equal(1, calls.DeviceInfoSetReleaseCount);
        Assert.Equal(1, calls.RegistryReleaseCount);
    }

    [Fact]
    public void Native_skips_a_non_string_PortName()
    {
        var calls = OneDeviceCalls();
        calls.RegistryReplies.Enqueue(RegistryReply.Size(10, type: 4));
        var source = new SetupApiNative(calls);

        Assert.Empty(source.QueryRows(CancellationToken.None));
        Assert.Equal(0, calls.InstanceIdCallCount);
    }

    [Theory]
    [InlineData("COM1")]
    [InlineData("CO\0M1\0")]
    public void Native_rejects_missing_or_embedded_PortName_terminators(string rawText)
    {
        var calls = OneDeviceCalls();
        byte[] bytes = System.Text.Encoding.Unicode.GetBytes(rawText);
        calls.RegistryReplies.Enqueue(RegistryReply.Size((uint)bytes.Length));
        calls.RegistryReplies.Enqueue(RegistryReply.Data(bytes));
        var source = new SetupApiNative(calls);

        Assert.Throws<PortCatalogIntegrityException>(
            () => source.QueryRows(CancellationToken.None));
    }

    [Fact]
    public void Native_accepts_a_bounded_size_race_that_stabilizes()
    {
        var calls = OneDeviceCalls();
        calls.RegistryReplies.Enqueue(RegistryReply.Size(10));
        calls.RegistryReplies.Enqueue(RegistryReply.MoreData(12));
        calls.RegistryReplies.Enqueue(RegistryReply.Data(Utf16("COM12")));
        var source = new SetupApiNative(calls);

        SetupApiPortRow row = Assert.Single(source.QueryRows(CancellationToken.None));

        Assert.Equal("COM12", row.PortName);
    }

    [Fact]
    public void Native_rejects_a_size_that_never_stabilizes_after_three_retries()
    {
        var calls = OneDeviceCalls();
        calls.RegistryReplies.Enqueue(RegistryReply.Size(10));
        calls.RegistryReplies.Enqueue(RegistryReply.MoreData(12));
        calls.RegistryReplies.Enqueue(RegistryReply.MoreData(14));
        calls.RegistryReplies.Enqueue(RegistryReply.MoreData(16));
        calls.RegistryReplies.Enqueue(RegistryReply.MoreData(18));
        var source = new SetupApiNative(calls);

        Assert.Throws<PortCatalogIntegrityException>(
            () => source.QueryRows(CancellationToken.None));
        Assert.Empty(calls.RegistryReplies);
    }

    [Fact]
    public void Native_classifies_second_PortName_error_before_interpreting_stale_type()
    {
        var calls = OneDeviceCalls();
        calls.RegistryReplies.Enqueue(RegistryReply.Size(10));
        calls.RegistryReplies.Enqueue(RegistryReply.Failure(5, type: 4, bytes: 10));
        var source = new SetupApiNative(calls);

        SetupApiInfrastructureException error = Assert.Throws<SetupApiInfrastructureException>(
            () => source.QueryRows(CancellationToken.None));

        Assert.Equal(5, error.NativeErrorCode);
    }

    [Theory]
    [InlineData(0u)]
    [InlineData(4097u)]
    [InlineData(uint.MaxValue)]
    public void Native_rejects_invalid_instance_id_sizes(uint requiredCharacters)
    {
        var calls = OneDeviceCalls();
        calls.InstanceReplies.Enqueue(InstanceReply.Size(requiredCharacters));
        var source = new SetupApiNative(calls);

        Assert.Throws<PortCatalogIntegrityException>(
            () => source.QueryRows(CancellationToken.None));
    }

    [Fact]
    public void Native_rejects_missing_and_embedded_instance_id_terminators()
    {
        foreach (char[] invalid in new[]
                 {
                     "USB\\ID".ToCharArray(),
                     ['U', 'S', '\0', 'B', '\0'],
                 })
        {
            var calls = OneDeviceCalls();
            calls.InstanceReplies.Enqueue(InstanceReply.Size((uint)invalid.Length));
            calls.InstanceReplies.Enqueue(InstanceReply.Data(invalid));
            var source = new SetupApiNative(calls);

            Assert.Throws<PortCatalogIntegrityException>(
                () => source.QueryRows(CancellationToken.None));
        }
    }

    [Fact]
    public void Native_accepts_an_instance_id_size_race_that_stabilizes()
    {
        var calls = OneDeviceCalls();
        calls.InstanceReplies.Enqueue(InstanceReply.Size(5));
        calls.InstanceReplies.Enqueue(InstanceReply.MoreData(7));
        calls.InstanceReplies.Enqueue(InstanceReply.Data("USB\\ID\0".ToCharArray()));
        var source = new SetupApiNative(calls);

        SetupApiPortRow row = Assert.Single(source.QueryRows(CancellationToken.None));

        Assert.Equal("USB\\ID", row.DeviceInstanceId);
    }

    [Fact]
    public void Native_rejects_an_instance_id_size_that_never_stabilizes()
    {
        var calls = OneDeviceCalls();
        calls.InstanceReplies.Enqueue(InstanceReply.Size(5));
        calls.InstanceReplies.Enqueue(InstanceReply.MoreData(6));
        calls.InstanceReplies.Enqueue(InstanceReply.MoreData(7));
        calls.InstanceReplies.Enqueue(InstanceReply.MoreData(8));
        calls.InstanceReplies.Enqueue(InstanceReply.MoreData(9));
        var source = new SetupApiNative(calls);

        Assert.Throws<PortCatalogIntegrityException>(
            () => source.QueryRows(CancellationToken.None));
        Assert.Empty(calls.InstanceReplies);
    }

    [Fact]
    public void Native_classifies_a_second_instance_id_error_as_infrastructure_failure()
    {
        var calls = OneDeviceCalls();
        calls.InstanceReplies.Enqueue(InstanceReply.Size(5));
        calls.InstanceReplies.Enqueue(InstanceReply.Failure(5, characters: 5));
        var source = new SetupApiNative(calls);

        SetupApiInfrastructureException error = Assert.Throws<SetupApiInfrastructureException>(
            () => source.QueryRows(CancellationToken.None));

        Assert.Equal(5, error.NativeErrorCode);
    }

    [Fact]
    public void Native_rejects_an_instance_id_length_larger_than_its_buffer()
    {
        var calls = OneDeviceCalls();
        calls.InstanceReplies.Enqueue(InstanceReply.Size(5));
        calls.InstanceReplies.Enqueue(InstanceReply.SuccessfulRead(6));
        var source = new SetupApiNative(calls);

        Assert.Throws<PortCatalogIntegrityException>(
            () => source.QueryRows(CancellationToken.None));
    }

    [Fact]
    public void Native_rejects_a_non_string_friendly_name()
    {
        var calls = OneDeviceCalls();
        calls.PropertyReplies.Enqueue(PropertyReply.Size(12, type: 4));
        var source = new SetupApiNative(calls);

        Assert.Throws<PortCatalogIntegrityException>(
            () => source.QueryRows(CancellationToken.None));
    }

    [Fact]
    public void Native_rejects_a_non_string_device_description()
    {
        var calls = new ScriptedSetupApiCalls();
        calls.Devices.Add(new NativeDevice(
            "COM1",
            null,
            "Description",
            "USB\\DEVICE"));
        calls.PropertyReplies.Enqueue(PropertyReply.Missing());
        calls.PropertyReplies.Enqueue(PropertyReply.Size(12, type: 4));
        var source = new SetupApiNative(calls);

        Assert.Throws<PortCatalogIntegrityException>(
            () => source.QueryRows(CancellationToken.None));
    }

    [Fact]
    public void Native_degrades_from_a_blank_friendly_name_to_description()
    {
        var calls = new ScriptedSetupApiCalls();
        calls.Devices.Add(new NativeDevice(
            "COM1",
            "   ",
            "Description",
            "USB\\DEVICE"));
        var source = new SetupApiNative(calls);

        SetupApiPortRow row = Assert.Single(source.QueryRows(CancellationToken.None));

        Assert.Equal("   ", row.FriendlyName);
        Assert.Equal("Description", row.DeviceDescription);
    }

    [Theory]
    [InlineData(0u)]
    [InlineData(3u)]
    [InlineData(8194u)]
    [InlineData(uint.MaxValue)]
    public void Native_rejects_invalid_friendly_name_byte_sizes(uint requiredBytes)
    {
        var calls = OneDeviceCalls();
        calls.PropertyReplies.Enqueue(PropertyReply.Size(requiredBytes));
        var source = new SetupApiNative(calls);

        Assert.Throws<PortCatalogIntegrityException>(
            () => source.QueryRows(CancellationToken.None));
    }

    [Theory]
    [InlineData("Name")]
    [InlineData("Na\0me\0")]
    public void Native_rejects_missing_or_embedded_property_terminators(string rawText)
    {
        var calls = OneDeviceCalls();
        byte[] bytes = System.Text.Encoding.Unicode.GetBytes(rawText);
        calls.PropertyReplies.Enqueue(PropertyReply.Size((uint)bytes.Length));
        calls.PropertyReplies.Enqueue(PropertyReply.Data(bytes));
        var source = new SetupApiNative(calls);

        Assert.Throws<PortCatalogIntegrityException>(
            () => source.QueryRows(CancellationToken.None));
    }

    [Fact]
    public void Native_degrades_if_a_friendly_name_disappears_during_second_read()
    {
        var calls = OneDeviceCalls();
        calls.PropertyReplies.Enqueue(PropertyReply.Size(10));
        calls.PropertyReplies.Enqueue(PropertyReply.Missing());
        var source = new SetupApiNative(calls);

        SetupApiPortRow row = Assert.Single(source.QueryRows(CancellationToken.None));

        Assert.Null(row.FriendlyName);
        Assert.Equal("Description", row.DeviceDescription);
    }

    [Fact]
    public void Native_accepts_a_property_size_race_that_stabilizes()
    {
        var calls = OneDeviceCalls();
        calls.PropertyReplies.Enqueue(PropertyReply.Size(10));
        calls.PropertyReplies.Enqueue(PropertyReply.MoreData(12));
        calls.PropertyReplies.Enqueue(PropertyReply.Data(Utf16("NameX")));
        var source = new SetupApiNative(calls);

        SetupApiPortRow row = Assert.Single(source.QueryRows(CancellationToken.None));

        Assert.Equal("NameX", row.FriendlyName);
    }

    [Fact]
    public void Native_rejects_a_property_size_that_never_stabilizes()
    {
        var calls = OneDeviceCalls();
        calls.PropertyReplies.Enqueue(PropertyReply.Size(10));
        calls.PropertyReplies.Enqueue(PropertyReply.MoreData(12));
        calls.PropertyReplies.Enqueue(PropertyReply.MoreData(14));
        calls.PropertyReplies.Enqueue(PropertyReply.MoreData(16));
        calls.PropertyReplies.Enqueue(PropertyReply.MoreData(18));
        var source = new SetupApiNative(calls);

        Assert.Throws<PortCatalogIntegrityException>(
            () => source.QueryRows(CancellationToken.None));
        Assert.Empty(calls.PropertyReplies);
    }

    [Fact]
    public void Native_classifies_second_property_error_before_interpreting_stale_type()
    {
        var calls = OneDeviceCalls();
        calls.PropertyReplies.Enqueue(PropertyReply.Size(10));
        calls.PropertyReplies.Enqueue(PropertyReply.Failure(5, type: 4, bytes: 10));
        var source = new SetupApiNative(calls);

        SetupApiInfrastructureException error = Assert.Throws<SetupApiInfrastructureException>(
            () => source.QueryRows(CancellationToken.None));

        Assert.Equal(5, error.NativeErrorCode);
    }

    [Fact]
    public void Native_rejects_property_type_mutation_during_a_size_race()
    {
        var calls = OneDeviceCalls();
        calls.PropertyReplies.Enqueue(PropertyReply.Size(10));
        calls.PropertyReplies.Enqueue(PropertyReply.MoreData(12, type: 4));
        var source = new SetupApiNative(calls);

        Assert.Throws<PortCatalogIntegrityException>(
            () => source.QueryRows(CancellationToken.None));
    }

    [Fact]
    public void Native_rejects_a_property_length_larger_than_its_buffer()
    {
        var calls = OneDeviceCalls();
        calls.PropertyReplies.Enqueue(PropertyReply.Size(10));
        calls.PropertyReplies.Enqueue(PropertyReply.SuccessfulRead(12));
        var source = new SetupApiNative(calls);

        Assert.Throws<PortCatalogIntegrityException>(
            () => source.QueryRows(CancellationToken.None));
    }

    [Fact]
    public void Native_closes_each_handle_once_on_success()
    {
        var calls = OneDeviceCalls();
        var source = new SetupApiNative(calls);

        Assert.Single(source.QueryRows(CancellationToken.None));
        Assert.Equal(1, calls.DeviceInfoSetReleaseCount);
        Assert.Equal(1, calls.RegistryReleaseCount);
    }

    [Fact]
    public void Native_closes_each_handle_once_on_native_failure()
    {
        var calls = OneDeviceCalls();
        calls.RegistryReplies.Enqueue(RegistryReply.Failure(5));
        var source = new SetupApiNative(calls);

        Assert.Throws<SetupApiInfrastructureException>(
            () => source.QueryRows(CancellationToken.None));
        Assert.Equal(1, calls.DeviceInfoSetReleaseCount);
        Assert.Equal(1, calls.RegistryReleaseCount);
    }

    [Fact]
    public void Native_closes_each_handle_once_on_integrity_failure()
    {
        var calls = OneDeviceCalls();
        calls.InstanceReplies.Enqueue(InstanceReply.Size(0));
        var source = new SetupApiNative(calls);

        Assert.Throws<PortCatalogIntegrityException>(
            () => source.QueryRows(CancellationToken.None));
        Assert.Equal(1, calls.DeviceInfoSetReleaseCount);
        Assert.Equal(1, calls.RegistryReleaseCount);
    }

    [Fact]
    public void Native_closes_each_handle_once_on_cancellation()
    {
        using var cancellation = new CancellationTokenSource();
        var calls = OneDeviceCalls();
        calls.AfterRegistryCall = cancellation.Cancel;
        var source = new SetupApiNative(calls);

        Assert.ThrowsAny<OperationCanceledException>(
            () => source.QueryRows(cancellation.Token));
        Assert.Equal(1, calls.DeviceInfoSetReleaseCount);
        Assert.Equal(1, calls.RegistryReleaseCount);
    }

    private static ScriptedSetupApiCalls OneDeviceCalls()
    {
        var calls = new ScriptedSetupApiCalls();
        calls.Devices.Add(new NativeDevice(
            "COM1",
            "Friendly",
            "Description",
            "USB\\DEVICE"));
        return calls;
    }

    private static byte[] Utf16(string value) =>
        System.Text.Encoding.Unicode.GetBytes(value + "\0");

    private sealed class StubRowSource(IReadOnlyList<SetupApiPortRow> rows)
        : ISetupApiRowSource
    {
        public IReadOnlyList<SetupApiPortRow> QueryRows(CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            return rows;
        }
    }

    private sealed record NativeDevice(
        string? PortName,
        string? FriendlyName,
        string? Description,
        string? InstanceId);

    private sealed record RegistryReply(
        int Result,
        uint RequiredBytes,
        uint Type,
        byte[]? Payload)
    {
        public static RegistryReply Size(uint bytes, uint type = 1) =>
            new(0, bytes, type, null);

        public static RegistryReply Data(byte[] payload, uint type = 1) =>
            new(0, (uint)payload.Length, type, payload);

        public static RegistryReply MoreData(uint bytes, uint type = 1) =>
            new(234, bytes, type, null);

        public static RegistryReply Failure(
            int error,
            uint type = 1,
            uint bytes = 0) => new(error, bytes, type, null);
    }

    private sealed record InstanceReply(
        bool Success,
        uint RequiredCharacters,
        int Error,
        char[]? Payload)
    {
        public static InstanceReply Size(uint characters) =>
            new(false, characters, 122, null);

        public static InstanceReply Data(char[] payload) =>
            new(true, (uint)payload.Length, 0, payload);

        public static InstanceReply MoreData(uint characters) =>
            new(false, characters, 122, null);

        public static InstanceReply Failure(int error, uint characters = 0) =>
            new(false, characters, error, null);

        public static InstanceReply SuccessfulRead(
            uint characters,
            char[]? payload = null) =>
            new(true, characters, 0, payload);
    }

    private sealed record PropertyReply(
        bool Success,
        uint RequiredBytes,
        uint Type,
        int Error,
        byte[]? Payload)
    {
        public static PropertyReply Size(uint bytes, uint type = 1) =>
            new(false, bytes, type, 122, null);

        public static PropertyReply Data(byte[] payload, uint type = 1) =>
            new(true, (uint)payload.Length, type, 0, payload);

        public static PropertyReply MoreData(uint bytes, uint type = 1) =>
            new(false, bytes, type, 122, null);

        public static PropertyReply Missing() => new(false, 0, 1, 13, null);

        public static PropertyReply Failure(
            int error,
            uint type = 1,
            uint bytes = 0) => new(false, bytes, type, error, null);

        public static PropertyReply SuccessfulRead(
            uint bytes,
            uint type = 1,
            byte[]? payload = null) => new(true, bytes, type, 0, payload);
    }

    private sealed class ScriptedSetupApiCalls : ISetupApiCalls
    {
        private const int ErrorNoMoreItems = 259;
        private const int ErrorInsufficientBuffer = 122;
        private const int ErrorInvalidData = 13;
        private const uint RegSz = 1;

        public List<NativeDevice> Devices { get; } = [];
        public Queue<RegistryReply> RegistryReplies { get; } = new();
        public Queue<InstanceReply> InstanceReplies { get; } = new();
        public Queue<PropertyReply> PropertyReplies { get; } = new();
        public Guid RequestedClassGuid { get; private set; }
        public SetupApiGetClassDevicesFlags RequestedFlags { get; private set; }
        public int EnumerationTerminalError { get; init; } = ErrorNoMoreItems;
        public Exception? GetClassDevicesFailure { get; init; }
        public int DeviceInfoSetReleaseCount { get; private set; }
        public int RegistryReleaseCount { get; private set; }
        public int InstanceIdCallCount { get; private set; }
        public Action? AfterRegistryCall { get; set; }
        public Action? AfterEnumCall { get; set; }

        public SafeDeviceInfoSetHandle GetClassDevices(
            Guid classGuid,
            SetupApiGetClassDevicesFlags flags,
            out int error)
        {
            if (GetClassDevicesFailure is not null)
            {
                throw GetClassDevicesFailure;
            }

            RequestedClassGuid = classGuid;
            RequestedFlags = flags;
            error = 0;
            return new SafeDeviceInfoSetHandle(
                new IntPtr(0x1000),
                _ => DeviceInfoSetReleaseCount++);
        }

        public bool EnumDeviceInfo(
            SafeDeviceInfoSetHandle deviceInfoSet,
            uint memberIndex,
            ref SetupApiDeviceInfoData deviceInfoData,
            out int error)
        {
            if (memberIndex >= Devices.Count)
            {
                error = EnumerationTerminalError;
                AfterEnumCall?.Invoke();
                return false;
            }

            deviceInfoData.DeviceInstance = memberIndex;
            error = 0;
            AfterEnumCall?.Invoke();
            return true;
        }

        public SafeDeviceRegistryKeyHandle OpenDeviceRegistryKey(
            SafeDeviceInfoSetHandle deviceInfoSet,
            ref SetupApiDeviceInfoData deviceInfoData,
            out int error)
        {
            error = 0;
            return new SafeDeviceRegistryKeyHandle(
                new IntPtr(0x2000 + deviceInfoData.DeviceInstance),
                _ => RegistryReleaseCount++);
        }

        public int QueryRegistryValue(
            SafeDeviceRegistryKeyHandle key,
            string valueName,
            byte[]? buffer,
            ref uint byteCount,
            out uint type)
        {
            if (RegistryReplies.TryDequeue(out RegistryReply? scripted))
            {
                byteCount = scripted.RequiredBytes;
                type = scripted.Type;
                if (buffer is not null && scripted.Payload is not null)
                {
                    scripted.Payload.AsSpan().CopyTo(buffer);
                }

                AfterRegistryCall?.Invoke();
                return scripted.Result;
            }

            int index = checked((int)(key.DangerousGetHandle().ToInt64() - 0x2000));
            string? value = Devices[index].PortName;
            if (value is null)
            {
                byteCount = 0;
                type = RegSz;
                AfterRegistryCall?.Invoke();
                return 2;
            }

            byte[] payload = Utf16(value);
            byteCount = (uint)payload.Length;
            type = RegSz;
            if (buffer is not null)
            {
                payload.AsSpan().CopyTo(buffer);
            }

            AfterRegistryCall?.Invoke();
            return 0;
        }

        public bool GetDeviceInstanceId(
            SafeDeviceInfoSetHandle deviceInfoSet,
            ref SetupApiDeviceInfoData deviceInfoData,
            char[]? buffer,
            uint bufferCharacters,
            out uint requiredCharacters,
            out int error)
        {
            InstanceIdCallCount++;
            if (InstanceReplies.TryDequeue(out InstanceReply? scripted))
            {
                requiredCharacters = scripted.RequiredCharacters;
                error = scripted.Error;
                if (buffer is not null && scripted.Payload is not null)
                {
                    scripted.Payload.AsSpan().CopyTo(buffer);
                }

                return scripted.Success;
            }

            string? value = Devices[checked((int)deviceInfoData.DeviceInstance)].InstanceId;
            if (value is null)
            {
                requiredCharacters = 0;
                error = ErrorInvalidData;
                return false;
            }

            char[] payload = (value + "\0").ToCharArray();
            requiredCharacters = (uint)payload.Length;
            if (buffer is null || bufferCharacters < payload.Length)
            {
                error = ErrorInsufficientBuffer;
                return false;
            }

            payload.AsSpan().CopyTo(buffer);
            error = 0;
            return true;
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
            if (PropertyReplies.TryDequeue(out PropertyReply? scripted))
            {
                requiredBytes = scripted.RequiredBytes;
                type = scripted.Type;
                error = scripted.Error;
                if (buffer is not null && scripted.Payload is not null)
                {
                    scripted.Payload.AsSpan().CopyTo(buffer);
                }

                return scripted.Success;
            }

            NativeDevice device = Devices[checked((int)deviceInfoData.DeviceInstance)];
            string? value = property == SetupApiRegistryProperty.FriendlyName
                ? device.FriendlyName
                : device.Description;
            if (value is null)
            {
                requiredBytes = 0;
                type = RegSz;
                error = ErrorInvalidData;
                return false;
            }

            byte[] payload = Utf16(value);
            requiredBytes = (uint)payload.Length;
            type = RegSz;
            if (buffer is null || buffer.Length < payload.Length)
            {
                error = ErrorInsufficientBuffer;
                return false;
            }

            payload.AsSpan().CopyTo(buffer);
            error = 0;
            return true;
        }
    }
}
