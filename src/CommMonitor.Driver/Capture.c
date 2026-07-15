#include "Driver.h"

static VOID
CmonResetRequestContext(
    _Inout_ PREQUEST_CONTEXT Context)
{
    WDFMEMORY eventMemory;

    eventMemory = Context->EventMemory;
    Context->EventMemory = NULL;
    if (eventMemory != NULL)
    {
        WdfObjectDelete(eventMemory);
    }

    RtlZeroMemory(Context, sizeof(*Context));
}

static PREQUEST_CONTEXT
CmonAcquireRequestContext(
    _In_ WDFREQUEST Request)
{
    WDF_OBJECT_ATTRIBUTES attributes;
    PREQUEST_CONTEXT requestContext;
    NTSTATUS status;

    requestContext = NULL;
    WDF_OBJECT_ATTRIBUTES_INIT_CONTEXT_TYPE(
        &attributes,
        REQUEST_CONTEXT);
    status = WdfObjectAllocateContext(
        Request,
        &attributes,
        (PVOID*)&requestContext);
    if ((status != STATUS_OBJECT_NAME_EXISTS) &&
        !NT_SUCCESS(status))
    {
        return NULL;
    }
    if (requestContext == NULL)
    {
        return NULL;
    }

    CmonResetRequestContext(requestContext);
    return requestContext;
}

static BOOLEAN
CmonDeviceCaptureIsEnabled(
    _In_ PDEVICE_CONTEXT DeviceContext)
{
    PDRIVER_CONTEXT driverContext;
    BOOLEAN selected;

    driverContext = CmonGetDriverContext(DeviceContext->Driver);
    WdfSpinLockAcquire(driverContext->SpinLock);
    selected = CmonCaptureDeviceIsSelected(
        driverContext->CaptureState,
        DeviceContext->DeviceIdHash,
        driverContext->SelectedDeviceHashes,
        driverContext->SelectedDeviceCount);
    WdfSpinLockRelease(driverContext->SpinLock);

    return selected;
}

