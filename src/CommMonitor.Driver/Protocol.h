#pragma once

#if defined(_KERNEL_MODE)
#include <ntddk.h>

typedef UCHAR uint8_t;
typedef USHORT uint16_t;
typedef ULONG uint32_t;
typedef ULONGLONG uint64_t;
typedef LONG int32_t;
typedef LONGLONG int64_t;
#else
#include <Windows.h>
#include <winioctl.h>
#include <stdint.h>
#endif

#define CMON_MAGIC 0x4E4F4D43u
#define CMON_PROTOCOL_VERSION 1u
#define CMON_EVENT_HEADER_SIZE 68u
#define CMON_MAX_PAYLOAD 4096u
#define CMON_MAX_SELECTED_DEVICES 64u

#define CMON_EVENT_READ 1u
#define CMON_EVENT_WRITE 2u
#define CMON_EVENT_IOCTL 3u
#define CMON_EVENT_CREATE 4u
#define CMON_EVENT_CLOSE 5u
#define CMON_EVENT_DROP_NOTICE 6u
#define CMON_EVENT_DEVICE_ARRIVAL 7u
#define CMON_EVENT_DEVICE_REMOVAL 8u

#define CMON_STATE_STOPPED 0u
#define CMON_STATE_RUNNING 1u
#define CMON_STATE_PAUSED 2u

#define CMON_FLAG_NONE 0x00000000u
#define CMON_FLAG_TRUNCATED 0x00000001u
#define CMON_FLAG_INPUT_PAYLOAD 0x00000002u
#define CMON_FLAG_OUTPUT_PAYLOAD 0x00000004u
#define CMON_FLAG_SYNTHETIC 0x00000008u

#define IOCTL_CMON_GET_VERSION \
    CTL_CODE(FILE_DEVICE_UNKNOWN, 0x800, METHOD_BUFFERED, FILE_READ_ACCESS | FILE_WRITE_ACCESS)
#define IOCTL_CMON_SET_CONFIG \
    CTL_CODE(FILE_DEVICE_UNKNOWN, 0x801, METHOD_BUFFERED, FILE_READ_ACCESS | FILE_WRITE_ACCESS)
#define IOCTL_CMON_GET_BATCH \
    CTL_CODE(FILE_DEVICE_UNKNOWN, 0x802, METHOD_BUFFERED, FILE_READ_ACCESS | FILE_WRITE_ACCESS)
#define IOCTL_CMON_GET_STATS \
    CTL_CODE(FILE_DEVICE_UNKNOWN, 0x803, METHOD_BUFFERED, FILE_READ_ACCESS | FILE_WRITE_ACCESS)

#pragma pack(push, 1)

typedef struct _CMON_EVENT_HEADER
{
    uint32_t Magic;
    uint16_t Version;
    uint16_t HeaderSize;
    uint32_t TotalSize;
    uint64_t Sequence;
    int64_t QpcTicks;
    uint64_t DeviceId;
    uint32_t ProcessId;
    uint32_t Kind;
    uint32_t IoctlCode;
    int32_t NtStatus;
    uint32_t RequestedLength;
    uint32_t CompletedLength;
    uint32_t PayloadLength;
    uint32_t Flags;
} CMON_EVENT_HEADER, *PCMON_EVENT_HEADER;

typedef struct _CMON_EVENT_SLOT
{
    CMON_EVENT_HEADER Header;
    uint8_t Payload[CMON_MAX_PAYLOAD];
} CMON_EVENT_SLOT, *PCMON_EVENT_SLOT;

typedef struct _CMON_VERSION_INFO
{
    uint32_t ProtocolVersion;
    uint32_t HeaderSize;
    uint32_t MaxPayloadLength;
} CMON_VERSION_INFO, *PCMON_VERSION_INFO;

typedef struct _CMON_CONFIG_INPUT
{
    uint32_t State;
    uint32_t DeviceCount;
    uint64_t DeviceHashes[ANYSIZE_ARRAY];
} CMON_CONFIG_INPUT, *PCMON_CONFIG_INPUT;

typedef struct _CMON_STATS_INFO
{
    uint32_t Queued;
    uint32_t State;
    uint64_t Dropped;
    uint64_t Sequence;
} CMON_STATS_INFO, *PCMON_STATS_INFO;

#pragma pack(pop)
