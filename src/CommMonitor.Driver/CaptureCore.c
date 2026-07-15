#include "CaptureCore.h"

#if defined(_KERNEL_MODE)
#include <ntddser.h>
#else
#define IOCTL_SERIAL_SET_BAUD_RATE CTL_CODE(FILE_DEVICE_SERIAL_PORT, 1, METHOD_BUFFERED, FILE_ANY_ACCESS)
#define IOCTL_SERIAL_SET_LINE_CONTROL CTL_CODE(FILE_DEVICE_SERIAL_PORT, 3, METHOD_BUFFERED, FILE_ANY_ACCESS)
#define IOCTL_SERIAL_SET_TIMEOUTS CTL_CODE(FILE_DEVICE_SERIAL_PORT, 7, METHOD_BUFFERED, FILE_ANY_ACCESS)
#define IOCTL_SERIAL_GET_TIMEOUTS CTL_CODE(FILE_DEVICE_SERIAL_PORT, 8, METHOD_BUFFERED, FILE_ANY_ACCESS)
#define IOCTL_SERIAL_SET_DTR CTL_CODE(FILE_DEVICE_SERIAL_PORT, 9, METHOD_BUFFERED, FILE_ANY_ACCESS)
#define IOCTL_SERIAL_CLR_DTR CTL_CODE(FILE_DEVICE_SERIAL_PORT, 10, METHOD_BUFFERED, FILE_ANY_ACCESS)
#define IOCTL_SERIAL_SET_RTS CTL_CODE(FILE_DEVICE_SERIAL_PORT, 12, METHOD_BUFFERED, FILE_ANY_ACCESS)
#define IOCTL_SERIAL_CLR_RTS CTL_CODE(FILE_DEVICE_SERIAL_PORT, 13, METHOD_BUFFERED, FILE_ANY_ACCESS)
#define IOCTL_SERIAL_PURGE CTL_CODE(FILE_DEVICE_SERIAL_PORT, 19, METHOD_BUFFERED, FILE_ANY_ACCESS)
#define IOCTL_SERIAL_GET_BAUD_RATE CTL_CODE(FILE_DEVICE_SERIAL_PORT, 20, METHOD_BUFFERED, FILE_ANY_ACCESS)
#define IOCTL_SERIAL_GET_LINE_CONTROL CTL_CODE(FILE_DEVICE_SERIAL_PORT, 21, METHOD_BUFFERED, FILE_ANY_ACCESS)
#define IOCTL_SERIAL_GET_CHARS CTL_CODE(FILE_DEVICE_SERIAL_PORT, 22, METHOD_BUFFERED, FILE_ANY_ACCESS)
#define IOCTL_SERIAL_SET_CHARS CTL_CODE(FILE_DEVICE_SERIAL_PORT, 23, METHOD_BUFFERED, FILE_ANY_ACCESS)
#define IOCTL_SERIAL_GET_HANDFLOW CTL_CODE(FILE_DEVICE_SERIAL_PORT, 24, METHOD_BUFFERED, FILE_ANY_ACCESS)
#define IOCTL_SERIAL_SET_HANDFLOW CTL_CODE(FILE_DEVICE_SERIAL_PORT, 25, METHOD_BUFFERED, FILE_ANY_ACCESS)
#define IOCTL_SERIAL_GET_DTRRTS CTL_CODE(FILE_DEVICE_SERIAL_PORT, 30, METHOD_BUFFERED, FILE_ANY_ACCESS)
#endif

#if defined(_KERNEL_MODE)
#define CmonZeroMemory RtlZeroMemory
#define CmonCopyMemory RtlCopyMemory
#else
#include <string.h>
#define CmonZeroMemory(Destination, Length) memset((Destination), 0, (Length))
#define CmonCopyMemory memcpy
#endif

#define CMON_FNV1A_OFFSET ((uint64_t)14695981039346656037ULL)
#define CMON_FNV1A_PRIME ((uint64_t)1099511628211ULL)

static uint16_t
CmonUppercaseCodeUnit(
    _In_ uint16_t CodeUnit)
{
#if defined(_KERNEL_MODE)
    return (uint16_t)RtlUpcaseUnicodeChar((WCHAR)CodeUnit);
#else
    if ((CodeUnit >= (uint16_t)'a') &&
        (CodeUnit <= (uint16_t)'z'))
    {
        return (uint16_t)(CodeUnit - ((uint16_t)'a' - (uint16_t)'A'));
    }
    return CodeUnit;
#endif
}

static uint32_t
CmonMinimumUint32(
    _In_ uint32_t Left,
    _In_ uint32_t Right)
{
    return Left < Right ? Left : Right;
}

uint64_t
CmonHashDeviceIdUtf16(
    _In_reads_opt_(CodeUnitCount) const uint16_t* CodeUnits,
    _In_ SIZE_T CodeUnitCount)
{
    uint64_t hash;
    SIZE_T index;

    if ((CodeUnits == NULL) && (CodeUnitCount != 0))
    {
        return 0;
    }

    hash = CMON_FNV1A_OFFSET;
    for (index = 0; index < CodeUnitCount; ++index)
    {
        const uint16_t codeUnit = CmonUppercaseCodeUnit(CodeUnits[index]);

        hash ^= (uint8_t)(codeUnit & 0x00FFu);
        hash *= CMON_FNV1A_PRIME;
        hash ^= (uint8_t)(codeUnit >> 8);
        hash *= CMON_FNV1A_PRIME;
    }

    return hash;
}

BOOLEAN
CmonCaptureLengthIsRepresentable(
    _In_ SIZE_T Length)
{
    return Length <= (SIZE_T)0xFFFFFFFFu ? TRUE : FALSE;
}

