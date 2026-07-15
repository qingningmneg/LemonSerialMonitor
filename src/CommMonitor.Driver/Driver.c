#include "Driver.h"

#ifdef ALLOC_PRAGMA
#pragma alloc_text(INIT, DriverEntry)
#endif

NTSTATUS
DriverEntry(
    _In_ PDRIVER_OBJECT DriverObject,
    _In_ PUNICODE_STRING RegistryPath)
{
    WDF_DRIVER_CONFIG config;
    WDF_OBJECT_ATTRIBUTES driverAttributes;
    WDF_OBJECT_ATTRIBUTES lockAttributes;
    WDFDRIVER driver;
    PDRIVER_CONTEXT context;
    NTSTATUS status;

    WDF_DRIVER_CONFIG_INIT(&config, CommMonitorEvtDeviceAdd);
    WDF_OBJECT_ATTRIBUTES_INIT_CONTEXT_TYPE(
        &driverAttributes,
        DRIVER_CONTEXT);
    driverAttributes.EvtCleanupCallback = CmonDriverContextCleanup;

    status = WdfDriverCreate(
        DriverObject,
        RegistryPath,
        &driverAttributes,
        &config,
        &driver);
    if (!NT_SUCCESS(status))
    {
        return status;
    }

    context = CmonGetDriverContext(driver);
    context->CaptureState = CMON_STATE_STOPPED;
    context->ControlState = CmonControlAbsent;
    context->RecreateAfterDelete = FALSE;
    context->RecreateWorkerQueued = FALSE;
    InitializeListHead(&context->ActivePnpList);
    context->Ring.Slots = ExAllocatePool2(
        POOL_FLAG_NON_PAGED,
        sizeof(*context->Ring.Slots) * CMON_RING_CAPACITY,
        CMON_POOL_TAG);
    if (context->Ring.Slots == NULL)
    {
        return STATUS_INSUFFICIENT_RESOURCES;
    }
    CmonRingCoreInitialize(
        &context->Ring,
        context->Ring.Slots,
        CMON_RING_CAPACITY);

    WDF_OBJECT_ATTRIBUTES_INIT(&lockAttributes);
    lockAttributes.ParentObject = driver;
    status = WdfSpinLockCreate(&lockAttributes, &context->SpinLock);
    if (!NT_SUCCESS(status))
    {
        ExFreePoolWithTag(context->Ring.Slots, CMON_POOL_TAG);
        context->Ring.Slots = NULL;
        return status;
    }

    status = WdfWaitLockCreate(&lockAttributes, &context->LifecycleLock);
    if (!NT_SUCCESS(status))
    {
        ExFreePoolWithTag(context->Ring.Slots, CMON_POOL_TAG);
        context->Ring.Slots = NULL;
        return status;
    }

    (VOID)CmonCreateControlDevice(driver);

    return STATUS_SUCCESS;
}

VOID
CmonDriverContextCleanup(
    _In_ WDFOBJECT DriverObject)
{
    PDRIVER_CONTEXT context;

    context = CmonGetDriverContext((WDFDRIVER)DriverObject);
    if (context->Ring.Slots != NULL)
    {
        ExFreePoolWithTag(context->Ring.Slots, CMON_POOL_TAG);
        context->Ring.Slots = NULL;
    }
}
