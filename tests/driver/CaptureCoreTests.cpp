#include "../../src/CommMonitor.Driver/CaptureCore.h"

#include <array>
#include <cstdint>
#include <cstring>

namespace
{
int CheckPayloadPlanning()
{
    CMON_CAPTURE_PAYLOAD_PLAN plan = CmonCapturePlanPayload(
        CmonCaptureDirectionInput,
        0,
        0,
        0,
        FALSE);
    if ((plan.PayloadLength != 0) ||
        (plan.Flags != CMON_FLAG_INPUT_PAYLOAD))
    {
        return 201;
    }

    plan = CmonCapturePlanPayload(
        CmonCaptureDirectionInput,
        CMON_MAX_PAYLOAD,
        0,
        CMON_MAX_PAYLOAD,
        FALSE);
    if ((plan.PayloadLength != CMON_MAX_PAYLOAD) ||
        (plan.Flags != CMON_FLAG_INPUT_PAYLOAD))
    {
        return 202;
    }

    plan = CmonCapturePlanPayload(
        CmonCaptureDirectionInput,
        CMON_MAX_PAYLOAD + 1u,
        0,
        CMON_MAX_PAYLOAD + 1u,
        FALSE);
    if ((plan.PayloadLength != CMON_MAX_PAYLOAD) ||
        (plan.Flags != (CMON_FLAG_INPUT_PAYLOAD | CMON_FLAG_TRUNCATED)))
    {
        return 203;
    }

    plan = CmonCapturePlanPayload(
        CmonCaptureDirectionOutput,
        CMON_MAX_PAYLOAD + 1u,
        CMON_MAX_PAYLOAD + 1u,
        CMON_MAX_PAYLOAD + 1u,
        TRUE);
    if ((plan.PayloadLength != CMON_MAX_PAYLOAD) ||
        (plan.Flags != (CMON_FLAG_OUTPUT_PAYLOAD | CMON_FLAG_TRUNCATED)))
    {
        return 204;
    }

    plan = CmonCapturePlanPayload(
        CmonCaptureDirectionOutput,
        64,
        17,
        64,
        FALSE);
    if ((plan.PayloadLength != 0) ||
        (plan.Flags != CMON_FLAG_OUTPUT_PAYLOAD))
    {
        return 205;
    }

    plan = CmonCapturePlanPayload(
        CmonCaptureDirectionInput,
        10,
        0,
        4,
        TRUE);
    if ((plan.PayloadLength != 4) ||
        (plan.Flags != (CMON_FLAG_INPUT_PAYLOAD | CMON_FLAG_TRUNCATED)))
    {
        return 206;
    }

    plan = CmonCapturePlanPayload(
        CmonCaptureDirectionOutput,
        8,
        6,
        10,
        TRUE);
    if ((plan.PayloadLength != 6) ||
        (plan.Flags != CMON_FLAG_OUTPUT_PAYLOAD))
    {
        return 207;
    }

    plan = CmonCapturePlanPayload(
        CmonCaptureDirectionOutput,
        10,
        10,
        4,
        TRUE);
    if ((plan.PayloadLength != 4) ||
        (plan.Flags != (CMON_FLAG_OUTPUT_PAYLOAD | CMON_FLAG_TRUNCATED)))
    {
        return 208;
    }

    return 0;
}

int CheckSelection()
{
    const std::array<std::uint64_t, 2> selected = {
        UINT64_C(0x1111),
        UINT64_C(0x2222),
    };

    if (CmonCaptureDeviceIsSelected(
            CMON_STATE_STOPPED,
            selected[0],
            selected.data(),
            static_cast<std::uint32_t>(selected.size())))
    {
        return 301;
    }
    if (CmonCaptureDeviceIsSelected(
            CMON_STATE_PAUSED,
            selected[0],
            selected.data(),
            static_cast<std::uint32_t>(selected.size())))
    {
        return 302;
    }
    if (!CmonCaptureDeviceIsSelected(
            CMON_STATE_RUNNING,
            selected[1],
            selected.data(),
            static_cast<std::uint32_t>(selected.size())))
    {
        return 303;
    }
    if (CmonCaptureDeviceIsSelected(
            CMON_STATE_RUNNING,
            UINT64_C(0x3333),
            selected.data(),
            static_cast<std::uint32_t>(selected.size())))
    {
        return 304;
    }
    if (CmonCaptureDeviceIsSelected(
            CMON_STATE_RUNNING,
            0,
            selected.data(),
            static_cast<std::uint32_t>(selected.size())))
    {
        return 305;
    }

    return 0;
}

int CheckIoctlDirections()
{
    constexpr auto serialIoctl = [](const ULONG function) {
        return CTL_CODE(
            FILE_DEVICE_SERIAL_PORT,
            function,
            METHOD_BUFFERED,
            FILE_ANY_ACCESS);
    };
    const std::array<ULONG, 10> inputIoctls = {
        serialIoctl(1),
        serialIoctl(3),
        serialIoctl(25),
        serialIoctl(7),
        serialIoctl(23),
        serialIoctl(9),
        serialIoctl(10),
        serialIoctl(12),
        serialIoctl(13),
        serialIoctl(19),
    };
    const std::array<ULONG, 6> outputIoctls = {
        serialIoctl(20),
        serialIoctl(21),
        serialIoctl(24),
        serialIoctl(8),
        serialIoctl(22),
        serialIoctl(30),
    };

    for (const ULONG code : inputIoctls)
    {
        if (CmonSerialIoctlDirection(code) != CmonCaptureDirectionInput)
        {
            return 401;
        }
    }
    for (const ULONG code : outputIoctls)
    {
        if (CmonSerialIoctlDirection(code) != CmonCaptureDirectionOutput)
        {
            return 402;
        }
    }
    if (CmonSerialIoctlDirection(serialIoctl(26)) !=
        CmonCaptureDirectionNone)
    {
        return 403;
    }

    return 0;
}

int CheckExactCompletionMetadata()
{
    CMON_EVENT_SLOT event{};
    CMON_CAPTURE_METADATA metadata{};
    metadata.QpcTicks = INT64_C(0x102030405060708);
    metadata.DeviceId = UINT64_C(0x8877665544332211);
    metadata.ProcessId = 0x10203040u;
    metadata.Kind = CMON_EVENT_READ;
    metadata.IoctlCode = 0;
    metadata.RequestedLength = 0x55667788u;

    CmonCaptureInitializeEvent(
        &event,
        &metadata,
        static_cast<std::int32_t>(0xC0000120u),
        0x11223344u,
        3u,
        CMON_FLAG_OUTPUT_PAYLOAD);

    if ((event.Header.QpcTicks != metadata.QpcTicks) ||
        (event.Header.DeviceId != metadata.DeviceId) ||
        (event.Header.ProcessId != metadata.ProcessId) ||
        (event.Header.Kind != metadata.Kind) ||
        (event.Header.IoctlCode != metadata.IoctlCode) ||
        (event.Header.NtStatus != static_cast<std::int32_t>(0xC0000120u)) ||
        (event.Header.RequestedLength != metadata.RequestedLength) ||
        (event.Header.CompletedLength != 0x11223344u) ||
        (event.Header.PayloadLength != 3u) ||
        (event.Header.Flags != CMON_FLAG_OUTPUT_PAYLOAD))
    {
        return 501;
    }

    return 0;
}

int CheckWireLengthRepresentability()
{
    if (!CmonCaptureLengthIsRepresentable(static_cast<SIZE_T>(UINT32_MAX)))
    {
        return 601;
    }
#if defined(_WIN64)
    if (CmonCaptureLengthIsRepresentable(
            static_cast<SIZE_T>(UINT32_MAX) + 1u))
    {
        return 602;
    }
#endif
    return 0;
}

int CheckWriteSnapshotOwnsCopiedBytes()
{
    std::array<std::uint8_t, 4> source = {0x10, 0x20, 0x30, 0x40};
    std::array<std::uint8_t, 4> snapshot = {};

    if (!CmonCaptureCopyPayload(
            snapshot.data(),
            static_cast<std::uint32_t>(snapshot.size()),
            source.data(),
            static_cast<std::uint32_t>(source.size())))
    {
        return 701;
    }
    source.fill(0xFF);
    if (snapshot != std::array<std::uint8_t, 4>{0x10, 0x20, 0x30, 0x40})
    {
        return 702;
    }
    if (CmonCaptureCopyPayload(snapshot.data(), 3, source.data(), 4))
    {
        return 703;
    }
    return 0;
}
}

int main()
{
    const std::array checks = {
        CheckPayloadPlanning(),
        CheckSelection(),
        CheckIoctlDirections(),
        CheckExactCompletionMetadata(),
        CheckWireLengthRepresentability(),
        CheckWriteSnapshotOwnsCopiedBytes(),
    };
    for (const int result : checks)
    {
        if (result != 0)
        {
            return result;
        }
    }
    return 0;
}
