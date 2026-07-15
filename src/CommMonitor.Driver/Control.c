#include "Driver.h"

#define CMON_RECREATE_COLLISION_RETRIES 4u
#define CMON_RECREATE_RETRY_DELAY_100NS (-100000LL)

static PDEVICE_CONTEXT
CmonAcquireRecreateAnchorLocked(
    _In_ PDRIVER_CONTEXT Context)
{
    PLIST_ENTRY entry;

    for (entry = Context->ActivePnpList.Flink;
         entry != &Context->ActivePnpList;
         entry = entry->Flink)
    {
        PDEVICE_CONTEXT deviceContext;

        deviceContext = CONTAINING_RECORD(
            entry,
            DEVICE_CONTEXT,
            ActiveListEntry);
        if (deviceContext->Registered &&
            ExAcquireRundownProtection(
                &deviceContext->RecreateWorkRundown))
        {
            return deviceContext;
        }
    }

    return NULL;
}

static VOID
CmonQueueRecreateWorker(
    _Inout_ PDRIVER_CONTEXT Context,
    _In_ PDEVICE_CONTEXT AnchorContext,
    _In_ PDEVICE_OBJECT AnchorWdmDevice)
{
    PIO_WORKITEM workItem;

    workItem = IoAllocateWorkItem(AnchorWdmDevice);
    if (workItem == NULL)
    {
        (VOID)WdfWaitLockAcquire(Context->LifecycleLock, NULL);
        if ((Context->ControlState == CmonControlDeleting) &&
            (Context->ControlDevice == NULL) &&
            Context->RecreateWorkerQueued)
        {
            Context->RecreateWorkerQueued = FALSE;
        }
        WdfWaitLockRelease(Context->LifecycleLock);
        ExReleaseRundownProtection(&AnchorContext->RecreateWorkRundown);
        return;
    }

    IoQueueWorkItemEx(
        workItem,
        CmonRecreateControlWorkItem,
        DelayedWorkQueue,
        NULL);
}

static NTSTATUS
CmonSetConfig(
    _In_ WDFREQUEST Request,
    _In_ SIZE_T InputBufferLength,
    _In_ SIZE_T OutputBufferLength,
    _Inout_ PDRIVER_CONTEXT Context)
{
    const uint8_t* configBytes;
    uint32_t deviceCount;
    uint32_t deviceIndex;
    uint32_t state;
    PVOID inputBuffer;
    NTSTATUS status;

    if ((OutputBufferLength != 0) ||
        (InputBufferLength < CMON_CONFIG_PREFIX_SIZE))
    {
        return STATUS_INVALID_PARAMETER;
    }

    status = WdfRequestRetrieveInputBuffer(
        Request,
        CMON_CONFIG_PREFIX_SIZE,
        &inputBuffer,
        NULL);
    if (!NT_SUCCESS(status))
    {
        return STATUS_INVALID_PARAMETER;
    }

    configBytes = (const uint8_t*)inputBuffer;
    if (!CmonConfigBytesAreValid(
            configBytes,
            InputBufferLength,
            &state,
            &deviceCount))
    {
        return STATUS_INVALID_PARAMETER;
    }

    WdfSpinLockAcquire(Context->SpinLock);
    Context->CaptureState = state;
    Context->SelectedDeviceCount = deviceCount;
    RtlZeroMemory(
        Context->SelectedDeviceHashes,
        sizeof(Context->SelectedDeviceHashes));
    for (deviceIndex = 0; deviceIndex < deviceCount; ++deviceIndex)
    {
        Context->SelectedDeviceHashes[deviceIndex] =
            CmonConfigReadDeviceHash(configBytes, deviceIndex);
    }
    WdfSpinLockRelease(Context->SpinLock);

    return STATUS_SUCCESS;
}