static BOOLEAN
CmonTrySendCapturedRequest(
    _In_ WDFQUEUE Queue,
    _In_ WDFREQUEST Request,
    _In_ ULONG Kind,
    _In_ ULONG IoctlCode,
    _In_ SIZE_T RequestedLength,
    _In_ CMON_CAPTURE_DIRECTION Direction)
{
    WDFDEVICE device;
    PDEVICE_CONTEXT deviceContext;
    PREQUEST_CONTEXT requestContext;
    WDF_OBJECT_ATTRIBUTES memoryAttributes;
    PCMON_EVENT_SLOT event;
    PVOID inputBuffer;
    SIZE_T inputBufferLength;
    ULONG availableLength;
    CMON_CAPTURE_PAYLOAD_PLAN payloadPlan;
    NTSTATUS status;

    if (!CmonCaptureLengthIsRepresentable(RequestedLength))
    {
        return FALSE;
    }

    device = WdfIoQueueGetDevice(Queue);
    deviceContext = CmonGetDeviceContext(device);
    if (!CmonDeviceCaptureIsEnabled(deviceContext))
    {
        return FALSE;
    }

    requestContext = CmonAcquireRequestContext(Request);
    if (requestContext == NULL)
    {
        return FALSE;
    }

    WDF_OBJECT_ATTRIBUTES_INIT(&memoryAttributes);
    memoryAttributes.ParentObject = Request;
    status = WdfMemoryCreate(
        &memoryAttributes,
        NonPagedPoolNx,
        CMON_POOL_TAG,
        sizeof(CMON_EVENT_SLOT),
        &requestContext->EventMemory,
        (PVOID*)&event);
    if (!NT_SUCCESS(status))
    {
        CmonResetRequestContext(requestContext);
        return FALSE;
    }

    requestContext->Device = device;
    requestContext->Direction = Direction;
    requestContext->Metadata.QpcTicks =
        KeQueryPerformanceCounter(NULL).QuadPart;
    requestContext->Metadata.DeviceId = deviceContext->DeviceIdHash;
    requestContext->Metadata.ProcessId =
        IoGetRequestorProcessId(WdfRequestWdmGetIrp(Request));
    requestContext->Metadata.Kind = Kind;
    requestContext->Metadata.IoctlCode = IoctlCode;
    requestContext->Metadata.RequestedLength = (ULONG)RequestedLength;

    if (Direction == CmonCaptureDirectionInput)
    {
        inputBuffer = NULL;
        inputBufferLength = 0;
        if (RequestedLength != 0)
        {
            status = WdfRequestRetrieveInputBuffer(
                Request,
                1,
                &inputBuffer,
                &inputBufferLength);
            if (!NT_SUCCESS(status))
            {
                CmonResetRequestContext(requestContext);
                return FALSE;
            }
        }

        availableLength = CmonCaptureLengthIsRepresentable(inputBufferLength)
            ? (ULONG)inputBufferLength
            : MAXULONG;
        payloadPlan = CmonCapturePlanPayload(
            Direction,
            (ULONG)RequestedLength,
            0,
            availableLength,
            TRUE);
        requestContext->SnapshotLength = payloadPlan.PayloadLength;
        requestContext->SnapshotFlags = payloadPlan.Flags;
        if (!CmonCaptureCopyPayload(
                event->Payload,
                CMON_MAX_PAYLOAD,
                (const uint8_t*)inputBuffer,
                payloadPlan.PayloadLength))
        {
            CmonResetRequestContext(requestContext);
            return FALSE;
        }
    }

    WdfRequestFormatRequestUsingCurrentType(Request);
    WdfRequestSetCompletionRoutine(
        Request,
        CmonEvtCaptureRequestCompletion,
        requestContext);
    if (WdfRequestSend(
            Request,
            WdfDeviceGetIoTarget(device),
            WDF_NO_SEND_OPTIONS))
    {
        return TRUE;
    }

    status = WdfRequestGetStatus(Request);
    CmonResetRequestContext(requestContext);
    WdfRequestComplete(Request, status);
    return TRUE;
}

VOID
CmonEvtIoRead(
    _In_ WDFQUEUE Queue,
    _In_ WDFREQUEST Request,
    _In_ SIZE_T Length)
{
    if (!CmonTrySendCapturedRequest(
            Queue,
            Request,
            CMON_EVENT_READ,
            0,
            Length,
            CmonCaptureDirectionOutput))
    {
        CommMonitorEvtIoDefault(Queue, Request);
    }
}

VOID
CmonEvtIoWrite(
    _In_ WDFQUEUE Queue,
    _In_ WDFREQUEST Request,
    _In_ SIZE_T Length)
{
    if (!CmonTrySendCapturedRequest(
            Queue,
            Request,
            CMON_EVENT_WRITE,
            0,
            Length,
            CmonCaptureDirectionInput))
    {
        CommMonitorEvtIoDefault(Queue, Request);
    }
}

VOID
CmonEvtIoSerialDeviceControl(
    _In_ WDFQUEUE Queue,
    _In_ WDFREQUEST Request,
    _In_ SIZE_T OutputBufferLength,
    _In_ SIZE_T InputBufferLength,
    _In_ ULONG IoControlCode)
{
    CMON_CAPTURE_DIRECTION direction;
    SIZE_T requestedLength;

    direction = CmonSerialIoctlDirection(IoControlCode);
    if (direction == CmonCaptureDirectionInput)
    {
        requestedLength = InputBufferLength;
    }
    else if (direction == CmonCaptureDirectionOutput)
    {
        requestedLength = OutputBufferLength;
    }
    else
    {
        CommMonitorEvtIoDefault(Queue, Request);
        return;
    }

    if (!CmonTrySendCapturedRequest(
            Queue,
            Request,
            CMON_EVENT_IOCTL,
            IoControlCode,
            requestedLength,
            direction))
    {
        CommMonitorEvtIoDefault(Queue, Request);
    }
}

