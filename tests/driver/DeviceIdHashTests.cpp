#include "../../src/CommMonitor.Driver/CaptureCore.h"

#include <cstdint>
#include <string_view>
#include <vector>

namespace
{
std::vector<std::uint16_t> ToCodeUnits(std::u16string_view value)
{
    return std::vector<std::uint16_t>(value.begin(), value.end());
}
}

int main()
{
    const auto goldenId = ToCodeUnits(u"USB\\VID_1A86&PID_7523\\5&1234&0&2");
    const auto lowerId = ToCodeUnits(u"usb\\vid_1a86&pid_7523\\5&1234&0&2");
    constexpr std::uint64_t expected = UINT64_C(0x01D944A5154C9461);

    if (CmonHashDeviceIdUtf16(goldenId.data(), goldenId.size()) != expected)
    {
        return 101;
    }
    if (CmonHashDeviceIdUtf16(lowerId.data(), lowerId.size()) != expected)
    {
        return 102;
    }
    if (CmonHashDeviceIdUtf16(nullptr, 0) != UINT64_C(14695981039346656037))
    {
        return 103;
    }

    return 0;
}
