#include <cstddef>
#include <cstdint>
#include <cstring>
#include <vector>

#include "../../src/CommMonitor.Driver/TransportCore.h"

static int Require(bool condition, int line)
{
    return condition ? 0 : line;
}

static CMON_EVENT_SLOT MakeEvent(
    std::uint32_t kind,
    const std::vector<std::uint8_t>& payload)
{
    CMON_EVENT_SLOT event{};
    event.Header.Kind = kind;
    event.Header.PayloadLength = static_cast<std::uint32_t>(payload.size());
    if (!payload.empty())
    {
        std::memcpy(event.Payload, payload.data(), payload.size());
    }
    return event;
}

static std::vector<std::uint8_t> MakeConfig(
    std::uint32_t state,
    const std::vector<std::uint64_t>& hashes)
{
    const std::uint32_t count = static_cast<std::uint32_t>(hashes.size());
    std::vector<std::uint8_t> bytes(
        CMON_CONFIG_PREFIX_SIZE + hashes.size() * sizeof(hashes[0]));
    std::memcpy(bytes.data(), &state, sizeof(state));
    std::memcpy(bytes.data() + sizeof(state), &count, sizeof(count));
    if (!hashes.empty())
    {
        std::memcpy(
            bytes.data() + CMON_CONFIG_PREFIX_SIZE,
            hashes.data(),
            hashes.size() * sizeof(hashes[0]));
    }
    return bytes;
}