static NTSTATUS
CmonGetVersion(
    _In_ WDFREQUEST Request,
    _In_ SIZE_T InputBufferLength,
    _In_ SIZE_T OutputBufferLength,
    _Out_ PULONG_PTR BytesWritten)
{
    PCMON_VERSION_INFO versionInfo;
    PVOID outputBuffer;
    NTSTATUS status;

    if ((InputBufferLength != 0) ||
        (OutputBufferLength < sizeof(*versionInfo)))
    {
        return STATUS_INVALID_PARAMETER;
    }

    status = WdfRequestRetrieveOutputBuffer(
        Request,
        sizeof(*versionInfo),
        &outputBuffer,
        NULL);
    if (!NT_SUCCESS(status))
    {
        return STATUS_INVALID_PARAMETER;
    }

    versionInfo = (PCMON_VERSION_INFO)outputBuffer;
    versionInfo->ProtocolVersion = CMON_PROTOCOL_VERSION;
    versionInfo->HeaderSize = CMON_EVENT_HEADER_SIZE;
    versionInfo->MaxPayloadLength = CMON_MAX_PAYLOAD;
    *BytesWritten = sizeof(*versionInfo);
    return STATUS_SUCCESS;
}

static NTSTATUS
CmonGetBatch(
    _In_ WDFREQUEST Request,
    _In_ SIZE_T InputBufferLength,
    _In_ SIZE_T OutputBufferLength,
    _Inout_ PDRIVER_CONTEXT Context,
    _Out_ PULONG_PTR BytesWritten)
{
    PVOID outputBuffer;
    NTSTATUS status;

    if ((InputBufferLength != 0) ||
        (OutputBufferLength < sizeof(CMON_EVENT_HEADER)))
    {
        return STATUS_INVALID_PARAMETER;
    }

    status = WdfRequestRetrieveOutputBuffer(
        Request,
        sizeof(CMON_EVENT_HEADER),
        &outputBuffer,
        NULL);
    if (!NT_SUCCESS(status))
    {
        return STATUS_INVALID_PARAMETER;
    }

    return CmonRingPopBatch(
        Context,
        outputBuffer,
        OutputBufferLength,
        BytesWritten);
}

static NTSTATUS
CmonGetStats(
    _In_ WDFREQUEST Request,
    _In_ SIZE_T InputBufferLength,
    _In_ SIZE_T OutputBufferLength,
    _Inout_ PDRIVER_CONTEXT Context,
    _Out_ PULONG_PTR BytesWritten)
{
    PCMON_STATS_INFO stats;
    CMON_STATS_INFO snapshot;
    PVOID outputBuffer;
    NTSTATUS status;

    if ((InputBufferLength != 0) ||
        (OutputBufferLength < sizeof(*stats)))
    {
        return STATUS_INVALID_PARAMETER;
    }

    status = WdfRequestRetrieveOutputBuffer(
        Request,
        sizeof(*stats),
        &outputBuffer,
        NULL);
    if (!NT_SUCCESS(status))
    {
        return STATUS_INVALID_PARAMETER;
    }

    WdfSpinLockAcquire(Context->SpinLock);
    snapshot.Queued = Context->Ring.Count;
    snapshot.State = Context->CaptureState;
    snapshot.Dropped = Context->Ring.Dropped;
    snapshot.Sequence = Context->Ring.Sequence;
    WdfSpinLockRelease(Context->SpinLock);

    stats = (PCMON_STATS_INFO)outputBuffer;
    RtlCopyMemory(stats, &snapshot, sizeof(snapshot));

    *BytesWritten = sizeof(*stats);
    return STATUS_SUCCESS;
}

