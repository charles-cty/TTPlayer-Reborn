#include <tracy/TracyC.h>
#include <cstdint>
#include <map>
#include <string>

#ifdef _WIN32
#define TT_TRACY_EXPORT __declspec(dllexport)
#else
#define TT_TRACY_EXPORT
#endif

extern "C" {
TT_TRACY_EXPORT uint64_t tt_tracy_zone_begin_v2(const char* name) noexcept {
    static_assert(sizeof(TracyCZoneCtx) == sizeof(uint64_t),
        "The v2 zone ABI requires Tracy without TRACY_ON_DEMAND");
    try {
        using SourceLocations = std::map<std::string, ___tracy_source_location_data, std::less<>>;
        static thread_local auto* sourceLocations = new SourceLocations;
        const auto* zoneName = name ? name : "zone";
        auto location = sourceLocations->find(zoneName);
        if (location == sourceLocations->end()) {
            location = sourceLocations->try_emplace(zoneName).first;
            location->second = {location->first.c_str(), "pascal", "tttracy", 0, 0};
        }
        const auto context = ___tracy_emit_zone_begin(&location->second, 1);
        return (uint64_t(uint32_t(context.active)) << 32) | context.id;
    } catch (...) {
        return 0;
    }
}

TT_TRACY_EXPORT void tt_tracy_zone_end_v2(uint64_t zone) noexcept {
    if (zone != 0) {
        const TracyCZoneCtx context = {uint32_t(zone), int32_t(zone >> 32)};
        ___tracy_emit_zone_end(context);
    }
}

TT_TRACY_EXPORT void tt_tracy_frame_start(const char* name) noexcept {
    ___tracy_emit_frame_mark_start(name);
}

TT_TRACY_EXPORT void tt_tracy_frame_end(const char* name) noexcept {
    ___tracy_emit_frame_mark_end(name);
}

}
