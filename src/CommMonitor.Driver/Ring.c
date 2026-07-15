#include "Driver.h"

NTSTATUS
CmonRingPush(
    _Inout_ PDRIVER_CONTEXT Context,
    _In_ const CMON_EVENT_SLOT* Event)
{
    CMON_RING_PUSH_RESULT result;

    if ((Event == NULL) ||
        (Event->Header.PayloadLength > CMON_MAX_PAYLOAD))
    {
        return STATUS_INVALID_PARAMETER;
    }

    WdfSpinLockAcquire(Context->SpinLock);
    result = CmonRingCorePush(&Context->Ring, Event);
    WdfSpinLockRelease(Context->SpinLock);

    switch (result)
    {
    case CmonRingPushStored:
        return STATUS_SUCCESS;
    case CmonRingPushFull:
        return STATUS_BUFFER_OVERFLOW;
    default:
        return STATUS_INVALID_PARAMETER;
    }
}

NTSTATUS
CmonRingPopBatch(
    _Inout_ PDRIVER_CONTEXT Context,
    _Out_writes_bytes_to_(OutputBufferLength, *BytesWritten) PVOID OutputBuffer,
    _In_ SIZE_T OutputBufferLength,
    _Out_ PULONG_PTR BytesWritten)
{
    PUCHAR output;

    if ((OutputBuffer == NULL) ||
        (BytesWritten == NULL) ||
        (OutputBufferLength < sizeof(CMON_EVENT_HEADER)))
    {
        return STATUS_INVALID_PARAMETER;
    }

    output = (PUCHAR)OutputBuffer;
    *BytesWritten = 0;

    for (;;)
    {
        CMON_RING_POP_RESULT result;
        SIZE_T eventBytes;
        SIZE_T remaining;

        remaining = OutputBufferLength - *BytesWritten;
        WdfSpinLockAcquire(Context->SpinLock);
        result = CmonRingCorePopOne(
            &Context->Ring,
            output + *BytesWritten,
            remaining,
            *BytesWritten != 0,
            &eventBytes);
        WdfSpinLockRelease(Context->SpinLock);

        switch (result)
        {
        case CmonRingPopCopied:
            *BytesWritten += eventBytes;
            break;
        case CmonRingPopEmpty:
        case CmonRingPopBatchComplete:
            return STATUS_SUCCESS;
        case CmonRingPopFirstTooSmall:
            return STATUS_BUFFER_TOO_SMALL;
        default:
            return STATUS_INVALID_PARAMETER;
        }
    }
}