static int TestRingCore()
{
    std::vector<CMON_EVENT_SLOT> slots(2);
    CMON_RING_CORE ring{};
    CmonRingCoreInitialize(
        &ring,
        slots.data(),
        static_cast<std::uint32_t>(slots.size()));

    CMON_EVENT_SLOT invalid = MakeEvent(CMON_EVENT_READ, {});
    invalid.Header.PayloadLength = CMON_MAX_PAYLOAD + 1u;
    if (const int result = Require(
            CmonRingCorePush(&ring, &invalid) == CmonRingPushInvalidPayload &&
                ring.Sequence == 0 && ring.Dropped == 0 && ring.Count == 0,
            __LINE__);
        result != 0)
    {
        return result;
    }

    const CMON_EVENT_SLOT first = MakeEvent(CMON_EVENT_READ, {0xA1, 0xA2});
    const CMON_EVENT_SLOT second = MakeEvent(CMON_EVENT_WRITE, {0xB1});
    const CMON_EVENT_SLOT dropped = MakeEvent(CMON_EVENT_IOCTL, {0xC1});
    if (const int result = Require(
            CmonRingCorePush(&ring, &first) == CmonRingPushStored &&
                CmonRingCorePush(&ring, &second) == CmonRingPushStored &&
                CmonRingCorePush(&ring, &dropped) == CmonRingPushFull,
            __LINE__);
        result != 0)
    {
        return result;
    }
    if (const int result = Require(
            ring.Count == 2 && ring.Sequence == 3 && ring.Dropped == 1 &&
                slots[0].Header.Sequence == 1 &&
                slots[1].Header.Sequence == 2 &&
                slots[0].Payload[0] == 0xA1 &&
                slots[1].Payload[0] == 0xB1,
            __LINE__);
        result != 0)
    {
        return result;
    }

    std::vector<std::uint8_t> exactOutput(
        CMON_EVENT_HEADER_SIZE + first.Header.PayloadLength);
    SIZE_T eventBytes = 0;
    if (const int result = Require(
            CmonRingCorePopOne(
                &ring,
                exactOutput.data(),
                exactOutput.size(),
                FALSE,
                &eventBytes) == CmonRingPopCopied &&
                eventBytes == exactOutput.size() && ring.Count == 1,
            __LINE__);
        result != 0)
    {
        return result;
    }
    CMON_EVENT_HEADER outputHeader{};
    std::memcpy(&outputHeader, exactOutput.data(), sizeof(outputHeader));
    if (const int result = Require(
            outputHeader.Magic == CMON_MAGIC &&
                outputHeader.Version == CMON_PROTOCOL_VERSION &&
                outputHeader.HeaderSize == CMON_EVENT_HEADER_SIZE &&
                outputHeader.TotalSize == exactOutput.size() &&
                outputHeader.Sequence == 1 &&
                exactOutput[CMON_EVENT_HEADER_SIZE] == 0xA1 &&
                exactOutput[CMON_EVENT_HEADER_SIZE + 1] == 0xA2,
            __LINE__);
        result != 0)
    {
        return result;
    }

    const CMON_EVENT_SLOT fourth = MakeEvent(
        CMON_EVENT_CREATE,
        {0xD1, 0xD2, 0xD3});
    if (const int result = Require(
            CmonRingCorePush(&ring, &fourth) == CmonRingPushStored &&
                ring.Sequence == 4 && ring.Count == 2,
            __LINE__);
        result != 0)
    {
        return result;
    }

    std::vector<std::uint8_t> partialOutput(
        CMON_EVENT_HEADER_SIZE + second.Header.PayloadLength + 1u);
    eventBytes = 0;
    if (const int result = Require(
            CmonRingCorePopOne(
                &ring,
                partialOutput.data(),
                partialOutput.size(),
                FALSE,
                &eventBytes) == CmonRingPopCopied &&
                eventBytes == CMON_EVENT_HEADER_SIZE + second.Header.PayloadLength,
            __LINE__);
        result != 0)
    {
        return result;
    }
    const SIZE_T firstBatchBytes = eventBytes;
    SIZE_T laterBytes = 99;
    const std::uint32_t headBeforePartial = ring.Head;
    if (const int result = Require(
            CmonRingCorePopOne(
                &ring,
                partialOutput.data() + firstBatchBytes,
                partialOutput.size() - firstBatchBytes,
                TRUE,
                &laterBytes) == CmonRingPopBatchComplete &&
                laterBytes == 0 && ring.Count == 1 &&
                ring.Head == headBeforePartial,
            __LINE__);
        result != 0)
    {
        return result;
    }

    std::vector<CMON_EVENT_SLOT> smallSlots(1);
    CMON_RING_CORE smallRing{};
    CmonRingCoreInitialize(&smallRing, smallSlots.data(), 1);
    const CMON_EVENT_SLOT large = MakeEvent(
        CMON_EVENT_CLOSE,
        {0xE1, 0xE2, 0xE3, 0xE4});
    (void)CmonRingCorePush(&smallRing, &large);
    std::vector<std::uint8_t> tooSmall(
        CMON_EVENT_HEADER_SIZE + large.Header.PayloadLength - 1u);
    const std::uint32_t headBeforeSmall = smallRing.Head;
    eventBytes = 99;
    if (const int result = Require(
            CmonRingCorePopOne(
                &smallRing,
                tooSmall.data(),
                tooSmall.size(),
                FALSE,
                &eventBytes) == CmonRingPopFirstTooSmall &&
                eventBytes == 0 && smallRing.Count == 1 &&
                smallRing.Head == headBeforeSmall,
            __LINE__);
        result != 0)
    {
        return result;
    }

    std::vector<std::uint8_t> fourthOutput(
        CMON_EVENT_HEADER_SIZE + fourth.Header.PayloadLength);
    eventBytes = 0;
    if (const int result = Require(
            CmonRingCorePopOne(
                &ring,
                fourthOutput.data(),
                fourthOutput.size(),
                FALSE,
                &eventBytes) == CmonRingPopCopied &&
                ring.Count == 0,
            __LINE__);
        result != 0)
    {
        return result;
    }
    std::memcpy(&outputHeader, fourthOutput.data(), sizeof(outputHeader));
    if (const int result = Require(
            outputHeader.Sequence == 4 &&
                fourthOutput[CMON_EVENT_HEADER_SIZE + 2] == 0xD3,
            __LINE__);
        result != 0)
    {
        return result;
    }

    eventBytes = 99;
    if (const int result = Require(
            CmonRingCorePopOne(
                &ring,
                fourthOutput.data(),
                fourthOutput.size(),
                FALSE,
                &eventBytes) == CmonRingPopEmpty &&
                eventBytes == 0,
            __LINE__);
        result != 0)
    {
        return result;
    }

    return 0;
}

