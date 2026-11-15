// apv-host — the single-owner Reims backend for the E16 AppleParavirtGPU live bridge.
//
// One console-session process owns everything that must not run as root:
//   * the real Reims device (Metal backend on the XeGfx Metal device);
//   * the shared 16 KiB BAR0 page exported by ReimsAPVBridge (io mapping type 0);
//   * the session client (type 2: arm / raise IRQ0 / map guest physical pages)
//     and the scalar MMIO transport client (type 1).
//
// Data flow:
//   AppleParavirtGPU inline BAR0 accesses
//     -> patched call sites in Apple's text -> kext dispatcher -> type-1 client
//     -> this process -> rvg_device_mmio_read/write -> Reims (Metal on XeGfx)
//   register writes Apple stores in the shared BAR0 page are applied here by a
//   poll loop, in a fixed order; the registers Reims owns (read cursor, fault
//   flag, port count) are published back into the page.
//   Reims raise_interrupt -> this process -> type-2 client -> IRQ0 handler.
//
// The guest memory route is the Reims task/memory callbacks (no static memory
// map): the host reserves the address space, and the kext maps the guest
// physical pages Apple hands to Reims into it with a fixed-address mapping.
//
// Build (MacBook Air, x86_64): bash build.sh
// Run on the ThinkPad, in the GUI session, from the package directory:
//   ./apv-host --registry-id <REIMS_METAL_REGISTRY_ID> --seconds 45
#include <IOKit/IOKitLib.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <mach/vm_page_size.h>
#include <pthread.h>
#include <unistd.h>

#include <atomic>
#include <cerrno>
#include <cinttypes>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "panel.hpp"
#include "reims_vgpu.h"

namespace {

constexpr uint64_t kBarSize = RVG_DEVICE_MMIO_SIZE;
constexpr uint32_t kCellDisplayPortCount = 0x122c;
constexpr uint32_t kCellDisplayConnectionTypes = 0x1234;
constexpr uint32_t kCellFifoRead = 0x100c;
constexpr uint32_t kCellFault = 0x102c;

constexpr IOReturn kIoNotReady = static_cast<IOReturn>(0xe00002d8u);

FILE *gLogFile = nullptr;

void say(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
void say(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stdout, fmt, ap);
    va_end(ap);
    fputc('\n', stdout);
    fflush(stdout);
    if (gLogFile) {
        va_start(ap, fmt);
        vfprintf(gLogFile, fmt, ap);
        va_end(ap);
        fputc('\n', gLogFile);
        fflush(gLogFile);
    }
}

// ---------------------------------------------------------------------------
// The kext clients
// ---------------------------------------------------------------------------
class BridgeClient {
public:
    ~BridgeClient() { close(); }

    bool open();
    void close();

    IOReturn arm() { return callScalar(session_, kSelectorArm, nullptr, 0, nullptr, nullptr); }
    IOReturn raiseInterrupt() {
        uint64_t vector = 0;
        return callScalar(session_, kSelectorRaise, &vector, 1, nullptr, nullptr);
    }
    IOReturn mapPhysical(uint64_t physical, uint64_t length, uint64_t target) {
        MapRequest request = {physical, length, target};
        return IOConnectCallStructMethod(session_, kSelectorMapPhysical, &request, sizeof(request),
                                         nullptr, nullptr);
    }
    IOReturn unmapPhysical(uint64_t target, uint64_t length) {
        UnmapRequest request = {target, length};
        return IOConnectCallStructMethod(session_, kSelectorUnmapPhysical, &request,
                                         sizeof(request), nullptr, nullptr);
    }
    IOReturn fetchMmio(uint64_t request[4], uint32_t &count) {
        count = 4;
        return callScalar(transport_, 0, nullptr, 0, request, &count);
    }
    IOReturn completeMmio(const uint64_t reply[3]) {
        return callScalar(transport_, 1, reply, 3, nullptr, nullptr);
    }
    // selector 6: dispatch calls, dispatch failures, patched sites, BAR bases.
    bool statistics(uint64_t out[4]) {
        uint32_t count = 4;
        return callScalar(session_, 6, nullptr, 0, out, &count) == kIOReturnSuccess && count == 4;
    }

