#include "../../src/CommMonitor.Driver/Protocol.h"

#if defined(_KERNEL_MODE) && defined(_STDINT)
#error Protocol.h kernel branch must not include the MSVC stdint.h header.
#endif

C_ASSERT(sizeof(uint8_t) == 1);
C_ASSERT(sizeof(uint16_t) == 2);
C_ASSERT(sizeof(uint32_t) == 4);
C_ASSERT(sizeof(uint64_t) == 8);
C_ASSERT(sizeof(int32_t) == 4);
C_ASSERT(sizeof(int64_t) == 8);
C_ASSERT(sizeof(CMON_EVENT_HEADER) == 68);
C_ASSERT(FIELD_OFFSET(CMON_EVENT_HEADER, Sequence) == 12);
C_ASSERT(FIELD_OFFSET(CMON_EVENT_HEADER, PayloadLength) == 60);
C_ASSERT(sizeof(CMON_EVENT_SLOT) == 4164);
C_ASSERT(sizeof(CMON_VERSION_INFO) == 12);
C_ASSERT(FIELD_OFFSET(CMON_VERSION_INFO, ProtocolVersion) == 0);
C_ASSERT(sizeof(((CMON_VERSION_INFO*)0)->ProtocolVersion) == sizeof(uint32_t));
C_ASSERT(FIELD_OFFSET(CMON_VERSION_INFO, HeaderSize) == 4);
C_ASSERT(sizeof(((CMON_VERSION_INFO*)0)->HeaderSize) == sizeof(uint32_t));
C_ASSERT(FIELD_OFFSET(CMON_VERSION_INFO, MaxPayloadLength) == 8);
C_ASSERT(sizeof(((CMON_VERSION_INFO*)0)->MaxPayloadLength) == sizeof(uint32_t));
C_ASSERT(FIELD_OFFSET(CMON_CONFIG_INPUT, State) == 0);
C_ASSERT(sizeof(((CMON_CONFIG_INPUT*)0)->State) == sizeof(uint32_t));
C_ASSERT(FIELD_OFFSET(CMON_CONFIG_INPUT, DeviceCount) == 4);
C_ASSERT(sizeof(((CMON_CONFIG_INPUT*)0)->DeviceCount) == sizeof(uint32_t));
C_ASSERT(FIELD_OFFSET(CMON_CONFIG_INPUT, DeviceHashes) == 8);
C_ASSERT(sizeof(((CMON_CONFIG_INPUT*)0)->DeviceHashes[0]) == sizeof(uint64_t));
C_ASSERT(sizeof(CMON_STATS_INFO) == 24);
C_ASSERT(FIELD_OFFSET(CMON_STATS_INFO, Queued) == 0);
C_ASSERT(sizeof(((CMON_STATS_INFO*)0)->Queued) == sizeof(uint32_t));
C_ASSERT(FIELD_OFFSET(CMON_STATS_INFO, State) == 4);
C_ASSERT(sizeof(((CMON_STATS_INFO*)0)->State) == sizeof(uint32_t));
C_ASSERT(FIELD_OFFSET(CMON_STATS_INFO, Dropped) == 8);
C_ASSERT(sizeof(((CMON_STATS_INFO*)0)->Dropped) == sizeof(uint64_t));
C_ASSERT(FIELD_OFFSET(CMON_STATS_INFO, Sequence) == 16);
C_ASSERT(sizeof(((CMON_STATS_INFO*)0)->Sequence) == sizeof(uint64_t));
C_ASSERT(CMON_MAX_SELECTED_DEVICES == 64u);
