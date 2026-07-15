#include <cstddef>
#include <cstdint>
#include "../../src/CommMonitor.Driver/Protocol.h"

static_assert(sizeof(CMON_EVENT_HEADER) == 68);
static_assert(offsetof(CMON_EVENT_HEADER, Magic) == 0);
static_assert(sizeof(((CMON_EVENT_HEADER*)nullptr)->Magic) == sizeof(std::uint32_t));
static_assert(offsetof(CMON_EVENT_HEADER, Version) == 4);
static_assert(sizeof(((CMON_EVENT_HEADER*)nullptr)->Version) == sizeof(std::uint16_t));
static_assert(offsetof(CMON_EVENT_HEADER, HeaderSize) == 6);
static_assert(sizeof(((CMON_EVENT_HEADER*)nullptr)->HeaderSize) == sizeof(std::uint16_t));
static_assert(offsetof(CMON_EVENT_HEADER, TotalSize) == 8);
static_assert(sizeof(((CMON_EVENT_HEADER*)nullptr)->TotalSize) == sizeof(std::uint32_t));
static_assert(offsetof(CMON_EVENT_HEADER, Sequence) == 12);
static_assert(sizeof(((CMON_EVENT_HEADER*)nullptr)->Sequence) == sizeof(std::uint64_t));
static_assert(offsetof(CMON_EVENT_HEADER, QpcTicks) == 20);
static_assert(sizeof(((CMON_EVENT_HEADER*)nullptr)->QpcTicks) == sizeof(std::int64_t));
static_assert(offsetof(CMON_EVENT_HEADER, DeviceId) == 28);
static_assert(sizeof(((CMON_EVENT_HEADER*)nullptr)->DeviceId) == sizeof(std::uint64_t));
static_assert(offsetof(CMON_EVENT_HEADER, ProcessId) == 36);
static_assert(sizeof(((CMON_EVENT_HEADER*)nullptr)->ProcessId) == sizeof(std::uint32_t));
static_assert(offsetof(CMON_EVENT_HEADER, Kind) == 40);
static_assert(sizeof(((CMON_EVENT_HEADER*)nullptr)->Kind) == sizeof(std::uint32_t));
static_assert(offsetof(CMON_EVENT_HEADER, IoctlCode) == 44);
static_assert(sizeof(((CMON_EVENT_HEADER*)nullptr)->IoctlCode) == sizeof(std::uint32_t));
static_assert(offsetof(CMON_EVENT_HEADER, NtStatus) == 48);
static_assert(sizeof(((CMON_EVENT_HEADER*)nullptr)->NtStatus) == sizeof(std::int32_t));
static_assert(offsetof(CMON_EVENT_HEADER, RequestedLength) == 52);
static_assert(sizeof(((CMON_EVENT_HEADER*)nullptr)->RequestedLength) == sizeof(std::uint32_t));
static_assert(offsetof(CMON_EVENT_HEADER, CompletedLength) == 56);
static_assert(sizeof(((CMON_EVENT_HEADER*)nullptr)->CompletedLength) == sizeof(std::uint32_t));
static_assert(offsetof(CMON_EVENT_HEADER, PayloadLength) == 60);
static_assert(sizeof(((CMON_EVENT_HEADER*)nullptr)->PayloadLength) == sizeof(std::uint32_t));
static_assert(offsetof(CMON_EVENT_HEADER, Flags) == 64);
static_assert(sizeof(((CMON_EVENT_HEADER*)nullptr)->Flags) == sizeof(std::uint32_t));

static_assert(sizeof(CMON_EVENT_SLOT) == 4164);
static_assert(offsetof(CMON_EVENT_SLOT, Payload) == 68);