    volatile uint32_t *cell(uint32_t barOffset) {
        return reinterpret_cast<volatile uint32_t *>(bar_ + barOffset);
    }
    uint8_t *bar() { return bar_; }

private:
    enum {
        kSelectorArm = 1,
        kSelectorRaise = 2,
        kSelectorMapPhysical = 3,
        kSelectorUnmapPhysical = 4,
    };
    struct MapRequest {
        uint64_t physicalAddress;
        uint64_t length;
        uint64_t targetAddress;
    };
    struct UnmapRequest {
        uint64_t targetAddress;
        uint64_t length;
    };

    static IOReturn callScalar(io_connect_t connection, uint32_t selector, const uint64_t *input,
                               uint32_t inputCount, uint64_t *output, uint32_t *outputCount);

    io_service_t service_ = 0;
    io_connect_t session_ = 0;
    io_connect_t transport_ = 0;
    uint8_t *bar_ = nullptr;
    mach_vm_size_t barLength_ = 0;
};

IOReturn BridgeClient::callScalar(io_connect_t connection, uint32_t selector,
                                  const uint64_t *input, uint32_t inputCount, uint64_t *output,
                                  uint32_t *outputCount) {
    return IOConnectCallScalarMethod(connection, selector, input, inputCount, output, outputCount);
}

bool BridgeClient::open() {
    CFMutableDictionaryRef matching = IOServiceMatching("ReimsPCIProbe");
    if (!matching) {
        say("host: IOServiceMatching failed");
        return false;
    }
    service_ = IOServiceGetMatchingService(kIOMainPortDefault, matching);
    if (!service_) {
        say("host: ReimsPCIProbe service not found (boot with reimspci=12)");
        return false;
    }
    IOReturn kr = IOServiceOpen(service_, mach_task_self(), 2, &session_);
    if (kr != kIOReturnSuccess) {
        say("host: opening session client (type 2) failed: 0x%08x", kr);
        return false;
    }
    kr = IOServiceOpen(service_, mach_task_self(), 1, &transport_);
    if (kr != kIOReturnSuccess) {
        say("host: opening transport client (type 1) failed: 0x%08x", kr);
        return false;
    }
    mach_vm_address_t address = 0;
    barLength_ = kBarSize;
    kr = IOConnectMapMemory64(session_, 0, mach_task_self(), &address, &barLength_, 0);
    if (kr != kIOReturnSuccess) {
        say("host: mapping the shared BAR0 page failed: 0x%08x", kr);
        return false;
    }
    bar_ = reinterpret_cast<uint8_t *>(address);
    say("host: bridge clients open, BAR0 page at %p (%llu bytes)", bar_,
        static_cast<unsigned long long>(barLength_));
    return true;
}

void BridgeClient::close() {
    if (bar_) {
        IOConnectUnmapMemory64(session_, 0, mach_task_self(),
                               reinterpret_cast<mach_vm_address_t>(bar_));
        bar_ = nullptr;
    }
    if (transport_) {
        IOServiceClose(transport_);
        transport_ = 0;
    }
    if (session_) {
        IOServiceClose(session_); // disarms the bridge
        session_ = 0;
    }
    if (service_) {
        IOObjectRelease(service_);
        service_ = 0;
    }
}

// ---------------------------------------------------------------------------
// Reims backend and the host state shared by the callbacks
// ---------------------------------------------------------------------------
struct TaskRecord {
    void *handle = nullptr;
    mach_vm_address_t base = 0;
    uint64_t size = 0;
};

struct PhysicalRecord {
    uint64_t target = 0;
    uint64_t length = 0;
};

struct Host {
    BridgeClient bridge;
    RvgDevice *device = nullptr;
    // No global MMIO lock: Reims documents that every function may be called
    // from any host thread, and a blocked root-FIFO write must never block the
    // dispatcher reads the kernel is waiting on.
    std::atomic<bool> running{true};
    std::atomic<bool> fatal{false};
    std::atomic<uint32_t> irqPending{0};
    std::atomic<uint64_t> lastWriteMs{0};      // monotonic, for the watchdog
    std::atomic<uint64_t> writesApplied{0};
    std::atomic<uint64_t> irqLogs{0};