BOOLEAN
CmonCaptureCopyPayload(
    _Out_writes_bytes_(DestinationCapacity) uint8_t* Destination,
    _In_ uint32_t DestinationCapacity,
    _In_reads_bytes_opt_(PayloadLength) const uint8_t* Source,
    _In_ uint32_t PayloadLength)
{
    if (PayloadLength == 0)
    {
        return TRUE;
    }
    if ((Destination == NULL) ||
        (Source == NULL) ||
        (PayloadLength > DestinationCapacity))
    {
        return FALSE;
    }

    CmonCopyMemory(Destination, Source, PayloadLength);
    return TRUE;
}

BOOLEAN
CmonCaptureDeviceIsSelected(
    _In_ uint32_t CaptureState,
    _In_ uint64_t DeviceId,
    _In_reads_opt_(SelectedDeviceCount) const uint64_t* SelectedDeviceHashes,
    _In_ uint32_t SelectedDeviceCount)
{
    uint32_t index;

    if ((CaptureState != CMON_STATE_RUNNING) ||
        (DeviceId == 0) ||
        (SelectedDeviceCount == 0) ||
        (SelectedDeviceCount > CMON_MAX_SELECTED_DEVICES) ||
        (SelectedDeviceHashes == NULL))
    {
        return FALSE;
    }

    for (index = 0; index < SelectedDeviceCount; ++index)
    {
        if (SelectedDeviceHashes[index] == DeviceId)
        {
            return TRUE;
        }
    }

    return FALSE;
}

CMON_CAPTURE_DIRECTION
CmonSerialIoctlDirection(
    _In_ uint32_t IoctlCode)
{
    switch (IoctlCode)
    {
    case IOCTL_SERIAL_SET_BAUD_RATE:
    case IOCTL_SERIAL_SET_LINE_CONTROL:
    case IOCTL_SERIAL_SET_HANDFLOW:
    case IOCTL_SERIAL_SET_TIMEOUTS:
    case IOCTL_SERIAL_SET_CHARS:
    case IOCTL_SERIAL_SET_DTR:
    case IOCTL_SERIAL_CLR_DTR:
    case IOCTL_SERIAL_SET_RTS:
    case IOCTL_SERIAL_CLR_RTS:
    case IOCTL_SERIAL_PURGE:
        return CmonCaptureDirectionInput;

    case IOCTL_SERIAL_GET_BAUD_RATE:
    case IOCTL_SERIAL_GET_LINE_CONTROL:
    case IOCTL_SERIAL_GET_HANDFLOW:
    case IOCTL_SERIAL_GET_TIMEOUTS:
    case IOCTL_SERIAL_GET_CHARS:
    case IOCTL_SERIAL_GET_DTRRTS:
        return CmonCaptureDirectionOutput;

    default:
        return CmonCaptureDirectionNone;
    }
}

CMON_CAPTURE_PAYLOAD_PLAN
CmonCapturePlanPayload(
    _In_ CMON_CAPTURE_DIRECTION Direction,
    _In_ uint32_t RequestedLength,
    _In_ uint32_t CompletedLength,
    _In_ uint32_t AvailableLength,
    _In_ BOOLEAN LowerSucceeded)
{
    CMON_CAPTURE_PAYLOAD_PLAN plan;
    uint32_t relevantLength;

    plan.PayloadLength = 0;
    plan.Flags = CMON_FLAG_NONE;
    relevantLength = 0;

    if (Direction == CmonCaptureDirectionInput)
    {
        plan.Flags = CMON_FLAG_INPUT_PAYLOAD;
        relevantLength = CmonMinimumUint32(RequestedLength, AvailableLength);
        plan.PayloadLength = CmonMinimumUint32(relevantLength, CMON_MAX_PAYLOAD);
        if (RequestedLength > plan.PayloadLength)
        {
            plan.Flags |= CMON_FLAG_TRUNCATED;
        }
    }
    else if (Direction == CmonCaptureDirectionOutput)
    {
        plan.Flags = CMON_FLAG_OUTPUT_PAYLOAD;
        if (LowerSucceeded)
        {
            relevantLength = CmonMinimumUint32(CompletedLength, RequestedLength);
            relevantLength = CmonMinimumUint32(relevantLength, AvailableLength);
            plan.PayloadLength = CmonMinimumUint32(relevantLength, CMON_MAX_PAYLOAD);
            if (CompletedLength > plan.PayloadLength)
            {
                plan.Flags |= CMON_FLAG_TRUNCATED;
            }
        }
    }

    return plan;
}

void
CmonCaptureInitializeEvent(
    _Out_ PCMON_EVENT_SLOT Event,
    _In_ const CMON_CAPTURE_METADATA* Metadata,
    _In_ int32_t LowerStatus,
    _In_ uint32_t CompletedLength,
    _In_ uint32_t PayloadLength,
    _In_ uint32_t Flags)
{
    CmonZeroMemory(&Event->Header, sizeof(Event->Header));
    Event->Header.Magic = CMON_MAGIC;
    Event->Header.Version = CMON_PROTOCOL_VERSION;
    Event->Header.HeaderSize = CMON_EVENT_HEADER_SIZE;
    Event->Header.TotalSize = CMON_EVENT_HEADER_SIZE + PayloadLength;
    Event->Header.QpcTicks = Metadata->QpcTicks;
    Event->Header.DeviceId = Metadata->DeviceId;
    Event->Header.ProcessId = Metadata->ProcessId;
    Event->Header.Kind = Metadata->Kind;
    Event->Header.IoctlCode = Metadata->IoctlCode;
    Event->Header.NtStatus = LowerStatus;
    Event->Header.RequestedLength = Metadata->RequestedLength;
    Event->Header.CompletedLength = CompletedLength;
    Event->Header.PayloadLength = PayloadLength;
    Event->Header.Flags = Flags;
}
