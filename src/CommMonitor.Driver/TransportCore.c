#include "TransportCore.h"

#if defined(_KERNEL_MODE)
#define CmonCopyMemory RtlCopyMemory
#else
#include <string.h>
#define CmonCopyMemory memcpy
#endif

static uint32_t
CmonReadUint32(
    _In_reads_bytes_(sizeof(uint32_t)) const uint8_t* Buffer)
{
    uint32_t value;

    CmonCopyMemory(&value, Buffer, sizeof(value));
    return value;
}

static uint64_t
CmonReadUint64(
    _In_reads_bytes_(sizeof(uint64_t)) const uint8_t* Buffer)
{
    uint64_t value;

    CmonCopyMemory(&value, Buffer, sizeof(value));
    return value;
}

void
CmonRingCoreInitialize(
    _Out_ PCMON_RING_CORE State,
    _Inout_updates_(Capacity) PCMON_EVENT_SLOT Slots,
    _In_ uint32_t Capacity)
{
    State->Slots = Slots;
    State->Capacity = Capacity;
    State->Head = 0;
    State->Tail = 0;
    State->Count = 0;
    State->Dropped = 0;
    State->Sequence = 0;
}

CMON_RING_PUSH_RESULT
CmonRingCorePush(
    _Inout_ PCMON_RING_CORE State,
    _In_ const CMON_EVENT_SLOT* Event)
{
    PCMON_EVENT_SLOT destination;
    uint32_t payloadLength;

    if ((State == NULL) || (Event == NULL) ||
        (State->Slots == NULL) || (State->Capacity == 0))
    {
        return CmonRingPushInvalidArgument;
    }

    payloadLength = Event->Header.PayloadLength;
    if (payloadLength > CMON_MAX_PAYLOAD)
    {
        return CmonRingPushInvalidPayload;
    }

    ++State->Sequence;
    if (State->Count == State->Capacity)
    {
        ++State->Dropped;
        return CmonRingPushFull;
    }

    destination = &State->Slots[State->Tail];
    CmonCopyMemory(
        &destination->Header,
        &Event->Header,
        sizeof(destination->Header));
    destination->Header.Magic = CMON_MAGIC;
    destination->Header.Version = CMON_PROTOCOL_VERSION;
    destination->Header.HeaderSize = CMON_EVENT_HEADER_SIZE;
    destination->Header.TotalSize = CMON_EVENT_HEADER_SIZE + payloadLength;
    destination->Header.Sequence = State->Sequence;
    if (payloadLength != 0)
    {
        CmonCopyMemory(destination->Payload, Event->Payload, payloadLength);
    }

    State->Tail = (State->Tail + 1u) % State->Capacity;
    ++State->Count;
    return CmonRingPushStored;
}

CMON_RING_POP_RESULT
CmonRingCorePopOne(
    _Inout_ PCMON_RING_CORE State,
    _Out_writes_bytes_to_(OutputBufferLength, *EventBytes) void* OutputBuffer,
    _In_ SIZE_T OutputBufferLength,
    _In_ BOOLEAN BatchAlreadyContainsEvent,
    _Out_ SIZE_T* EventBytes)
{
    PCMON_EVENT_SLOT event;
    uint8_t* output;
    SIZE_T wireLength;

    if (EventBytes == NULL)
    {
        return CmonRingPopInvalidArgument;
    }
    *EventBytes = 0;

    if ((State == NULL) ||
        (State->Slots == NULL) || (State->Capacity == 0))
    {
        return CmonRingPopInvalidArgument;
    }

    if (State->Count == 0)
    {
        return CmonRingPopEmpty;
    }

    event = &State->Slots[State->Head];
    if (event->Header.PayloadLength > CMON_MAX_PAYLOAD)
    {
        return CmonRingPopInvalidArgument;
    }

    wireLength = sizeof(CMON_EVENT_HEADER) + event->Header.PayloadLength;
    if (wireLength > OutputBufferLength)
    {
        return BatchAlreadyContainsEvent
            ? CmonRingPopBatchComplete
            : CmonRingPopFirstTooSmall;
    }
    if (OutputBuffer == NULL)
    {
        return CmonRingPopInvalidArgument;
    }

    output = (uint8_t*)OutputBuffer;
    CmonCopyMemory(output, &event->Header, sizeof(event->Header));
    if (event->Header.PayloadLength != 0)
    {
        CmonCopyMemory(
            output + sizeof(event->Header),
            event->Payload,
            event->Header.PayloadLength);
    }

    State->Head = (State->Head + 1u) % State->Capacity;
    --State->Count;
    *EventBytes = wireLength;
    return CmonRingPopCopied;
}

BOOLEAN
CmonConfigBytesAreValid(
    _In_reads_bytes_(InputBufferLength) const uint8_t* InputBuffer,
    _In_ SIZE_T InputBufferLength,
    _Out_opt_ uint32_t* State,
    _Out_opt_ uint32_t* DeviceCount)
{
    uint32_t state;
    uint32_t deviceCount;
    uint32_t firstIndex;
    uint32_t secondIndex;
    SIZE_T expectedLength;

    if (State != NULL)
    {
        *State = 0;
    }
    if (DeviceCount != NULL)
    {
        *DeviceCount = 0;
    }

    if ((InputBuffer == NULL) ||
        (InputBufferLength < CMON_CONFIG_PREFIX_SIZE))
    {
        return FALSE;
    }

    state = CmonReadUint32(InputBuffer);
    deviceCount = CmonReadUint32(InputBuffer + sizeof(state));
    if ((state != CMON_STATE_STOPPED) &&
        (state != CMON_STATE_RUNNING) &&
        (state != CMON_STATE_PAUSED))
    {
        return FALSE;
    }
    if ((deviceCount > CMON_MAX_SELECTED_DEVICES) ||
        ((state != CMON_STATE_STOPPED) && (deviceCount == 0)))
    {
        return FALSE;
    }

    expectedLength = CMON_CONFIG_PREFIX_SIZE +
        ((SIZE_T)deviceCount * sizeof(uint64_t));
    if (InputBufferLength != expectedLength)
    {
        return FALSE;
    }

    for (firstIndex = 0; firstIndex < deviceCount; ++firstIndex)
    {
        const uint64_t firstHash =
            CmonConfigReadDeviceHash(InputBuffer, firstIndex);
        if (firstHash == 0)
        {
            return FALSE;
        }

        for (secondIndex = firstIndex + 1;
             secondIndex < deviceCount;
             ++secondIndex)
        {
            if (firstHash ==
                CmonConfigReadDeviceHash(InputBuffer, secondIndex))
            {
                return FALSE;
            }
        }
    }

    if (State != NULL)
    {
        *State = state;
    }
    if (DeviceCount != NULL)
    {
        *DeviceCount = deviceCount;
    }
    return TRUE;
}

uint64_t
CmonConfigReadDeviceHash(
    _In_ const uint8_t* InputBuffer,
    _In_ uint32_t Index)
{
    return CmonReadUint64(
        InputBuffer + CMON_CONFIG_PREFIX_SIZE +
        ((SIZE_T)Index * sizeof(uint64_t)));
}
