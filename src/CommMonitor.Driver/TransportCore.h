#pragma once

#include "Protocol.h"

#define CMON_CONFIG_PREFIX_SIZE 8u

#if defined(__cplusplus)
extern "C" {
#endif

typedef enum _CMON_RING_PUSH_RESULT
{
    CmonRingPushStored = 0,
    CmonRingPushInvalidPayload = 1,
    CmonRingPushFull = 2,
    CmonRingPushInvalidArgument = 3,
} CMON_RING_PUSH_RESULT;

typedef enum _CMON_RING_POP_RESULT
{
    CmonRingPopCopied = 0,
    CmonRingPopEmpty = 1,
    CmonRingPopFirstTooSmall = 2,
    CmonRingPopBatchComplete = 3,
    CmonRingPopInvalidArgument = 4,
} CMON_RING_POP_RESULT;

typedef struct _CMON_RING_CORE
{
    PCMON_EVENT_SLOT Slots;
    uint32_t Capacity;
    uint32_t Head;
    uint32_t Tail;
    uint32_t Count;
    uint64_t Dropped;
    uint64_t Sequence;
} CMON_RING_CORE, *PCMON_RING_CORE;

void
CmonRingCoreInitialize(
    _Out_ PCMON_RING_CORE State,
    _Inout_updates_(Capacity) PCMON_EVENT_SLOT Slots,
    _In_ uint32_t Capacity);

CMON_RING_PUSH_RESULT
CmonRingCorePush(
    _Inout_ PCMON_RING_CORE State,
    _In_ const CMON_EVENT_SLOT* Event);

CMON_RING_POP_RESULT
CmonRingCorePopOne(
    _Inout_ PCMON_RING_CORE State,
    _Out_writes_bytes_to_(OutputBufferLength, *EventBytes) void* OutputBuffer,
    _In_ SIZE_T OutputBufferLength,
    _In_ BOOLEAN BatchAlreadyContainsEvent,
    _Out_ SIZE_T* EventBytes);

BOOLEAN
CmonConfigBytesAreValid(
    _In_reads_bytes_(InputBufferLength) const uint8_t* InputBuffer,
    _In_ SIZE_T InputBufferLength,
    _Out_opt_ uint32_t* State,
    _Out_opt_ uint32_t* DeviceCount);

uint64_t
CmonConfigReadDeviceHash(
    _In_ const uint8_t* InputBuffer,
    _In_ uint32_t Index);

#if defined(__cplusplus)
}
#endif