static NTSTATUS
CmonCreateControlDeviceLocked(
    _In_ WDFDRIVER Driver,
    _Inout_ PDRIVER_CONTEXT Context,
    _Out_ WDFDEVICE* PartialControlDevice)
{
    DECLARE_CONST_UNICODE_STRING(
        securityDescriptor,
        L"D:P(A;;GA;;;SY)(A;;GA;;;BA)");
    DECLARE_CONST_UNICODE_STRING(
        deviceName,
        L"\\Device\\CommMonitorFilter");
    DECLARE_CONST_UNICODE_STRING(
        symbolicLinkName,
        L"\\DosDevices\\Global\\CommMonitorFilter");
    PWDFDEVICE_INIT deviceInit;
    WDFDEVICE controlDevice;
    WDF_OBJECT_ATTRIBUTES controlAttributes;
    WDF_IO_QUEUE_CONFIG queueConfig;
    PCONTROL_DEVICE_CONTEXT controlContext;
    NTSTATUS status;

    *PartialControlDevice = NULL;
    if (Context->ControlState == CmonControlActive)
    {
        return STATUS_SUCCESS;
    }
    if (Context->ControlState == CmonControlDeleting)
    {
        return STATUS_DELETE_PENDING;
    }

    deviceInit = WdfControlDeviceInitAllocate(Driver, &securityDescriptor);
    if (deviceInit == NULL)
    {
        return STATUS_INSUFFICIENT_RESOURCES;
    }

    WdfDeviceInitSetDeviceType(deviceInit, FILE_DEVICE_UNKNOWN);
    WdfDeviceInitSetCharacteristics(deviceInit, FILE_DEVICE_SECURE_OPEN, FALSE);
    WdfDeviceInitSetExclusive(deviceInit, FALSE);

    status = WdfDeviceInitAssignName(deviceInit, &deviceName);
    if (!NT_SUCCESS(status))
    {
        WdfDeviceInitFree(deviceInit);
        return status;
    }

    WDF_OBJECT_ATTRIBUTES_INIT_CONTEXT_TYPE(
        &controlAttributes,
        CONTROL_DEVICE_CONTEXT);
    controlAttributes.EvtDestroyCallback = CmonEvtControlDeviceDestroy;
    controlAttributes.ExecutionLevel = WdfExecutionLevelPassive;
    status = WdfDeviceCreate(
        &deviceInit,
        &controlAttributes,
        &controlDevice);
    if (!NT_SUCCESS(status))
    {
        if (deviceInit != NULL)
        {
            WdfDeviceInitFree(deviceInit);
        }
        return status;
    }

    controlContext = CmonGetControlDeviceContext(controlDevice);
    controlContext->Driver = Driver;
    controlContext->Published = FALSE;

    status = WdfDeviceCreateSymbolicLink(controlDevice, &symbolicLinkName);
    if (!NT_SUCCESS(status))
    {
        *PartialControlDevice = controlDevice;
        return status;
    }

    WDF_IO_QUEUE_CONFIG_INIT_DEFAULT_QUEUE(
        &queueConfig,
        WdfIoQueueDispatchSequential);
    queueConfig.EvtIoDeviceControl = CmonEvtIoDeviceControl;
    queueConfig.PowerManaged = WdfFalse;
    status = WdfIoQueueCreate(
        controlDevice,
        &queueConfig,
        WDF_NO_OBJECT_ATTRIBUTES,
        WDF_NO_HANDLE);
    if (!NT_SUCCESS(status))
    {
        *PartialControlDevice = controlDevice;
        return status;
    }

    Context->ControlDevice = controlDevice;
    Context->ControlState = CmonControlActive;
    Context->RecreateAfterDelete = FALSE;
    controlContext->Published = TRUE;
    WdfControlFinishInitializing(controlDevice);
    return STATUS_SUCCESS;
}

NTSTATUS
CmonCreateControlDevice(
    _In_ WDFDRIVER Driver)
{
    PDRIVER_CONTEXT context;
    WDFDEVICE partialControlDevice;
    NTSTATUS status;

    context = CmonGetDriverContext(Driver);
    partialControlDevice = NULL;
    (VOID)WdfWaitLockAcquire(context->LifecycleLock, NULL);
    status = CmonCreateControlDeviceLocked(
        Driver,
        context,
        &partialControlDevice);
    WdfWaitLockRelease(context->LifecycleLock);
    if (partialControlDevice != NULL)
    {
        WdfObjectDelete(partialControlDevice);
    }
    return status;
}

