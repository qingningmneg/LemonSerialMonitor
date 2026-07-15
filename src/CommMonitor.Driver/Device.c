#include "Driver.h"
#include <initguid.h>
#include <devpkey.h>

static ULONGLONG
CmonQueryDeviceIdHash(
    _In_ WDFDEVICE Device)
{
    WDFMEMORY propertyMemory;
    WDF_DEVICE_PROPERTY_DATA propertyData;
    DEVPROPTYPE propertyType;
    const WCHAR* deviceInstanceId;
    SIZE_T propertyLength;
    SIZE_T codeUnitCapacity;
    SIZE_T codeUnitCount;
    ULONGLONG hash;
    NTSTATUS status;

    propertyMemory = NULL;
    propertyType = DEVPROP_TYPE_EMPTY;
    WDF_DEVICE_PROPERTY_DATA_INIT(
        &propertyData,
        &DEVPKEY_Device_InstanceId);
    status = WdfDeviceAllocAndQueryPropertyEx(
        Device,
        &propertyData,
        PagedPool,
        WDF_NO_OBJECT_ATTRIBUTES,
        &propertyMemory,
        &propertyType);
    if (!NT_SUCCESS(status) ||
        (propertyType != DEVPROP_TYPE_STRING))
    {
        if (propertyMemory != NULL)
        {
            WdfObjectDelete(propertyMemory);
        }
        return 0;
    }

    deviceInstanceId = (const WCHAR*)WdfMemoryGetBuffer(
        propertyMemory,
        &propertyLength);
    hash = 0;
    if ((deviceInstanceId != NULL) &&
        (propertyLength >= sizeof(WCHAR)) &&
        ((propertyLength % sizeof(WCHAR)) == 0))
    {
        codeUnitCapacity = propertyLength / sizeof(WCHAR);
        for (codeUnitCount = 0;
             (codeUnitCount < codeUnitCapacity) &&
             (deviceInstanceId[codeUnitCount] != L'\0');
             ++codeUnitCount)
        {
        }

        if ((codeUnitCount != 0) &&
            (codeUnitCount < codeUnitCapacity))
        {
            hash = CmonHashDeviceIdUtf16(
                (const uint16_t*)deviceInstanceId,
                codeUnitCount);
        }
    }

    WdfObjectDelete(propertyMemory);
    return hash;
}

NTSTATUS
CommMonitorEvtDeviceAdd(
    _In_ WDFDRIVER Driver,
    _Inout_ PWDFDEVICE_INIT DeviceInit)
{
    WDFDEVICE device;
    WDF_OBJECT_ATTRIBUTES deviceAttributes;
    WDF_IO_QUEUE_CONFIG queueConfig;
    PDEVICE_CONTEXT deviceContext;
    NTSTATUS status;

    WdfFdoInitSetFilter(DeviceInit);

    WDF_OBJECT_ATTRIBUTES_INIT_CONTEXT_TYPE(
        &deviceAttributes,
        DEVICE_CONTEXT);
    deviceAttributes.EvtCleanupCallback = CmonEvtDeviceContextCleanup;

    status = WdfDeviceCreate(
        &DeviceInit,
        &deviceAttributes,
        &device);
    if (!NT_SUCCESS(status))
    {
        return status;
    }

    deviceContext = CmonGetDeviceContext(device);
    deviceContext->Device = device;
    deviceContext->Driver = Driver;
    deviceContext->DeviceIdHash = CmonQueryDeviceIdHash(device);
    InitializeListHead(&deviceContext->ActiveListEntry);
    ExInitializeRundownProtection(&deviceContext->RecreateWorkRundown);
    deviceContext->Registered = FALSE;

    WDF_IO_QUEUE_CONFIG_INIT_DEFAULT_QUEUE(
        &queueConfig,
        WdfIoQueueDispatchParallel);
    queueConfig.EvtIoDefault = CommMonitorEvtIoDefault;
    queueConfig.EvtIoRead = CmonEvtIoRead;
    queueConfig.EvtIoWrite = CmonEvtIoWrite;
    queueConfig.EvtIoDeviceControl = CmonEvtIoSerialDeviceControl;

    status = WdfIoQueueCreate(
        device,
        &queueConfig,
        WDF_NO_OBJECT_ATTRIBUTES,
        WDF_NO_HANDLE);
    if (!NT_SUCCESS(status))
    {
        return status;
    }

    CmonRegisterPnpDevice(device);
    return STATUS_SUCCESS;
}

VOID
CmonEvtDeviceContextCleanup(
    _In_ WDFOBJECT DeviceObject)
{
    PDEVICE_CONTEXT deviceContext;

    deviceContext = CmonGetDeviceContext((WDFDEVICE)DeviceObject);
    CmonUnregisterPnpDevice((WDFDEVICE)DeviceObject);
    ExWaitForRundownProtectionRelease(&deviceContext->RecreateWorkRundown);
}

VOID
CommMonitorEvtIoDefault(
    _In_ WDFQUEUE Queue,
    _In_ WDFREQUEST Request)
{
    WDF_REQUEST_SEND_OPTIONS options;
    WDFDEVICE device;

    device = WdfIoQueueGetDevice(Queue);
    WdfRequestFormatRequestUsingCurrentType(Request);
    WDF_REQUEST_SEND_OPTIONS_INIT(
        &options,
        WDF_REQUEST_SEND_OPTION_SEND_AND_FORGET);

    if (!WdfRequestSend(
            Request,
            WdfDeviceGetIoTarget(device),
            &options))
    {
        WdfRequestComplete(Request, WdfRequestGetStatus(Request));
    }
}