VOID
CmonEvtCaptureRequestCompletion(
    _In_ WDFREQUEST Request,
    _In_ WDFIOTARGET Target,
    _In_ PWDF_REQUEST_COMPLETION_PARAMS Params,
    _In_ WDFCONTEXT Context)
{
    PREQUEST_CONTEXT requestContext;
    WDFMEMORY eventMemory;
    WDFDEVICE device;
    CMON_CAPTURE_METADATA metadata;
    CMON_CAPTURE_DIRECTION direction;
    ULONG snapshotLength;
    ULONG snapshotFlags;
    NTSTATUS lowerStatus;
    ULONG_PTR lowerInformation;
    BOOLEAN emitEvent;

    UNREFERENCED_PARAMETER(Target);

    requestContext = (PREQUEST_CONTEXT)Context;
    eventMemory = requestContext->EventMemory;
    device = requestContext->Device;
    metadata = requestContext->Metadata;
    direction = requestContext->Direction;
    snapshotLength = requestContext->SnapshotLength;
    snapshotFlags = requestContext->SnapshotFlags;
    lowerStatus = Params->IoStatus.Status;
    lowerInformation = Params->IoStatus.Information;
    emitEvent = eventMemory != NULL &&
        CmonCaptureLengthIsRepresentable(lowerInformation);

    if (emitEvent)
    {
        PCMON_EVENT_SLOT event;
        SIZE_T eventMemoryLength;
        CMON_CAPTURE_PAYLOAD_PLAN payloadPlan;

        payloadPlan.PayloadLength = 0;
        payloadPlan.Flags = CMON_FLAG_NONE;
        event = (PCMON_EVENT_SLOT)WdfMemoryGetBuffer(
            eventMemory,
            &eventMemoryLength);
        if ((event == NULL) ||
            (eventMemoryLength < sizeof(CMON_EVENT_SLOT)))
        {
            emitEvent = FALSE;
        }
        else if (direction == CmonCaptureDirectionInput)
        {
            payloadPlan.PayloadLength = snapshotLength;
            payloadPlan.Flags = snapshotFlags;
        }
        else
        {
            PVOID outputBuffer;
            SIZE_T outputBufferLength;
            ULONG availableLength;
            NTSTATUS bufferStatus;

            outputBuffer = NULL;
            outputBufferLength = 0;
            if (NT_SUCCESS(lowerStatus) &&
                (lowerInformation != 0) &&
                (metadata.RequestedLength != 0))
            {
                bufferStatus = WdfRequestRetrieveOutputBuffer(
                    Request,
                    1,
                    &outputBuffer,
                    &outputBufferLength);
                if (!NT_SUCCESS(bufferStatus))
                {
                    emitEvent = FALSE;
                }
            }

            availableLength =
                CmonCaptureLengthIsRepresentable(outputBufferLength)
                    ? (ULONG)outputBufferLength
                    : MAXULONG;
            payloadPlan = CmonCapturePlanPayload(
                direction,
                metadata.RequestedLength,
                (ULONG)lowerInformation,
                availableLength,
                NT_SUCCESS(lowerStatus));
            if (emitEvent &&
                !CmonCaptureCopyPayload(
                    event->Payload,
                    CMON_MAX_PAYLOAD,
                    (const uint8_t*)outputBuffer,
                    payloadPlan.PayloadLength))
            {
                emitEvent = FALSE;
            }
        }

        if (emitEvent)
        {
            PDEVICE_CONTEXT deviceContext;
            PDRIVER_CONTEXT driverContext;

            CmonCaptureInitializeEvent(
                event,
                &metadata,
                lowerStatus,
                (ULONG)lowerInformation,
                payloadPlan.PayloadLength,
                payloadPlan.Flags);
            deviceContext = CmonGetDeviceContext(device);
            driverContext = CmonGetDriverContext(deviceContext->Driver);
            (VOID)CmonRingPush(driverContext, event);
        }
    }

    CmonResetRequestContext(requestContext);
    WdfRequestCompleteWithInformation(
        Request,
        lowerStatus,
        lowerInformation);
}