    std::mutex taskMutex;
    std::vector<TaskRecord> tasks;
    std::mutex mapMutex;
    std::vector<PhysicalRecord> maps;

    std::atomic<uint64_t> mmioRequests{0};
    std::atomic<uint64_t> interruptsRaised{0};
    std::atomic<uint64_t> mapCallbacks{0};
    std::atomic<uint64_t> mapFailures{0};

    bool begin() { return true; }
    void end() {}
};

Host gHost;
bool gNoGuestWrites = false;

// Panel path (Reims display -> XeGfx scanout). Disabled unless --display.
bool gDisplayEnabled = false;
e16::PanelClient gPanel;
e16::DisplayPipeline gDisplay;
std::thread gDisplayThread;

uint64_t monotonicMs() {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return static_cast<uint64_t>(now.tv_sec) * 1000 + static_cast<uint64_t>(now.tv_nsec) / 1000000;
}
uint32_t mmioRead(uint64_t offset) { return rvg_device_mmio_read(gHost.device, offset); }
void mmioWrite(uint64_t offset, uint32_t value) { rvg_device_mmio_write(gHost.device, offset, value); }

// ---------------------------------------------------------------------------
// Reims callbacks. They run on Reims threads; none of them blocks a Reims
// worker on the main thread.
// ---------------------------------------------------------------------------
void cbLog(void *, RvgLogLevel level, const char *target, size_t targetLength, const char *message,
           size_t messageLength) {
    static std::atomic<uint64_t> lines{0};
    const uint64_t count = lines.fetch_add(1, std::memory_order_relaxed) + 1;
    // A malformed FIFO can make the library log hundreds of thousands of lines
    // a second; keep the first 300 and then a sample, so the report survives.
    if (count > 300 && (count % 8192) != 0)
        return;
    static const char *levels[] = {"error", "warn", "info", "debug"};
    const char *name = level < 4 ? levels[level] : "?";
    if (count == 301)
        say("host: Reims log spam follows; sampling every 8192nd line");
    say("reims[%s] %.*s: %.*s", name, static_cast<int>(targetLength), target,
        static_cast<int>(messageLength), message);
}

void cbDestroy(void *) { say("host: Reims destroy callback"); }

void *cbCreateTask(void *, uint64_t vmSize, void **baseOut) {
    mach_vm_address_t address = 0;
    kern_return_t kr = mach_vm_allocate(mach_task_self(), &address, vmSize, VM_FLAGS_ANYWHERE);
    if (kr != KERN_SUCCESS) {
        say("host: create_task: mach_vm_allocate(%llu) failed 0x%x",
            static_cast<unsigned long long>(vmSize), kr);
        return nullptr;
    }
    *baseOut = reinterpret_cast<void *>(address);
    TaskRecord record{reinterpret_cast<void *>(address), address, vmSize};
    {
        std::lock_guard<std::mutex> lock(gHost.taskMutex);
        gHost.tasks.push_back(record);
    }
    say("host: create_task size 0x%llx -> base 0x%llx", static_cast<unsigned long long>(vmSize),
        static_cast<unsigned long long>(address));
    return reinterpret_cast<void *>(address);
}

void cbDestroyTask(void *, void *task) {
    mach_vm_address_t base = reinterpret_cast<mach_vm_address_t>(task);
    uint64_t size = 0;
    {
        std::lock_guard<std::mutex> lock(gHost.taskMutex);
        for (size_t i = 0; i < gHost.tasks.size(); ++i) {
            if (gHost.tasks[i].handle == task) {
                base = gHost.tasks[i].base;
                size = gHost.tasks[i].size;
                gHost.tasks.erase(gHost.tasks.begin() + static_cast<std::ptrdiff_t>(i));
                break;
            }
        }
    }
    if (size)
        mach_vm_deallocate(mach_task_self(), base, size);
    say("host: destroy_task %p (deallocated 0x%llx)", task,
        static_cast<unsigned long long>(size));
}

bool cbMapMemory(void *, void *task, uint32_t rangeCount, uint64_t virtualOffset, bool readOnly,
                 const RvgPhysicalMemoryRange *ranges) {
    const auto base = reinterpret_cast<mach_vm_address_t>(task);
    uint64_t cursor = virtualOffset;
    ++gHost.mapCallbacks;
    for (uint32_t i = 0; i < rangeCount; ++i) {
        const uint64_t target = base + cursor;
        const IOReturn kr =
            gHost.bridge.mapPhysical(ranges[i].physical_address, ranges[i].physical_length, target);
        if (kr != kIOReturnSuccess) {
            ++gHost.mapFailures;
            gHost.fatal.store(true, std::memory_order_release);
            say("host: FATAL map_memory[%u]: gpa 0x%llx len 0x%llx -> 0x%llx failed 0x%08x; "
                "the guest would read unwritten FIFO memory, so the writer stops",
                i, static_cast<unsigned long long>(ranges[i].physical_address),
                static_cast<unsigned long long>(ranges[i].physical_length),
                static_cast<unsigned long long>(target), kr);
            return false;
        }
        {
            std::lock_guard<std::mutex> lock(gHost.mapMutex);
            gHost.maps.push_back({target, ranges[i].physical_length});
        }
        say("host: map_memory[%u]: gpa 0x%llx len 0x%llx -> 0x%llx (read_only=%d)", i,
            static_cast<unsigned long long>(ranges[i].physical_address),
            static_cast<unsigned long long>(ranges[i].physical_length),
            static_cast<unsigned long long>(target), readOnly ? 1 : 0);
        cursor += ranges[i].physical_length;
    }
    return true;
}

bool cbUnmapMemory(void *, void *task, uint64_t virtualOffset, uint64_t length) {
    const auto base = reinterpret_cast<mach_vm_address_t>(task);
    const uint64_t target = base + virtualOffset;
    const IOReturn kr = gHost.bridge.unmapPhysical(target, length);
    {
        std::lock_guard<std::mutex> lock(gHost.mapMutex);
        for (size_t i = 0; i < gHost.maps.size(); ++i) {
            if (gHost.maps[i].target == target) {
                gHost.maps.erase(gHost.maps.begin() + static_cast<std::ptrdiff_t>(i));
                break;
            }
        }
    }
    say("host: unmap_memory 0x%llx len 0x%llx -> 0x%08x", static_cast<unsigned long long>(target),
        static_cast<unsigned long long>(length), kr);
    return kr == kIOReturnSuccess;
}

void cbRaiseInterrupt(void *, uint32_t vector) {
    if (vector != 0) {
        say("host: unexpected interrupt vector %u", vector);
        return;
    }
    gHost.irqPending.store(1, std::memory_order_release);
}

// ---------------------------------------------------------------------------
// Threads
// ---------------------------------------------------------------------------
void transportThread() {
    while (gHost.running.load(std::memory_order_acquire)) {
        uint64_t request[4] = {};
        uint32_t count = 0;
        const IOReturn kr = gHost.bridge.fetchMmio(request, count);
        if (kr == kIoNotReady) {
            usleep(50);
            continue;
        }
        if (kr != kIOReturnSuccess) {
            say("host: transport fetch failed 0x%08x", kr);
            break;
        }
        if (count != 4) {
            say("host: transport fetch returned %u words", count);
            break;
        }
        const uint64_t sequence = request[0];
        const uint64_t operation = request[1];
        const uint64_t offset = request[2];
        const uint64_t value = request[3];
        ++gHost.mmioRequests;
        uint64_t reply[3] = {sequence, 1, 0};
        if (offset < kBarSize && (offset & 3) == 0) {
            if (operation == 0) {
                reply[1] = 0;
                reply[2] = mmioRead(offset);
            } else if (operation == 1 && value <= 0xffffffffu) {
                mmioWrite(offset, static_cast<uint32_t>(value));
                reply[1] = 0;
            }
        }
        const IOReturn done = gHost.bridge.completeMmio(reply);
        if (done != kIOReturnSuccess) {
            say("host: transport completion failed 0x%08x", done);
            break;
        }
    }
}

void irqThread() {
    while (gHost.running.load(std::memory_order_acquire)) {
        if (!gHost.irqPending.exchange(0, std::memory_order_acq_rel)) {
            usleep(500);
            continue;
        }
        const IOReturn kr = gHost.bridge.raiseInterrupt();
        if (kr == kIOReturnSuccess) {
            const uint64_t count = gHost.interruptsRaised.fetch_add(1) + 1;
            if (count <= 40 || (count % 500) == 0)
                say("host: IRQ0 delivered to the kernel (%llu)",
                    static_cast<unsigned long long>(count));
        } else {
            say("host: IRQ0 delivery failed 0x%08x (no handler or disabled)", kr);
        }
    }
}

// Registers Apple stores into the shared BAR0 page. The daemon applies them to
// the Reims device in this order: configuration before the FIFO enable, the
// FIFO doorbell after the configuration, the display doorbell last.
constexpr uint32_t kWriteOrder[] = {
    0x101c, 0x1030, 0x1004, 0x1010, 0x1034, 0x1038,
    0x1200, 0x1204, 0x1208, 0x120c, 0x1210, 0x1214, 0x1218, 0x121c, 0x1224, 0x1228,
    0x1000, 0x1020, 0x1024, 0x1028, 0x1008, 0x1220,
};

// The guest's register writes: a dedicated thread, in a fixed order, because a
// root-FIFO doorbell write may block in the library (it waits for the FIFO
// thread) and must not stall the dispatcher path the kernel is waiting on.
void writerThread() {
    uint32_t last[0x4000 / 4] = {};
    for (uint32_t offset : kWriteOrder)
        last[offset / 4] = gHost.bridge.cell(offset)[0];
    gHost.lastWriteMs.store(monotonicMs(), std::memory_order_release);
    while (gHost.running.load(std::memory_order_acquire)) {
        if (gHost.fatal.load(std::memory_order_acquire)) {
            say("host: writer stopped after a fatal mapping failure");
            return;
        }
        bool worked = false;
        for (uint32_t offset : kWriteOrder) {
            const uint32_t value = gHost.bridge.cell(offset)[0];
            if (value == last[offset / 4])
                continue;
            last[offset / 4] = value;
            if (gNoGuestWrites) {
                say("host: guest write 0x%x <- 0x%x NOT applied (--no-guest-writes)", offset, value);
                continue;
            }
            mmioWrite(offset, value);
            gHost.writesApplied.fetch_add(1, std::memory_order_relaxed);
            gHost.lastWriteMs.store(monotonicMs(), std::memory_order_release);
            worked = true;
        }
        if (!worked)
            usleep(60);
    }
}

// The registers Reims owns and the guest reads as plain memory: the FIFO read
// cursor (polled in writeFifo's spin loop) and the persistent fault flag.
// Reading these is lock-free in Reims and never clears an interrupt bitmap.
void publisherThread() {
    while (gHost.running.load(std::memory_order_acquire)) {
        gHost.bridge.cell(kCellFifoRead)[0] = mmioRead(kCellFifoRead);
        gHost.bridge.cell(kCellFault)[0] = mmioRead(kCellFault);
        usleep(80);
    }
}

void displayThread() {
    while (gHost.running.load(std::memory_order_acquire)) {
        const bool sent = e16::displayFrame(gDisplay);
        usleep(sent ? 1000 : 4000);
    }
}

} // namespace