static_assert(sizeof(CMON_VERSION_INFO) == 12);
static_assert(offsetof(CMON_VERSION_INFO, ProtocolVersion) == 0);
static_assert(sizeof(((CMON_VERSION_INFO*)nullptr)->ProtocolVersion) == sizeof(std::uint32_t));
static_assert(offsetof(CMON_VERSION_INFO, HeaderSize) == 4);
static_assert(sizeof(((CMON_VERSION_INFO*)nullptr)->HeaderSize) == sizeof(std::uint32_t));
static_assert(offsetof(CMON_VERSION_INFO, MaxPayloadLength) == 8);
static_assert(sizeof(((CMON_VERSION_INFO*)nullptr)->MaxPayloadLength) == sizeof(std::uint32_t));

static_assert(offsetof(CMON_CONFIG_INPUT, State) == 0);
static_assert(sizeof(((CMON_CONFIG_INPUT*)nullptr)->State) == sizeof(std::uint32_t));
static_assert(offsetof(CMON_CONFIG_INPUT, DeviceCount) == 4);
static_assert(sizeof(((CMON_CONFIG_INPUT*)nullptr)->DeviceCount) == sizeof(std::uint32_t));
static_assert(offsetof(CMON_CONFIG_INPUT, DeviceHashes) == 8);
static_assert(sizeof(((CMON_CONFIG_INPUT*)nullptr)->DeviceHashes[0]) == sizeof(std::uint64_t));

static_assert(sizeof(CMON_STATS_INFO) == 24);
static_assert(offsetof(CMON_STATS_INFO, Queued) == 0);
static_assert(sizeof(((CMON_STATS_INFO*)nullptr)->Queued) == sizeof(std::uint32_t));
static_assert(offsetof(CMON_STATS_INFO, State) == 4);
static_assert(sizeof(((CMON_STATS_INFO*)nullptr)->State) == sizeof(std::uint32_t));
static_assert(offsetof(CMON_STATS_INFO, Dropped) == 8);
static_assert(sizeof(((CMON_STATS_INFO*)nullptr)->Dropped) == sizeof(std::uint64_t));
static_assert(offsetof(CMON_STATS_INFO, Sequence) == 16);
static_assert(sizeof(((CMON_STATS_INFO*)nullptr)->Sequence) == sizeof(std::uint64_t));

static_assert(CMON_MAGIC == 0x4E4F4D43u);
static_assert(CMON_PROTOCOL_VERSION == 1u);
static_assert(CMON_EVENT_HEADER_SIZE == 68u);
static_assert(CMON_MAX_PAYLOAD == 4096u);
static_assert(CMON_MAX_SELECTED_DEVICES == 64u);

static_assert(IOCTL_CMON_GET_VERSION == 0x0022E000u);
static_assert(IOCTL_CMON_SET_CONFIG == 0x0022E004u);
static_assert(IOCTL_CMON_GET_BATCH == 0x0022E008u);
static_assert(IOCTL_CMON_GET_STATS == 0x0022E00Cu);

static_assert(CMON_EVENT_READ == 1u);
static_assert(CMON_EVENT_WRITE == 2u);
static_assert(CMON_EVENT_IOCTL == 3u);
static_assert(CMON_EVENT_CREATE == 4u);
static_assert(CMON_EVENT_CLOSE == 5u);
static_assert(CMON_EVENT_DROP_NOTICE == 6u);
static_assert(CMON_EVENT_DEVICE_ARRIVAL == 7u);
static_assert(CMON_EVENT_DEVICE_REMOVAL == 8u);

static_assert(CMON_STATE_STOPPED == 0u);
static_assert(CMON_STATE_RUNNING == 1u);
static_assert(CMON_STATE_PAUSED == 2u);

static_assert(CMON_FLAG_NONE == 0x00000000u);
static_assert(CMON_FLAG_TRUNCATED == 0x00000001u);
static_assert(CMON_FLAG_INPUT_PAYLOAD == 0x00000002u);
static_assert(CMON_FLAG_OUTPUT_PAYLOAD == 0x00000004u);
static_assert(CMON_FLAG_SYNTHETIC == 0x00000008u);

int main() { return 0; }
