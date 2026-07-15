#pragma once

#include "Protocol.h"

#if defined(__cplusplus)
extern "C" {
#endif

typedef enum _CMON_CAPTURE_DIRECTION
{
    CmonCaptureDirectionNone = 0,
    CmonCaptureDirectionInput = 1,
    CmonCaptureDirectionOutput = 2,
} CMON_CAPTURE_DIRECTION;

typedef struct _CMON_CAPTURE_PAYLOAD_PLAN
{
    uint32_t PayloadLength;
    uint32_t Flags;
} CMON_CAPTURE_PAYLOAD_PLAN, *PCMON_CAPTURE_PAYLOAD_PLAN;

typedef struct _CMON_CAPTURE_METADATA
{
    int64_t QpcTicks;
    uint64_t DeviceId;
    uint32_t ProcessId;
    uint32_t Kind;
    uint32_t IoctlCode;
    uint32_t RequestedLength;
} CMON_CAPTURE_METADATA, *PCMON_CAPTURE_METADATA;

uint64_t
CmonHashDeviceIdUtf16(
    _In_reads_opt_(CodeUnitCount) const uint16_t* CodeUnits,
    _In_ SIZE_T CodeUnitCount);

BOOLEAN
CmonCaptureLengthIsRepresentable(
    _In_ SIZE_T Length);

BOOLEAN
CmonCaptureCopyPayload(
    _Out_writes_bytes_(DestinationCapacity) uint8_t* Destination,
    _In_ uint32_t DestinationCapacity,
    _In_reads_bytes_opt_(PayloadLength) const uint8_t* Source,
    _In_ uint32_t PayloadLength);

BOOLEAN
CmonCaptureDeviceIsSelected(
    _In_ uint32_t CaptureState,
    _In_ uint64_t DeviceId,
    _In_reads_opt_(SelectedDeviceCount) const uint64_t* SelectedDeviceHashes,
    _In_ uint32_t SelectedDeviceCount);

CMON_CAPTURE_DIRECTION
CmonSerialIoctlDirection(
    _In_ uint32_t IoctlCode);

CMON_CAPTURE_PAYLOAD_PLAN
CmonCapturePlanPayload(
    _In_ CMON_CAPTURE_DIRECTION Direction,
    _In_ uint32_t RequestedLength,
    _In_ uint32_t CompletedLength,
    _In_ uint32_t AvailableLength,
    _In_ BOOLEAN LowerSucceeded);

void
CmonCaptureInitializeEvent(
    _Out_ PCMON_EVENT_SLOT Event,
    _In_ const CMON_CAPTURE_METADATA* Metadata,
    _In_ int32_t LowerStatus,
    _In_ uint32_t CompletedLength,
    _In_ uint32_t PayloadLength,
    _In_ uint32_t Flags);

#if defined(__cplusplus)
}
#endif