int main(int argc, char **argv) {
    uint64_t registryId = 0;
    unsigned seconds = 30;
    uint32_t portCount = 1;
    bool noArm = false;
    bool noPublish = false;   // open the bridge + create the device, but never arm (Apple never matches)
    bool noGuestWrites = false; // arm, but do not apply the guest's register writes to Reims
    bool displayRequired = false;
    const char *panelService = "NMXAccel";
    uint32_t panelType = 0x58474452u;
    const char *logPath = nullptr;

    for (int i = 1; i < argc; ++i) {
        const char *arg = argv[i];
        auto next = [&]() -> const char * { return i + 1 < argc ? argv[++i] : nullptr; };
        if (!std::strcmp(arg, "--registry-id")) {
            const char *value = next();
            if (!value) {
                say("--registry-id needs a value");
                return 2;
            }
            registryId = std::strtoull(value, nullptr, 0);
        } else if (!std::strcmp(arg, "--seconds")) {
            const char *value = next();
            seconds = value ? static_cast<unsigned>(std::strtoul(value, nullptr, 0)) : 30;
        } else if (!std::strcmp(arg, "--port-count")) {
            const char *value = next();
            portCount = value ? static_cast<uint32_t>(std::strtoul(value, nullptr, 0)) : 1;
        } else if (!std::strcmp(arg, "--display")) {
            gDisplayEnabled = true;
        } else if (!std::strcmp(arg, "--display-required")) {
            gDisplayEnabled = true;
            displayRequired = true;
        } else if (!std::strcmp(arg, "--panel-service")) {
            panelService = next();
            if (!panelService)
                return 2;
        } else if (!std::strcmp(arg, "--panel-type")) {
            const char *value = next();
            panelType = value ? static_cast<uint32_t>(std::strtoul(value, nullptr, 0)) : 0;
        } else if (!std::strcmp(arg, "--no-arm")) {
            noArm = true;
        } else if (!std::strcmp(arg, "--no-publish")) {
            noPublish = true;
        } else if (!std::strcmp(arg, "--no-guest-writes")) {
            noGuestWrites = true;
        } else if (!std::strcmp(arg, "--log")) {
            logPath = next();
        } else if (!std::strcmp(arg, "--help")) {
            say("usage: apv-host [--registry-id N] [--seconds N] [--port-count N] "
                "[--display] [--display-required] [--panel-service NMXAccel] "
                "[--panel-type 0x58474452] [--no-arm] [--log FILE]");
            return 0;
        } else {
            say("unknown argument: %s", arg);
            return 2;
        }
    }
    if (logPath) {
        gLogFile = std::fopen(logPath, "w");
        if (!gLogFile)
            say("host: cannot open log file %s (%s)", logPath, std::strerror(errno));
    }
    if (!gHost.begin()) {
        say("host: sem_init failed");
        return 1;
    }
    rvg_log_set_handler(cbLog, nullptr, 3);

    gNoGuestWrites = noGuestWrites;
    if (!noArm) {
        if (!gHost.bridge.open())
            return 1;
        gHost.bridge.cell(kCellDisplayPortCount)[0] = portCount;
        gHost.bridge.cell(kCellDisplayConnectionTypes)[0] = 0;
        say("host: BAR0 cells pre-filled: display port count %u", portCount);
    } else {
        say("host: --no-arm: no kernel bridge; only the Reims device is exercised");
    }

    RvgHostCallbacks callbacks = {};
    callbacks.struct_size = sizeof(RvgHostCallbacks);
    callbacks.ctx = &gHost;
    callbacks.destroy = cbDestroy;
    callbacks.create_task = cbCreateTask;
    callbacks.destroy_task = cbDestroyTask;
    callbacks.map_memory = cbMapMemory;
    callbacks.unmap_memory = cbUnmapMemory;
    callbacks.read_memory = nullptr;
    callbacks.raise_interrupt = cbRaiseInterrupt;

    RvgDeviceConfig config = {};
    config.struct_size = sizeof(RvgDeviceConfig);
    config.display_port_count = portCount;
    config.metal_registry_id = registryId;
    config.feature_level = 0;
    config.display_port_connection_types = 0;
    config.use_iosurface_mapper = false;
    config.process_isolation = false;
    config.disable_argument_buffers = false;
    config.memory_map = nullptr;
    config.callbacks = &callbacks;

    RvgStatus status = rvg_device_create(&config, &gHost.device);
    if (status != RVG_OK || !gHost.device) {
        say("host: rvg_device_create failed: %u (%s)", status, rvg_status_message(status));
        return 1;
    }
    say("host: Reims device created (registry id 0x%llx, %u display port(s))",
        static_cast<unsigned long long>(registryId), portCount);

    if (gDisplayEnabled) {
        if (gPanel.open(panelService, panelType)) {
            if (!gPanel.acquire())
                say("host: panel ACQUIRE refused (another producer owns the panel?)");
            char why[160] = {};
            if (e16::displayStart(gDisplay, gHost.device, &gPanel, why, sizeof(why))) {
                say("host: display path active (Reims display -> XeGfx panel)");
                gDisplayThread = std::thread(displayThread);
            } else {
                const std::string message = std::string("display path unavailable: ") + why;
                say("host: %s", message.c_str());
                if (displayRequired) {
                    say("host: --display-required given, aborting");
                    rvg_device_release(gHost.device);
                    return 1;
                }
            }
        } else {
            say("host: XeGfx panel interface unavailable (%s); run the patched XeGfxAccel "
                "kext and XeGfx, or omit --display", panelService);
            if (displayRequired)
                return 1;
        }
    }

    std::thread transport;
    std::thread irq;
    std::thread writer;
    std::thread publisher;
    if (!noArm) {
        transport = std::thread(transportThread);
        irq = std::thread(irqThread);
        writer = std::thread(writerThread);
        publisher = std::thread(publisherThread);
    } else {
        // No kernel bridge: exercise the same MMIO wrapper the bridge would use
        // so this mode still proves device creation and register access.
        mmioWrite(0x1034, 6);
        const uint32_t version = mmioRead(0x1034);
        const uint32_t ports = mmioRead(0x122c);
        say("host: self-check version=0x%x display_port_count=%u (expect 0x6 and 1)", version,
            ports);
    }

    if (!noArm && noPublish) {
        say("host: --no-publish: bridge opened and device created; NOT arming (Apple never matches)");
    } else if (!noArm) {
        const IOReturn kr = gHost.bridge.arm();
        if (kr != kIOReturnSuccess) {
            say("host: arming the bridge failed: 0x%08x", kr);
        } else {
            say("host: bridge armed; AppleParavirtGPU is being matched and started");
        }
    }

    unsigned stalled = 0;
    for (unsigned elapsed = 0; elapsed < seconds * 10; ++elapsed) {
        usleep(100 * 1000);
        // Watchdog: the writer thread may be inside a library write that waits
        // for the FIFO thread. If that never returns, report and end instead of
        // hanging the session.
        if (!noArm && gHost.writesApplied.load(std::memory_order_relaxed) > 0 &&
            monotonicMs() - gHost.lastWriteMs.load(std::memory_order_acquire) > 10000) {
            ++stalled;
            say("host: WATCHDOG: the writer has been blocked in a Reims write for >%us",
                stalled * 5);
            if (stalled >= 2) {
                say("host: giving up on the blocked Reims write; the kernel session will time out");
                std::fflush(nullptr);
                _exit(4);
            }
        } else {
            stalled = 0;
        }
        if (elapsed % 50 == 49) {
            say("host: alive %us: mmio=%llu irq=%llu maps=%llu(map fail %llu)", elapsed / 10 + 1,
                static_cast<unsigned long long>(gHost.mmioRequests.load()),
                static_cast<unsigned long long>(gHost.interruptsRaised.load()),
                static_cast<unsigned long long>(gHost.mapCallbacks.load()),
                static_cast<unsigned long long>(gHost.mapFailures.load()));
        }
    }

    if (!noArm) {
        uint64_t stats[4] = {};
        if (gHost.bridge.statistics(stats)) {
            say("host: kernel bridge stats: dispatch=%llu dispatch_failures=%llu patched=%llu "
                "bar_bases=%llu",
                static_cast<unsigned long long>(stats[0]), static_cast<unsigned long long>(stats[1]),
                static_cast<unsigned long long>(stats[2]), static_cast<unsigned long long>(stats[3]));
        } else {
            say("host: kernel bridge statistics unavailable");
        }
    }
    say("host: stopping");
    gHost.running.store(false, std::memory_order_release);
    if (!noArm) {
        gHost.bridge.close();
    }
    if (transport.joinable())
        transport.join();
    if (irq.joinable())
        irq.join();
    if (writer.joinable())
        writer.join();
    if (publisher.joinable())
        publisher.join();
    if (gDisplayThread.joinable())
        gDisplayThread.join();
    if (gDisplayEnabled)
        e16::displayStop(gDisplay);
    if (gHost.device) {
        rvg_device_release(gHost.device);
        gHost.device = nullptr;
    }
    say("host: teardown complete: mmio=%llu irq=%llu maps=%llu map_failures=%llu",
        static_cast<unsigned long long>(gHost.mmioRequests.load()),
        static_cast<unsigned long long>(gHost.interruptsRaised.load()),
        static_cast<unsigned long long>(gHost.mapCallbacks.load()),
        static_cast<unsigned long long>(gHost.mapFailures.load()));
    gHost.end();
    if (gLogFile)
        std::fclose(gLogFile);
    return 0;
}