VOID
CmonRegisterPnpDevice(
    _In_ WDFDEVICE Device)
{
    PDEVICE_CONTEXT deviceContext;
    PDRIVER_CONTEXT context;
    PDEVICE_CONTEXT anchorContext;
    PDEVICE_OBJECT anchorWdmDevice;
    WDFDEVICE partialControlDevice;

    deviceContext = CmonGetDeviceContext(Device);
    context = CmonGetDriverContext(deviceContext->Driver);
    anchorContext = NULL;
    anchorWdmDevice = NULL;
    partialControlDevice = NULL;

    (VOID)WdfWaitLockAcquire(context->LifecycleLock, NULL);
    if (!deviceContext->Registered)
    {
        InsertTailList(
            &context->ActivePnpList,
            &deviceContext->ActiveListEntry);
        deviceContext->Registered = TRUE;
        ++context->PnpDeviceCount;

        if (context->ControlState == CmonControlDeleting)
        {
            if (context->ControlDevice != NULL)
            {
                context->RecreateAfterDelete = TRUE;
            }
            else if (!context->RecreateWorkerQueued &&
                     ExAcquireRundownProtection(
                         &deviceContext->RecreateWorkRundown))
            {
                anchorContext = deviceContext;
                anchorWdmDevice =
                    WdfDeviceWdmGetDeviceObject(deviceContext->Device);
                context->RecreateWorkerQueued = TRUE;
            }
        }
        else if (context->ControlState == CmonControlAbsent)
        {
            (VOID)CmonCreateControlDeviceLocked(
                deviceContext->Driver,
                context,
                &partialControlDevice);
        }
    }
    WdfWaitLockRelease(context->LifecycleLock);

    if (partialControlDevice != NULL)
    {
        WdfObjectDelete(partialControlDevice);
    }
    if (anchorContext != NULL)
    {
        CmonQueueRecreateWorker(
            context,
            anchorContext,
            anchorWdmDevice);
    }
}

VOID
CmonUnregisterPnpDevice(
    _In_ WDFDEVICE Device)
{
    PDEVICE_CONTEXT deviceContext;
    PDRIVER_CONTEXT context;
    WDFDEVICE controlDevice;

    deviceContext = CmonGetDeviceContext(Device);
    context = CmonGetDriverContext(deviceContext->Driver);
    controlDevice = NULL;

    (VOID)WdfWaitLockAcquire(context->LifecycleLock, NULL);
    if (deviceContext->Registered)
    {
        RemoveEntryList(&deviceContext->ActiveListEntry);
        InitializeListHead(&deviceContext->ActiveListEntry);
        deviceContext->Registered = FALSE;
        --context->PnpDeviceCount;

        if (context->PnpDeviceCount == 0)
        {
            context->RecreateAfterDelete = FALSE;
            if ((context->ControlState == CmonControlActive) &&
                (context->ControlDevice != NULL))
            {
                context->ControlState = CmonControlDeleting;
                controlDevice = context->ControlDevice;
            }
        }
    }
    WdfWaitLockRelease(context->LifecycleLock);

    if (controlDevice != NULL)
    {
        WdfObjectDelete(controlDevice);
    }
}

_Use_decl_annotations_
VOID
CmonEvtControlDeviceDestroy(
    _In_ WDFOBJECT Object)
{
    WDFDEVICE controlDevice;
    PCONTROL_DEVICE_CONTEXT controlDeviceContext;
    PDRIVER_CONTEXT context;
    PDEVICE_CONTEXT anchorContext;
    PDEVICE_OBJECT anchorWdmDevice;

    controlDevice = (WDFDEVICE)Object;
    controlDeviceContext = CmonGetControlDeviceContext(controlDevice);
    if (!controlDeviceContext->Published)
    {
        return;
    }

    context = CmonGetDriverContext(controlDeviceContext->Driver);
    anchorContext = NULL;
    anchorWdmDevice = NULL;

    (VOID)WdfWaitLockAcquire(context->LifecycleLock, NULL);
    if ((context->ControlState == CmonControlDeleting) &&
        (context->ControlDevice == controlDevice))
    {
        context->ControlDevice = NULL;
        controlDeviceContext->Published = FALSE;

        if (context->RecreateAfterDelete &&
            (context->PnpDeviceCount != 0) &&
            !context->RecreateWorkerQueued)
        {
            anchorContext = CmonAcquireRecreateAnchorLocked(context);
            if (anchorContext != NULL)
            {
                anchorWdmDevice =
                    WdfDeviceWdmGetDeviceObject(anchorContext->Device);
                context->RecreateWorkerQueued = TRUE;
            }
        }
        context->RecreateAfterDelete = FALSE;
    }
    WdfWaitLockRelease(context->LifecycleLock);

    if (anchorContext != NULL)
    {
        CmonQueueRecreateWorker(
            context,
            anchorContext,
            anchorWdmDevice);
    }
}

