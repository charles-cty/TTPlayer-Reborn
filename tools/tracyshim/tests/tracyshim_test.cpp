#include <tracy/TracyC.h>
#include <array>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <new>
#include <thread>

extern "C" uint64_t tt_tracy_zone_begin_v2(const char* name) noexcept;
extern "C" void tt_tracy_zone_end_v2(uint64_t zone) noexcept;

static thread_local size_t allocationCount = 0;
static thread_local bool failAllocation = false;
static thread_local std::array<TracyCZoneCtx, 16> zoneStack;
static thread_local size_t zoneDepth = 0;
static thread_local uint32_t nextZoneId = UINT32_MAX;
static thread_local const ___tracy_source_location_data* lastLocation = nullptr;

static void Check(bool condition, const char* message) {
    if (!condition) {
        std::fprintf(stderr, "%s\n", message);
        std::abort();
    }
}

void* operator new(size_t size) {
    if (failAllocation) throw std::bad_alloc();
    auto* memory = std::malloc(size ? size : 1);
    if (!memory) throw std::bad_alloc();
    ++allocationCount;
    return memory;
}

void operator delete(void* memory) noexcept {
    std::free(memory);
}

void operator delete(void* memory, size_t) noexcept {
    std::free(memory);
}

extern "C" TracyCZoneCtx ___tracy_emit_zone_begin(
    const ___tracy_source_location_data* location, int32_t active) {
    Check(zoneDepth < zoneStack.size(), "Zone nesting overflow");
    lastLocation = location;
    const TracyCZoneCtx context = {nextZoneId++, active};
    zoneStack[zoneDepth++] = context;
    return context;
}

extern "C" void ___tracy_emit_zone_end(TracyCZoneCtx context) {
    Check(zoneDepth > 0, "Unexpected zone end");
    const auto expected = zoneStack[--zoneDepth];
    Check(context.id == expected.id && context.active == expected.active,
        "Zone context did not survive the uint64_t ABI");
}

extern "C" void ___tracy_emit_frame_mark_start(const char*) {}
extern "C" void ___tracy_emit_frame_mark_end(const char*) {}

int main() {
    const auto outer = tt_tracy_zone_begin_v2("Resize.Playlist.Update");
    const auto inner = tt_tracy_zone_begin_v2("Resize.Playlist.Render");
    Check(outer != 0 && inner != 0, "Active zones must have nonzero tokens, including id zero");
    tt_tracy_zone_end_v2(inner);
    tt_tracy_zone_end_v2(outer);

    const auto allocationsBefore = allocationCount;
    for (size_t iteration = 0; iteration < 10000; ++iteration) {
        const auto update = tt_tracy_zone_begin_v2("Resize.Playlist.Update");
        const auto render = tt_tracy_zone_begin_v2("Resize.Playlist.Render");
        tt_tracy_zone_end_v2(render);
        tt_tracy_zone_end_v2(update);
    }
    Check(allocationCount == allocationsBefore, "Repeated zones allocated shim memory");

    char transientName[] = "Temporary zone name";
    tt_tracy_zone_end_v2(tt_tracy_zone_begin_v2(transientName));
    const auto* savedLocation = lastLocation;
    transientName[0] = 'X';
    Check(std::strcmp(savedLocation->name, "Temporary zone name") == 0, "Zone name was not copied");
    tt_tracy_zone_end_v2(tt_tracy_zone_begin_v2("Temporary zone name"));
    Check(savedLocation == lastLocation, "Equal names did not reuse the source location");

    failAllocation = true;
    const auto failedZone = tt_tracy_zone_begin_v2("Uncached zone during allocation failure");
    failAllocation = false;
    Check(failedZone == 0, "Allocation failure did not disable the zone");
    tt_tracy_zone_end_v2(failedZone);
    Check(zoneDepth == 0, "Allocation failure unbalanced zones");

    const ___tracy_source_location_data* exitedThreadLocation = nullptr;
    std::thread worker([&] {
        tt_tracy_zone_end_v2(tt_tracy_zone_begin_v2("Worker zone"));
        exitedThreadLocation = lastLocation;
    });
    worker.join();
    Check(std::strcmp(exitedThreadLocation->name, "Worker zone") == 0,
        "Source location did not survive thread exit");
    std::puts("Tracy shim tests passed");
}