static int TestConfigValidation()
{
    std::uint32_t state = 99;
    std::uint32_t count = 99;

    const std::vector<std::uint8_t> stopped = MakeConfig(CMON_STATE_STOPPED, {});
    if (const int result = Require(
            CmonConfigBytesAreValid(
                stopped.data(), stopped.size(), &state, &count) &&
                state == CMON_STATE_STOPPED && count == 0,
            __LINE__);
        result != 0)
    {
        return result;
    }

    const std::vector<std::uint8_t> running = MakeConfig(
        CMON_STATE_RUNNING,
        {0x101u, 0x202u});
    if (const int result = Require(
            CmonConfigBytesAreValid(
                running.data(), running.size(), &state, &count) &&
                state == CMON_STATE_RUNNING && count == 2 &&
                CmonConfigReadDeviceHash(running.data(), 0) == 0x101u &&
                CmonConfigReadDeviceHash(running.data(), 1) == 0x202u,
            __LINE__);
        result != 0)
    {
        return result;
    }

    std::vector<std::uint64_t> maximumHashes(CMON_MAX_SELECTED_DEVICES);
    for (std::size_t index = 0; index < maximumHashes.size(); ++index)
    {
        maximumHashes[index] = static_cast<std::uint64_t>(index + 1u);
    }
    const std::vector<std::uint8_t> maximum = MakeConfig(
        CMON_STATE_PAUSED,
        maximumHashes);
    if (const int result = Require(
            CmonConfigBytesAreValid(
                maximum.data(), maximum.size(), nullptr, nullptr),
            __LINE__);
        result != 0)
    {
        return result;
    }

    std::vector<std::uint64_t> tooManyHashes(
        CMON_MAX_SELECTED_DEVICES + 1u,
        1u);
    for (std::size_t index = 0; index < tooManyHashes.size(); ++index)
    {
        tooManyHashes[index] = static_cast<std::uint64_t>(index + 1u);
    }
    const std::vector<std::uint8_t> tooMany = MakeConfig(
        CMON_STATE_RUNNING,
        tooManyHashes);
    if (const int result = Require(
            !CmonConfigBytesAreValid(
                tooMany.data(), tooMany.size(), nullptr, nullptr),
            __LINE__);
        result != 0)
    {
        return result;
    }

    const std::vector<std::uint8_t> invalidState = MakeConfig(99u, {1u});
    const std::vector<std::uint8_t> emptyRunning = MakeConfig(
        CMON_STATE_RUNNING,
        {});
    const std::vector<std::uint8_t> zeroHash = MakeConfig(
        CMON_STATE_RUNNING,
        {0u});
    const std::vector<std::uint8_t> duplicateHash = MakeConfig(
        CMON_STATE_RUNNING,
        {7u, 7u});
    state = 99;
    count = 99;
    if (const int result = Require(
            !CmonConfigBytesAreValid(
                invalidState.data(), invalidState.size(), &state, &count) &&
                state == 0 && count == 0,
            __LINE__);
        result != 0)
    {
        return result;
    }
    if (const int result = Require(
            !CmonConfigBytesAreValid(
                invalidState.data(), invalidState.size(), nullptr, nullptr) &&
                !CmonConfigBytesAreValid(
                    emptyRunning.data(), emptyRunning.size(), nullptr, nullptr) &&
                !CmonConfigBytesAreValid(
                    zeroHash.data(), zeroHash.size(), nullptr, nullptr) &&
                !CmonConfigBytesAreValid(
                    duplicateHash.data(), duplicateHash.size(), nullptr, nullptr),
            __LINE__);
        result != 0)
    {
        return result;
    }

    std::vector<std::uint8_t> trailing = running;
    trailing.push_back(0);
    std::vector<std::uint8_t> truncated = running;
    truncated.pop_back();
    if (const int result = Require(
            !CmonConfigBytesAreValid(
                trailing.data(), trailing.size(), nullptr, nullptr) &&
                !CmonConfigBytesAreValid(
                    truncated.data(), truncated.size(), nullptr, nullptr),
            __LINE__);
        result != 0)
    {
        return result;
    }

    return 0;
}

int main()
{
    if (const int result = TestRingCore(); result != 0)
    {
        return result;
    }
    return TestConfigValidation();
}