_Use_decl_annotations_
VOID
CmonRecreateControlWorkItem(
    _In_ PVOID IoObject,
    _In_opt_ PVOID WorkContext,
    _In_ PIO_WORKITEM WorkItem)
{
    WDFDEVICE anchorDevice;
    PDEVICE_CONTEXT anchorContext;
    PDRIVER_CONTEXT context;
    LARGE_INTEGER retryDelay;
    ULONG attempt;

    UNREFERENCED_PARAMETER(WorkContext);

    anchorDevice = WdfWdmDeviceGetWdfDeviceHandle((PDEVICE_OBJECT)IoObject);
    anchorContext = CmonGetDeviceContext(anchorDevice);
    context = CmonGetDriverContext(anchorContext->Driver);
    retryDelay.QuadPart = CMON_RECREATE_RETRY_DELAY_100NS;

    for (attempt = 0;
         attempt <= CMON_RECREATE_COLLISION_RETRIES;
         ++attempt)
    {
        WDFDEVICE partialControlDevice;
        BOOLEAN retry;
        NTSTATUS status;

        partialControlDevice = NULL;
        retry = FALSE;
        status = STATUS_CANCELLED;

        (VOID)WdfWaitLockAcquire(context->LifecycleLock, NULL);
        if ((context->ControlState == CmonControlDeleting) &&
            (context->ControlDevice == NULL) &&
            context->RecreateWorkerQueued)
        {
            context->RecreateAfterDelete = FALSE;
            if (context->PnpDeviceCount == 0)
            {
                context->RecreateWorkerQueued = FALSE;
            }
            else
            {
                context->ControlState = CmonControlAbsent;
                status = CmonCreateControlDeviceLocked(
                    anchorContext->Driver,
                    context,
                    &partialControlDevice);
                if (NT_SUCCESS(status))
                {
                    context->RecreateWorkerQueued = FALSE;
                }
                else if (status == STATUS_OBJECT_NAME_COLLISION)
                {
                    if (attempt < CMON_RECREATE_COLLISION_RETRIES)
                    {
                        context->ControlState = CmonControlDeleting;
                        retry = TRUE;
                    }
                    else
                    {
                        context->ControlState = CmonControlDeleting;
                        context->RecreateWorkerQueued = FALSE;
                    }
                }
                else
                {
                    context->ControlState = CmonControlDeleting;
                    context->RecreateWorkerQueued = FALSE;
                }
            }
        }
        else
        {
            context->RecreateWorkerQueued = FALSE;
        }
        WdfWaitLockRelease(context->LifecycleLock);

        if (partialControlDevice != NULL)
        {
            WdfObjectDelete(partialControlDevice);
        }
        if (!retry)
        {
            break;
        }

        (VOID)KeDelayExecutionThread(
            KernelMode,
            FALSE,
            &retryDelay);
    }

    IoFreeWorkItem(WorkItem);
    ExReleaseRundownProtection(&anchorContext->RecreateWorkRundown);
}

VOID
CmonEvtIoDeviceControl(
    _In_ WDFQUEUE Queue,
    _In_ WDFREQUEST Request,
    _In_ SIZE_T OutputBufferLength,
    _In_ SIZE_T InputBufferLength,
    _In_ ULONG IoControlCode)
{
    WDFDEVICE controlDevice;
    WDFDRIVER driver;
    PDRIVER_CONTEXT context;
    ULONG_PTR bytesWritten;
    NTSTATUS status;

    controlDevice = WdfIoQueueGetDevice(Queue);
    driver = WdfDeviceGetDriver(controlDevice);
    context = CmonGetDriverContext(driver);
    bytesWritten = 0;

    switch (IoControlCode)
    {
    case IOCTL_CMON_GET_VERSION:
        status = CmonGetVersion(
            Request,
            InputBufferLength,
            OutputBufferLength,
            &bytesWritten);
        break;

    case IOCTL_CMON_SET_CONFIG:
        status = CmonSetConfig(
            Request,
            InputBufferLength,
            OutputBufferLength,
            context);
        break;

    case IOCTL_CMON_GET_BATCH:
        status = CmonGetBatch(
            Request,
            InputBufferLength,
            OutputBufferLength,
            context,
            &bytesWritten);
        break;

    case IOCTL_CMON_GET_STATS:
        status = CmonGetStats(
            Request,
            InputBufferLength,
            OutputBufferLength,
            context,
            &bytesWritten);
        break;

    default:
        status = STATUS_INVALID_PARAMETER;
        break;
    }

    WdfRequestCompleteWithInformation(Request, status, bytesWritten);
}
