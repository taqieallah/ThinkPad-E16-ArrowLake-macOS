// ReimsAPVBridge 0.3.2 — live AppleParavirtGPU <-> Reims bridge for the ThinkPad E16.
//
// Modes (boot argument reimspci=<n>); the 0.1.x diagnostic modes are kept:
//   1  control service only
//   3  attach-only nub
//   5  publish the vendor-specific nub (no Apple match)
//   6  Apple personality match, shared RAM BAR0
//   7  Apple match, refuse the BAR0 map (marker property)
//   8  Apple match, self-test map and read, then refuse
//   9  Apple match, allow only the first BAR0 map
//   10 diagnostic relay (fixed request, no Apple)
//   11 scalar MMIO transport service (no Apple match)
//   12 LIVE BRIDGE: control service only at boot. A console-session daemon
//      opens the session client, maps the shared BAR0 page, creates the real
//      Reims device and arms the bridge; only then is the nub published and
//      Apple's driver matched. The first BAR0 map inside Apple's setupMMIO
//      validates and patches the audited inline BAR0 sites (kext/sites.json),
//      and every intercepted access is served by the daemon through the type-1
//      client.
//
// Safety rules enforced here:
//   * nothing is patched before the daemon has claimed the session;
//   * every site's image UUID and original bytes are verified first, and a
//     failure leaves the image untouched (all-or-nothing);
//   * the dispatcher answers 0 and refuses to sleep for a call from a
//     non-sleepable context, from a BAR base it did not create, or when the
//     session is not being served;
//   * a timed-out transfer poisons the session instead of replaying a write.
#include <IOKit/IOBufferMemoryDescriptor.h>
#include <IOKit/IODeviceMemory.h>
#include <IOKit/IOLib.h>
#include <IOKit/IOLocks.h>
#include <IOKit/IOMemoryDescriptor.h>
#include <IOKit/IOUserClient.h>
#include <IOKit/pci/IOPCIDevice.h>
#include <kern/clock.h>
#include <libkern/c++/OSArray.h>
#include <libkern/c++/OSData.h>
#include <libkern/c++/OSDictionary.h>
#include <libkern/c++/OSString.h>
#include <pexpert/pexpert.h>

#include "MMIOTransaction.hpp"
#include "SiteTable.hpp"

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------
namespace {

constexpr UInt32 kPCIId = 0xeeee106b;
constexpr UInt32 kDisplayPCIClass = 0x038000;
constexpr UInt32 kVendorSpecificPCIClass = 0xff0000;
constexpr IOByteCount kBARSize = 0x4000;
constexpr UInt8 kBARRegister = 0x10;
constexpr UInt32 kMaxLiveMaps = 8;
constexpr UInt32 kMaxPhysicalMaps = 64;
constexpr UInt64 kMaxPhysicalMapLength = 128ULL * 1024 * 1024;
constexpr UInt32 kTransportTimeoutMs = 100;

enum ProbeMode {
    kControlMode = 1,
    kAttachOnlyMode = 3,
    kPublishVendorSpecificMode = 5,
    kMatchAppleMode = 6,
    kDenyBARMappingMode = 7,
    kTestBARMappingMode = 8,
    kFirstBARMappingMode = 9,
    kRelayMode = 10,
    kMMIOBridgeMode = 11,
    kLiveBridgeMode = 12,
};

int gMode = 0;
// Diagnostic switches, parsed from the same boot-arg set (whitespace separated).
//   apvpatch=0  : arm the bridge but do not patch Apple's text (isolates the fake
//                 PCI device / Apple start path from the patch machinery)
//   apvdsp=0    : patch, but the dispatcher answers 0 immediately without ever
//                 sleeping (isolates the patch machinery from the transport sleep)
int gPatchEnabled = 1;
int gDispatchSleepAllowed = 1;

bool publishesLegacyNub(int probeMode) {
    return probeMode == kPublishVendorSpecificMode;
}
bool allowsAppleMatch(int probeMode) {
    return probeMode == kMatchAppleMode || probeMode == kDenyBARMappingMode ||
           probeMode == kTestBARMappingMode || probeMode == kFirstBARMappingMode ||
           probeMode == kLiveBridgeMode;
}
UInt32 pciClassForMode() {
    return allowsAppleMatch(gMode) || publishesLegacyNub(gMode) ? kVendorSpecificPCIClass
                                                               : kDisplayPCIClass;
}
bool matchesString(OSDictionary *table, const char *key, const char *value) {
    auto string = OSDynamicCast(OSString, table->getObject(key));
    return string && string->isEqualTo(value);
}

} // namespace

// ---------------------------------------------------------------------------
// CPU helpers
// ---------------------------------------------------------------------------
namespace {

constexpr UInt64 kCr0WriteProtect = 1ULL << 16;

inline UInt64 readCr0() {
    UInt64 value;
    __asm__ __volatile__("mov %%cr0, %0" : "=r"(value));
    return value;
}
inline void writeCr0(UInt64 value) {
    __asm__ __volatile__("mov %0, %%cr0" : : "r"(value) : "memory");
}
inline void flushLine(void *address) {
    __asm__ __volatile__("clflush (%0)" : : "r"(address) : "memory");
}
inline void memoryBarrier() { __asm__ __volatile__("mfence" : : : "memory"); }
inline UInt64 readRflags() {
    UInt64 flags;
    __asm__ __volatile__("pushfq; pop %0" : "=r"(flags));
    return flags;
}
inline void writeRflags(UInt64 flags) {
    __asm__ __volatile__("push %0; popfq" : : "r"(flags) : "memory", "cc");
}

// A CLI context can never block: the dispatcher answers 0 instead of stalling.
inline bool sleepableContext() { return (readRflags() & 0x200ULL) != 0; }

struct TextWriteWindow {
    UInt64 cr0 = 0;
    UInt64 rflags = 0;
    bool open = false;
    void begin() {
        if (open)
            return;
        rflags = readRflags();
        __asm__ __volatile__("cli" : : : "memory");
        cr0 = readCr0();
        writeCr0(cr0 & ~kCr0WriteProtect);
        open = true;
    }
    void end() {
        if (!open)
            return;
        writeCr0(cr0);
        writeRflags(rflags);
        open = false;
    }
};

void writeText(void *destination, const void *source, size_t length) {
    auto *dst = static_cast<UInt8 *>(destination);
    auto *src = static_cast<const UInt8 *>(source);
    for (size_t i = 0; i < length; ++i)
        dst[i] = src[i];
    for (size_t i = 0; i < length; i += 64)
        flushLine(dst + i);
    memoryBarrier();
}

} // namespace

// ---------------------------------------------------------------------------
// Loaded-image validation
// ---------------------------------------------------------------------------
namespace {

struct MachHeader64 {
    UInt32 magic;
    UInt32 cputype;
    UInt32 cpusubtype;
    UInt32 filetype;
    UInt32 ncmds;
    UInt32 sizeofcmds;
    UInt32 flags;
    UInt32 reserved;
};
struct LoadCommand64 {
    UInt32 cmd;
    UInt32 cmdsize;
};
struct SegmentCommand64 {
    UInt32 cmd;
    UInt32 cmdsize;
    char segname[16];
    UInt64 vmaddr;
    UInt64 vmsize;
    UInt64 fileoff;
    UInt64 filesize;
    UInt32 maxprot;
    UInt32 initprot;
    UInt32 nsects;
    UInt32 flags;
};
struct UuidCommand64 {
    UInt32 cmd;
    UInt32 cmdsize;
    UInt8 uuid[16];
};

constexpr UInt32 kMachMagic64 = 0xfeedfacf;
constexpr UInt32 kCpuTypeX8664 = 0x01000007;
constexpr UInt32 kMachFileTypeKextBundle = 11;
constexpr UInt32 kLcSegment64 = 0x19;
constexpr UInt32 kLcUuid = 0x1b;
constexpr UInt8 kApvUuid[16] = {0x0c, 0xae, 0x9e, 0x29, 0xbc, 0x33, 0x31, 0x5d,
                               0x82, 0xa7, 0xa7, 0xd3, 0x0e, 0x9b, 0x97, 0x1e};
constexpr UInt64 kHeaderScanLimit = 0x40000;

struct ApvImage {
    UInt64 base;
    UInt64 textSize;
};

bool uuidMatches(const MachHeader64 *header) {
    const auto *bytes = reinterpret_cast<const UInt8 *>(header);
    const UInt32 ncmds = header->ncmds;
    if (ncmds == 0 || ncmds > 256)
        return false;
    UInt64 offset = sizeof(MachHeader64);
    const UInt64 limit = sizeof(MachHeader64) + header->sizeofcmds;
    bool sawUuid = false;
    for (UInt32 i = 0; i < ncmds; ++i) {
        if (offset + sizeof(LoadCommand64) > limit)
            return false;
        const auto *command = reinterpret_cast<const LoadCommand64 *>(bytes + offset);
        if (command->cmdsize < sizeof(LoadCommand64) || (command->cmdsize & 3u) != 0)
            return false;
        if (command->cmd == kLcUuid && command->cmdsize == sizeof(UuidCommand64)) {
            const auto *uuid = reinterpret_cast<const UuidCommand64 *>(command);
            for (unsigned b = 0; b < 16; ++b) {
                if (uuid->uuid[b] != kApvUuid[b])
                    return false;
            }
            sawUuid = true;
        }
        offset += command->cmdsize;
    }
    return sawUuid;
}

bool textSegment(const MachHeader64 *header, UInt64 *fileSize) {
    const auto *bytes = reinterpret_cast<const UInt8 *>(header);
    UInt64 offset = sizeof(MachHeader64);
    for (UInt32 i = 0; i < header->ncmds; ++i) {
        const auto *command = reinterpret_cast<const LoadCommand64 *>(bytes + offset);
        if (command->cmdsize < sizeof(LoadCommand64) || (command->cmdsize & 3u) != 0)
            return false;
        if (command->cmd == kLcSegment64 && command->cmdsize >= sizeof(SegmentCommand64)) {
            const auto *segment = reinterpret_cast<const SegmentCommand64 *>(command);
            const char expected[] = "__TEXT";
            bool isText = true;
            for (unsigned c = 0; c < 16; ++c) {
                const char want = c < 6 ? expected[c] : 0;
                if (segment->segname[c] != want) {
                    isText = false;
                    break;
                }
            }
            if (isText) {
                if (segment->fileoff != 0 || segment->filesize < 0x1000)
                    return false;
                *fileSize = segment->filesize;
                return true;
            }
        }
        offset += command->cmdsize;
    }
    return false;
}

// From a return address inside Apple's text, walk back to the page-aligned
// Mach-O header and validate image identity. Nothing is read beyond the
// bounded scan and no candidate is trusted without the UUID check.
bool findApvImage(UInt64 callerReturnAddress, ApvImage &out) {
    UInt64 page = callerReturnAddress & ~0xfffULL;
    for (UInt64 scanned = 0; scanned < kHeaderScanLimit; scanned += 0x1000) {
        const auto *header = reinterpret_cast<const MachHeader64 *>(page);
        if (header->magic == kMachMagic64 && header->cputype == kCpuTypeX8664 &&
            header->filetype == kMachFileTypeKextBundle && uuidMatches(header)) {
            UInt64 textSize = 0;
            if (textSegment(header, &textSize)) {
                out.base = page;
                out.textSize = textSize;
                return true;
            }
        }
        if (page == 0)
            break;
        page -= 0x1000;
    }
    return false;
}

} // namespace

// ---------------------------------------------------------------------------
// Misc forward declarations and live state
// ---------------------------------------------------------------------------
class ReimsPCIProbe;
class ReimsAPVNub;
class ReimsMMIOClient;
class ReimsSessionClient;

namespace {

struct LiveState {
    volatile UInt32 armed;
    volatile UInt32 ready;
    volatile UInt32 patched;
    volatile UInt32 patchFailed;
    UInt64 apvBase;
    UInt64 regBases[kMaxLiveMaps];
    UInt32 regBaseCount;
    volatile UInt32 dispatchCalls;
    volatile UInt32 dispatchFailures;
};

LiveState gLive = {};

ReimsPCIProbe *gBridge = nullptr;
ReimsAPVNub *gNub = nullptr;
ReimsMMIOClient *gTransport = nullptr;
ReimsSessionClient *gSession = nullptr;
IOBufferMemoryDescriptor *gBarBacking = nullptr;
IOLock *gMapLock = nullptr;

// Stub code lives in a dedicated __TEXT section: executable, never writable in
// normal operation, written once under the kernel text write window before any
// site points at it.
UInt8 gStubArea[e16::kSiteTableCount * e16::kStubCapacity]
    __attribute__((section("__TEXT,__apvstubs"), used, aligned(64)));

struct PhysicalMapping {
    UInt64 targetAddress;
    UInt64 length;
    IOMemoryMap *map;
};
PhysicalMapping gPhysicalMaps[kMaxPhysicalMaps] = {};
UInt32 gPhysicalMapCount = 0;

} // namespace

// ---------------------------------------------------------------------------
// Dispatcher, called from the patched Apple call sites through the stubs.
// ---------------------------------------------------------------------------
extern "C" UInt32 e16_apv_dispatch(UInt32 siteId, UInt64 barBase, UInt32 value);


// ---------------------------------------------------------------------------
// Patch application
// ---------------------------------------------------------------------------
namespace {

void markStage(ReimsPCIProbe *bridge, const char *stage);

void recordRegBase(IOMemoryMap *map) {
    if (!map || !gMapLock)
        return;
    const UInt64 base = map->getVirtualAddress() + 0x1000;
    bool duplicate = false;
    IOLockLock(gMapLock);
    for (UInt32 i = 0; i < gLive.regBaseCount; ++i) {
        if (gLive.regBases[i] == base) {
            duplicate = true;
            break;
        }
    }
    if (!duplicate && gLive.regBaseCount < kMaxLiveMaps)
        gLive.regBases[gLive.regBaseCount++] = base;
    IOLockUnlock(gMapLock);
    if (!duplicate)
        IOLog("ReimsAPVBridge: BAR register base 0x%llx registered\n",
              static_cast<unsigned long long>(base));
}

// All-or-nothing patch application. The caller is inside Apple's setupMMIO,
// immediately after the BAR map: no other Apple thread has reached the sites
// yet, and the patched functions are different from the one on the stack.
bool applyLivePatches(ReimsPCIProbe *bridge, UInt64 callerReturnAddress) {
    ApvImage image = {};
    if (!findApvImage(callerReturnAddress, image)) {
        __atomic_store_n(&gLive.patchFailed, 1, __ATOMIC_RELEASE);
        markStage(bridge, "patch-no-apv-image");
        IOLog("ReimsAPVBridge: patch refused: no AppleParavirtGPU image at 0x%llx\n",
              static_cast<unsigned long long>(callerReturnAddress));
        return false;
    }

    for (size_t i = 0; i < e16::kSiteTableCount; ++i) {
        const e16::SiteSpec &site = e16::kSiteTable[i];
        if (static_cast<UInt64>(site.text_offset) + site.span > image.textSize) {
            __atomic_store_n(&gLive.patchFailed, 1, __ATOMIC_RELEASE);
            markStage(bridge, "patch-site-out-of-range");
            IOLog("ReimsAPVBridge: patch refused: site %u outside __TEXT\n", site.id);
            return false;
        }
        const auto *bytes = reinterpret_cast<const UInt8 *>(image.base + site.text_offset);
        for (size_t b = 0; b < site.span; ++b) {
            if (bytes[b] != site.original[b]) {
                __atomic_store_n(&gLive.patchFailed, 1, __ATOMIC_RELEASE);
                markStage(bridge, "patch-byte-mismatch");
                IOLog("ReimsAPVBridge: patch refused: site %u byte %u is 0x%02x, want 0x%02x\n",
                      site.id, static_cast<unsigned>(b), bytes[b], site.original[b]);
                return false;
            }
        }
    }

    TextWriteWindow window;
    window.begin();

    size_t written = 0;
    for (size_t i = 0; i < e16::kSiteTableCount; ++i) {
        const e16::SiteSpec &site = e16::kSiteTable[i];
        auto *slot = gStubArea + i * e16::kStubCapacity;
        const UInt64 slotAddress = reinterpret_cast<UInt64>(slot);
        const UInt64 continuation = image.base + site.continuation;
        const UInt64 branchTarget = image.base + site.branch_target;
        size_t stubLength = 0;
        if (!e16::buildStub(site, reinterpret_cast<UInt64>(&e16_apv_dispatch), continuation,
                            branchTarget, slot, e16::kStubCapacity, stubLength)) {
            window.end();
            __atomic_store_n(&gLive.patchFailed, 1, __ATOMIC_RELEASE);
            markStage(bridge, "stub-generation-failed");
            IOLog("ReimsAPVBridge: stub generation failed for site %u\n", site.id);
            return false;
        }
        for (size_t f = 0; f < stubLength; f += 64)
            flushLine(slot + f);
        memoryBarrier();

        UInt8 patch[e16::kPatchCapacity] = {};
        size_t patchLength = 0;
        if (!e16::buildPatch(site, image.base + site.text_offset, slotAddress, patch,
                             sizeof(patch), patchLength)) {
            window.end();
            __atomic_store_n(&gLive.patchFailed, 1, __ATOMIC_RELEASE);
            markStage(bridge, "patch-out-of-range");
            IOLog("ReimsAPVBridge: site %u stub out of rel32 range\n", site.id);
            return false;
        }
        writeText(reinterpret_cast<void *>(image.base + site.text_offset), patch, patchLength);
        ++written;
    }

    window.end();

    // Read back through the normal mapping. A mismatch cannot be repaired
    // safely here, so the bridge reports failure and refuses every dispatch
    // (the site would call a stub, and the dispatcher is still gated).
    for (size_t i = 0; i < e16::kSiteTableCount; ++i) {
        const e16::SiteSpec &site = e16::kSiteTable[i];
        const auto *bytes = reinterpret_cast<const UInt8 *>(image.base + site.text_offset);
        if (bytes[0] != 0xE8) {
            __atomic_store_n(&gLive.patchFailed, 1, __ATOMIC_RELEASE);
            markStage(bridge, "patch-readback-failed");
            IOLog("ReimsAPVBridge: readback failed for site %u\n", site.id);
            return false;
        }
    }

    (void)written;
    gLive.apvBase = image.base;
    __atomic_store_n(&gLive.patched, 1, __ATOMIC_RELEASE);
    markStage(bridge, "patched");
    IOLog("ReimsAPVBridge: %u sites patched in AppleParavirtGPU at 0x%llx (__TEXT 0x%llx)\n",
          static_cast<unsigned>(e16::kSiteTableCount),
          static_cast<unsigned long long>(image.base),
          static_cast<unsigned long long>(image.textSize));
    return true;
}

} // namespace

// ---------------------------------------------------------------------------
// The fake PCI device
// ---------------------------------------------------------------------------
class ReimsAPVNub final : public IOPCIDevice {
    OSDeclareDefaultStructors(ReimsAPVNub)

public:
    bool configure(IOBufferMemoryDescriptor *backing, const char *name);
    void free() override;
    void detach(IOService *provider) override { IOService::detach(provider); }
    IOReturn getResources() override { return bar_ ? kIOReturnSuccess : kIOReturnNoResources; }
    bool matchPropertyTable(OSDictionary *table) override;
    bool matchPropertyTable(OSDictionary *table, SInt32 *score) override;
    IOReturn deliverInterrupt();

    UInt32 configRead32(IOPCIAddressSpace, UInt8 offset) override;
    UInt16 configRead16(IOPCIAddressSpace, UInt8 offset) override;
    UInt8 configRead8(IOPCIAddressSpace, UInt8 offset) override;
    void configWrite32(IOPCIAddressSpace, UInt8 offset, UInt32 value) override;
    void configWrite16(IOPCIAddressSpace, UInt8 offset, UInt16 value) override;
    void configWrite8(IOPCIAddressSpace, UInt8 offset, UInt8 value) override;
    UInt32 setConfigBits(UInt8 offset, UInt32 mask, UInt32 value) override;
    bool setMemoryEnable(bool enable) override {
        return setConfigBits(0x04, 2, enable ? 2 : 0) != 0;
    }
    bool setBusMasterEnable(bool enable) override {
        return setConfigBits(0x04, 4, enable ? 4 : 0) != 0;
    }
    bool setIOEnable(bool enable, bool) override {
        return setConfigBits(0x04, 1, enable ? 1 : 0) != 0;
    }
    // Apple's accelerator queries capability 5 (MSI) and refuses to configure
    // without it; the live bridge answers with a synthetic capability offset
    // because interrupts are delivered by the bridge itself.
    UInt32 findPCICapability(UInt8 capability, UInt8 *offset) override;
    UInt32 extendedFindPCICapability(UInt32, IOByteCount *) override { return 0; }
    IOReturn saveDeviceState(IOOptionBits) override { return kIOReturnUnsupported; }
    IOReturn restoreDeviceState(IOOptionBits) override { return kIOReturnUnsupported; }

    IODeviceMemory *getDeviceMemoryWithIndex(unsigned int index) override;
    IODeviceMemory *getDeviceMemoryWithRegister(UInt8 reg) override;
    IOMemoryMap *mapDeviceMemoryWithIndex(unsigned int index, IOOptionBits options) override;
    IOMemoryMap *mapDeviceMemoryWithRegister(UInt8 reg, IOOptionBits options) override;

    IOReturn getInterruptType(int source, int *type) override;
    IOReturn registerInterrupt(int source, OSObject *target, IOInterruptAction handler,
                               void *refcon) override;
    IOReturn unregisterInterrupt(int source) override;
    IOReturn enableInterrupt(int source) override;
    IOReturn disableInterrupt(int source) override;
    IOReturn causeInterrupt(int) override { return kIOReturnUnsupported; }

private:
    UInt32 readDword(UInt8 offset);
    void updateCommand(UInt32 mask, UInt32 value);

    IOBufferMemoryDescriptor *backing_ = nullptr;
    IODeviceMemory *bar_ = nullptr;
    UInt32 command_ = 0;
    volatile UInt32 irqRegistered_ = 0;
    volatile UInt32 irqEnabled_ = 0;
    OSObject *irqTarget_ = nullptr;
    IOInterruptAction irqHandler_ = nullptr;
    void *irqRefcon_ = nullptr;
    UInt32 barMapRequests_ = 0;
    IOMemoryMap *liveMaps_[kMaxLiveMaps] = {};
    UInt32 liveMapCount_ = 0;
};

OSDefineMetaClassAndStructors(ReimsAPVNub, IOPCIDevice)

// ---------------------------------------------------------------------------
// Scalar MMIO transport client (type 1). The dispatcher calls submit(); the
// daemon fetches request selectors and completes them. No request is ever
// replayed after a timeout.
// ---------------------------------------------------------------------------
class ReimsMMIOClient final : public IOUserClient {
    OSDeclareDefaultStructors(ReimsMMIOClient)

public:
    bool start(IOService *provider) override;
    void free() override;
    void stop(IOService *provider) override;
    IOReturn clientClose() override;
    IOReturn clientDied() override;

    IOReturn submit(MMIOTransaction::Op op, UInt32 offset, UInt32 &value);
    void invalidate();
    IOReturn externalMethod(uint32_t selector, IOExternalMethodArguments *args,
                            IOExternalMethodDispatch *dispatch, OSObject *target,
                            void *reference) override;

private:
    void closeRequests();

    IOLock *lock_ = nullptr;
    volatile bool closed_ = false;
    MMIOTransaction txn_;
};

OSDefineMetaClassAndStructors(ReimsMMIOClient, IOUserClient)

extern "C" UInt32 e16_apv_dispatch(UInt32 siteId, UInt64 barBase, UInt32 value) {
    const e16::SiteSpec *site = e16::findSite(static_cast<UInt8>(siteId));
    if (!site)
        return 0;

    __atomic_add_fetch(&gLive.dispatchCalls, 1, __ATOMIC_RELAXED);

    ReimsMMIOClient *transport = __atomic_load_n(&gTransport, __ATOMIC_ACQUIRE);
    if (__atomic_load_n(&gLive.ready, __ATOMIC_ACQUIRE) == 0 || !transport) {
        const UInt32 count = __atomic_add_fetch(&gLive.dispatchFailures, 1, __ATOMIC_RELAXED);
        if (count <= 4 || (count % 256) == 0)
            IOLog("ReimsAPVBridge: site %u refused: session not ready (%u)\n", siteId, count);
        return 0;
    }

    const bool sleepable = sleepableContext();
    const UInt32 seen = __atomic_load_n(&gLive.dispatchCalls, __ATOMIC_ACQUIRE);
    if (seen <= 8)
        IOLog("ReimsAPVBridge: dispatch site %u base 0x%llx value 0x%x if=%d sleep=%d\n", siteId,
              static_cast<unsigned long long>(barBase), value, sleepable ? 1 : 0,
              gDispatchSleepAllowed);
    if (!gDispatchSleepAllowed) {
        if (seen <= 8)
            IOLog("ReimsAPVBridge: dispatch disabled by boot arg; answering 0\n");
        return 0;
    }
    if (!sleepable) {
        const UInt32 count = __atomic_add_fetch(&gLive.dispatchFailures, 1, __ATOMIC_RELAXED);
        if (count <= 4 || (count % 256) == 0)
            IOLog("ReimsAPVBridge: site %u refused: interrupt context (%u)\n", siteId, count);
        return 0;
    }

    bool baseOk = false;
    for (UInt32 i = 0; i < gLive.regBaseCount; ++i) {
        if (gLive.regBases[i] == barBase) {
            baseOk = true;
            break;
        }
    }
    if (!baseOk) {
        const UInt32 count = __atomic_add_fetch(&gLive.dispatchFailures, 1, __ATOMIC_RELAXED);
        if (count <= 4 || (count % 256) == 0)
            IOLog("ReimsAPVBridge: site %u refused: BAR base 0x%llx (%u)\n", siteId,
                  static_cast<unsigned long long>(barBase), count);
        return 0;
    }

    switch (static_cast<e16::SiteKind>(site->kind)) {
    case e16::kSiteRead32:
    case e16::kSiteReadBranch: {
        UInt32 result = 0;
        if (transport->submit(MMIOTransaction::Op::read32, site->bar_offset, result) !=
            kIOReturnSuccess) {
            __atomic_add_fetch(&gLive.dispatchFailures, 1, __ATOMIC_RELAXED);
            return 0;
        }
        return result;
    }
    case e16::kSiteWriteImm: {
        UInt32 immediate = site->immediate;
        if (transport->submit(MMIOTransaction::Op::write32, site->bar_offset, immediate) !=
            kIOReturnSuccess)
            __atomic_add_fetch(&gLive.dispatchFailures, 1, __ATOMIC_RELAXED);
        return 0;
    }
    case e16::kSiteVersionPair: {
        UInt32 request = value;
        if (transport->submit(MMIOTransaction::Op::write32, site->bar_offset, request) !=
            kIOReturnSuccess) {
            __atomic_add_fetch(&gLive.dispatchFailures, 1, __ATOMIC_RELAXED);
            return 0;
        }
        UInt32 negotiated = 0;
        if (transport->submit(MMIOTransaction::Op::read32, site->bar_offset, negotiated) !=
            kIOReturnSuccess) {
            __atomic_add_fetch(&gLive.dispatchFailures, 1, __ATOMIC_RELAXED);
            return 0;
        }
        return negotiated;
    }
    }
    return 0;
}

// ---------------------------------------------------------------------------
// Session client (type 2): owns the shared BAR0 page and the arm/raise/physical
// mapping channel. It is the only client allowed to move the bridge out of its
// inert boot state.
// ---------------------------------------------------------------------------
class ReimsSessionClient final : public IOUserClient {
    OSDeclareDefaultStructors(ReimsSessionClient)

public:
    bool initWithTask(task_t owningTask, void *securityID, UInt32 type,
                      OSDictionary *properties) override;
    bool start(IOService *provider) override;
    void stop(IOService *provider) override;
    IOReturn clientClose() override;
    IOReturn clientDied() override;
    IOReturn externalMethod(uint32_t selector, IOExternalMethodArguments *args,
                            IOExternalMethodDispatch *dispatch, OSObject *target,
                            void *reference) override;
    IOReturn clientMemoryForType(UInt32 type, IOOptionBits *options,
                                 IOMemoryDescriptor **memory) override;

private:
    IOReturn arm();
    IOReturn disarm();
    IOReturn raiseInterrupt(UInt32 vector);
    IOReturn mapPhysical(UInt64 physical, UInt64 length, UInt64 target);
    IOReturn unmapPhysical(UInt64 target, UInt64 length);
    void releasePhysicalMaps();

    task_t owningTask_ = TASK_NULL;
};

OSDefineMetaClassAndStructors(ReimsSessionClient, IOUserClient)

// ---------------------------------------------------------------------------
// The control service
// ---------------------------------------------------------------------------
class ReimsPCIProbe final : public IOService {
    OSDeclareDefaultStructors(ReimsPCIProbe)

public:
    bool start(IOService *provider) override;
    IOReturn newUserClient(task_t owningTask, void *securityID, UInt32 type,
                           OSDictionary *properties, IOUserClient **handler) override;
    void free() override;
    bool armNub();
    void disarm() {
        __atomic_store_n(&gLive.ready, 0, __ATOMIC_RELEASE);
        __atomic_store_n(&gLive.armed, 0, __ATOMIC_RELEASE);
        setProperty("reims-apv-stage", "disarmed");
    }

    void setStage(const char *stage) { setProperty("reims-apv-stage", stage); }
};

OSDefineMetaClassAndStructors(ReimsPCIProbe, IOService)

namespace {

void markStage(ReimsPCIProbe *bridge, const char *stage) {
    if (bridge)
        bridge->setStage(stage);
    IOLog("ReimsAPVBridge: stage %s\n", stage);
}

} // namespace

// ---------------------------------------------------------------------------
// Nub implementation
// ---------------------------------------------------------------------------
bool ReimsAPVNub::configure(IOBufferMemoryDescriptor *backing, const char *serviceName) {
    UInt32 vendor = kPCIId & 0xffff;
    UInt32 device = kPCIId >> 16;
    UInt32 classCode = pciClassForMode();
    backing_ = backing;
    if (backing_)
        backing_->retain();
    bar_ = nullptr;
    command_ = 0;
    irqRegistered_ = 0;
    irqEnabled_ = 0;
    irqTarget_ = nullptr;
    irqHandler_ = nullptr;
    irqRefcon_ = nullptr;
    barMapRequests_ = 0;
    liveMapCount_ = 0;
    setName(serviceName);
    if (!backing_)
        return false;

    IOByteCount length = 0;
    const auto address = backing_->getPhysicalSegment(0, &length, kIOMemoryMapperNone);
    if (!address || length < kBARSize)
        return false;

    bzero(backing_->getBytesNoCopy(), kBARSize);
    bar_ = IODeviceMemory::withRange(address, kBARSize);
    if (!bar_)
        return false;
    auto memory = OSArray::withCapacity(1);
    if (!memory)
        return false;
    const bool added = memory->setObject(bar_);
    if (added)
        setDeviceMemory(memory);
    memory->release();
    if (!added)
        return false;

    return setProperty("vendor-id", &vendor, sizeof(vendor)) &&
           setProperty("device-id", &device, sizeof(device)) &&
           setProperty("class-code", &classCode, sizeof(classCode)) &&
           setProperty("compatible", "pci106b,eeee") &&
           setProperty("reims-probe-mode", static_cast<UInt64>(gMode), 32);
}

void ReimsAPVNub::free() {
    for (UInt32 i = 0; i < liveMapCount_; ++i) {
        if (liveMaps_[i])
            liveMaps_[i]->release();
        liveMaps_[i] = nullptr;
    }
    liveMapCount_ = 0;
    if (bar_) {
        setDeviceMemory(nullptr);
        bar_->release();
        bar_ = nullptr;
    }
    if (backing_) {
        backing_->release();
        backing_ = nullptr;
    }
    IOPCIDevice::free();
}

bool ReimsAPVNub::matchPropertyTable(OSDictionary *table) {
    return matchPropertyTable(table, nullptr);
}

bool ReimsAPVNub::matchPropertyTable(OSDictionary *table, SInt32 *) {
    if (!allowsAppleMatch(gMode) || !table)
        return false;
    if (!matchesString(table, "CFBundleIdentifier", "com.apple.driver.AppleParavirtGPU") ||
        !matchesString(table, "IOClass", "AppleParavirtGPUControl") ||
        !matchesString(table, "IOProviderClass", "IOPCIDevice") ||
        !matchesString(table, "IOMatchCategory", "IOFramebuffer") ||
        !matchesString(table, "IOPCIMatch", "0xEEEE106B"))
        return false;
    IOLog("ReimsAPVBridge: AppleParavirtGPUControl personality accepted\n");
    return true;
}

UInt32 ReimsAPVNub::readDword(UInt8 offset) {
    switch (offset & ~3u) {
    case 0x00:
        return kPCIId;
    case 0x04:
        return __atomic_load_n(&command_, __ATOMIC_RELAXED);
    case 0x08:
        return pciClassForMode() << 8;
    case 0x2c:
        return kPCIId;
    default:
        return 0;
    }
}

void ReimsAPVNub::updateCommand(UInt32 mask, UInt32 value) {
    setConfigBits(0x04, mask, value);
}

UInt32 ReimsAPVNub::configRead32(IOPCIAddressSpace, UInt8 offset) { return readDword(offset); }
UInt16 ReimsAPVNub::configRead16(IOPCIAddressSpace, UInt8 offset) {
    return static_cast<UInt16>(readDword(offset) >> ((offset & 2u) * 8));
}
UInt8 ReimsAPVNub::configRead8(IOPCIAddressSpace, UInt8 offset) {
    return static_cast<UInt8>(readDword(offset) >> ((offset & 3u) * 8));
}
void ReimsAPVNub::configWrite32(IOPCIAddressSpace, UInt8 offset, UInt32 value) {
    if ((offset & ~3u) == 0x04)
        updateCommand(0xffff, value);
}
void ReimsAPVNub::configWrite16(IOPCIAddressSpace, UInt8 offset, UInt16 value) {
    if ((offset & ~1u) == 0x04)
        updateCommand(0xffff, value);
}
void ReimsAPVNub::configWrite8(IOPCIAddressSpace, UInt8 offset, UInt8 value) {
    if (offset == 0x04 || offset == 0x05) {
        const unsigned shift = (offset - 0x04) * 8;
        updateCommand(0xffu << shift, static_cast<UInt32>(value) << shift);
    }
}
namespace {
volatile UInt32 gConfigLogs = 0;
}
UInt32 ReimsAPVNub::setConfigBits(UInt8 offset, UInt32 mask, UInt32 value) {
    const UInt32 logIndex = __atomic_add_fetch(&gConfigLogs, 1, __ATOMIC_RELAXED);
    if (logIndex <= 12)
        IOLog("ReimsAPVBridge: config bits call %u offset 0x%x mask 0x%x value 0x%x\n",
              logIndex, offset, mask, value);
    if (offset != 0x04)
        return readDword(offset) & mask;
    mask &= 0xffff;
    UInt32 old = __atomic_load_n(&command_, __ATOMIC_RELAXED);
    while (!__atomic_compare_exchange_n(&command_, &old, (old & ~mask) | (value & mask), false,
                                        __ATOMIC_RELAXED, __ATOMIC_RELAXED)) {
    }
    return old & mask;
}

UInt32 ReimsAPVNub::findPCICapability(UInt8 capability, UInt8 *offset) {
    // Interrupt delivery is provided by the bridge, not by MSI. Apple's
    // accelerator refuses to configure without an MSI capability, so the live
    // mode reports a synthetic one at 0x50 to let it reach setupInterrupts,
    // where the event source registers on this nub instead.
    if (gMode == kLiveBridgeMode && capability == 0x05) {
        if (offset)
            *offset = 0x50;
        IOLog("ReimsAPVBridge: synthetic MSI capability reported\n");
        return 0x50;
    }
    return 0;
}

IODeviceMemory *ReimsAPVNub::getDeviceMemoryWithIndex(unsigned int index) {
    IOLog("ReimsAPVBridge: device memory index %u requested\n", index);
    if (index != 0)
        return nullptr;
    return bar_;
}
IODeviceMemory *ReimsAPVNub::getDeviceMemoryWithRegister(UInt8 reg) {
    return reg == kBARRegister ? getDeviceMemoryWithIndex(0) : nullptr;
}

IOMemoryMap *ReimsAPVNub::mapDeviceMemoryWithIndex(unsigned int index, IOOptionBits options) {
    if (index != 0 || !backing_)
        return nullptr;
    if (gMode == kDenyBARMappingMode) {
        setProperty("reims-bar0-map", "denied-by-test");
        IOLog("ReimsAPVBridge: BAR0 map requested and denied by diagnostic mode\n");
        return nullptr;
    }
    if (gMode == kFirstBARMappingMode) {
        const UInt32 request = __atomic_add_fetch(&barMapRequests_, 1, __ATOMIC_RELAXED);
        if (request != 1) {
            setProperty("reims-bar0-later-map", "denied");
            IOLog("ReimsAPVBridge: BAR0 request %u denied\n", request);
            return nullptr;
        }
        IOLog("ReimsAPVBridge: BAR0 request 1 entering mapping\n");
    }
    auto mapping = backing_->map((options & ~static_cast<IOOptionBits>(kIOMapCacheMask)) |
                                 kIOMapCopybackCache);
    if (!mapping) {
        IOLog("ReimsAPVBridge: BAR0 map failed\n");
        return nullptr;
    }
    if (gMode == kTestBARMappingMode) {
        const char *result = "map-failed";
        const auto address = mapping->getVirtualAddress();
        if (!address || mapping->getLength() < 0x1230) {
            result = "map-invalid-range";
        } else {
            const auto word =
                reinterpret_cast<const volatile UInt32 *>(address + 0x122c);
            result = *word == 0 ? "mapped-zero-then-denied" : "mapped-nonzero-then-denied";
        }
        mapping->release();
        setProperty("reims-bar0-map", result);
        IOLog("ReimsAPVBridge: BAR0 self-test %s\n", result);
        return nullptr;
    }
    if (gMode == kLiveBridgeMode && liveMapCount_ < kMaxLiveMaps) {
        mapping->retain(); // owned by the nub, released in free()
        liveMaps_[liveMapCount_++] = mapping;
    }
    IOLog("ReimsAPVBridge: BAR0 map ok (register base 0x%llx)\n",
          static_cast<unsigned long long>(mapping->getVirtualAddress() + 0x1000));
    return mapping;
}

IOMemoryMap *ReimsAPVNub::mapDeviceMemoryWithRegister(UInt8 reg, IOOptionBits options) {
    if (reg != kBARRegister)
        return nullptr;
    // Capture Apple's return address before any other virtual call can move the
    // frame; it is the anchor used to locate and validate the loaded image.
    const UInt64 callerReturn = reinterpret_cast<UInt64>(__builtin_return_address(0));
    IOMemoryMap *mapping = mapDeviceMemoryWithIndex(0, options);
    if (!mapping)
        return nullptr;
    if (gMode == kLiveBridgeMode) {
        recordRegBase(mapping);
        if (!gPatchEnabled) {
            markStage(gBridge, "patch-disabled-by-boot-arg");
        } else if (__atomic_load_n(&gLive.patched, __ATOMIC_ACQUIRE) == 0 &&
                   __atomic_load_n(&gLive.patchFailed, __ATOMIC_ACQUIRE) == 0 &&
                   __atomic_load_n(&gLive.ready, __ATOMIC_ACQUIRE) != 0) {
            applyLivePatches(gBridge, callerReturn);
        }
    }
    return mapping;
}

IOReturn ReimsAPVNub::getInterruptType(int source, int *type) {
    if (source != 0 || !type)
        return kIOReturnNoInterrupt;
    *type = kIOInterruptTypeEdge;
    return kIOReturnSuccess;
}
IOReturn ReimsAPVNub::registerInterrupt(int source, OSObject *target,
                                       IOInterruptAction handler, void *refcon) {
    if (source != 0 || !target || !handler)
        return kIOReturnNoInterrupt;
    if (__atomic_exchange_n(&irqRegistered_, 1, __ATOMIC_ACQ_REL))
        return kIOReturnNoResources;
    irqTarget_ = target;
    irqHandler_ = handler;
    irqRefcon_ = refcon;
    IOLog("ReimsAPVBridge: IRQ0 handler registered (target %p)\n", target);
    return kIOReturnSuccess;
}
IOReturn ReimsAPVNub::unregisterInterrupt(int source) {
    if (source != 0)
        return kIOReturnNoInterrupt;
    __atomic_store_n(&irqEnabled_, 0, __ATOMIC_RELEASE);
    __atomic_store_n(&irqRegistered_, 0, __ATOMIC_RELEASE);
    irqTarget_ = nullptr;
    irqHandler_ = nullptr;
    irqRefcon_ = nullptr;
    return kIOReturnSuccess;
}
IOReturn ReimsAPVNub::enableInterrupt(int source) {
    if (source != 0 || !__atomic_load_n(&irqRegistered_, __ATOMIC_ACQUIRE))
        return kIOReturnNoInterrupt;
    __atomic_store_n(&irqEnabled_, 1, __ATOMIC_RELEASE);
    return kIOReturnSuccess;
}
IOReturn ReimsAPVNub::disableInterrupt(int source) {
    if (source != 0)
        return kIOReturnNoInterrupt;
    __atomic_store_n(&irqEnabled_, 0, __ATOMIC_RELEASE);
    return kIOReturnSuccess;
}

IOReturn ReimsAPVNub::deliverInterrupt() {
    if (!__atomic_load_n(&irqRegistered_, __ATOMIC_ACQUIRE) ||
        !__atomic_load_n(&irqEnabled_, __ATOMIC_ACQUIRE) || !irqHandler_)
        return kIOReturnNotReady;
    irqHandler_(irqTarget_, irqRefcon_, this, 0);
    return kIOReturnSuccess;
}

// ---------------------------------------------------------------------------
// Transport client
// ---------------------------------------------------------------------------
bool ReimsMMIOClient::start(IOService *provider) {
    lock_ = IOLockAlloc();
    if (!lock_)
        return false;
    closed_ = false;
    txn_ = MMIOTransaction{};
    setProperty("IOUserClientDefaultLocking", true);
    return IOUserClient::start(provider);
}

void ReimsMMIOClient::free() {
    if (lock_)
        IOLockFree(lock_);
    IOUserClient::free();
}

void ReimsMMIOClient::stop(IOService *provider) {
    closeRequests();
    IOUserClient::stop(provider);
}

void ReimsMMIOClient::invalidate() { closeRequests(); }

IOReturn ReimsMMIOClient::clientClose() {
    closeRequests();
    __atomic_store_n(&gLive.ready, 0, __ATOMIC_RELEASE);
    ReimsMMIOClient *expected = this;
    __atomic_compare_exchange_n(&gTransport, &expected,
                                static_cast<ReimsMMIOClient *>(nullptr), false,
                                __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE);
    terminate();
    return kIOReturnSuccess;
}

IOReturn ReimsMMIOClient::clientDied() {
    closeRequests();
    __atomic_store_n(&gLive.ready, 0, __ATOMIC_RELEASE);
    ReimsMMIOClient *expected = this;
    __atomic_compare_exchange_n(&gTransport, &expected,
                                static_cast<ReimsMMIOClient *>(nullptr), false,
                                __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE);
    return kIOReturnSuccess;
}

void ReimsMMIOClient::closeRequests() {
    IOLockLock(lock_);
    closed_ = true;
    txn_.cancel();
    IOLockWakeup(lock_, &txn_, false);
    IOLockUnlock(lock_);
}

IOReturn ReimsMMIOClient::submit(MMIOTransaction::Op op, UInt32 offset, UInt32 &value) {
    if (!lock_)
        return kIOReturnNotReady;
    UInt64 deadline = 0;
    clock_interval_to_deadline(kTransportTimeoutMs, kMillisecondScale, &deadline);
    IOLockLock(lock_);
    if (closed_ || !txn_.begin(op, offset, op == MMIOTransaction::Op::write32 ? value : 0)) {
        IOLockUnlock(lock_);
        IOLog("ReimsAPVBridge: submit refused (closed or busy)\n");
        return kIOReturnNotReady;
    }
    while (txn_.waiting()) {
        if (IOLockSleepDeadline(lock_, &txn_, deadline, THREAD_INTERRUPTIBLE) != THREAD_AWAKENED)
            break;
    }
    const bool timedOut = txn_.waiting();
    if (timedOut) {
        // A fetched write may have executed even though no reply arrived; the
        // session must never be reused for another request.
        closed_ = true;
        IOLog("ReimsAPVBridge: transport timeout, session poisoned\n");
    }
    MMIOTransaction::Word result = 0;
    const bool ok = txn_.consume(result);
    IOLockUnlock(lock_);
    if (!ok)
        return timedOut ? kIOReturnTimeout : kIOReturnError;
    if (op == MMIOTransaction::Op::read32)
        value = static_cast<UInt32>(result);
    return kIOReturnSuccess;
}

IOReturn ReimsMMIOClient::externalMethod(uint32_t selector, IOExternalMethodArguments *args,
                                         IOExternalMethodDispatch *, OSObject *, void *) {
    if (!args || args->structureInputSize || args->structureOutputSize ||
        args->structureInputDescriptor || args->structureOutputDescriptor)
        return kIOReturnBadArgument;

    IOReturn result = kIOReturnUnsupported;
    IOLockLock(lock_);
    if (closed_) {
        result = kIOReturnNotOpen;
    } else if (selector == 0) {
        if (args->scalarInputCount != 0 || args->scalarOutputCount != 4 || !args->scalarOutput) {
            result = kIOReturnBadArgument;
        } else {
            MMIOTransaction::Request request = {};
            if (txn_.fetch(request)) {
                args->scalarOutput[0] = request.sequence;
                args->scalarOutput[1] = request.operation;
                args->scalarOutput[2] = request.offset;
                args->scalarOutput[3] = request.value;
                result = kIOReturnSuccess;
            } else {
                result = kIOReturnNotReady;
            }
        }
    } else if (selector == 1) {
        if (args->scalarInputCount != 3 || args->scalarOutputCount != 0 || !args->scalarInput ||
            !txn_.reply(args->scalarInput[0], args->scalarInput[1], args->scalarInput[2])) {
            result = kIOReturnBadArgument;
        } else {
            IOLockWakeup(lock_, &txn_, false);
            result = kIOReturnSuccess;
        }
    }
    IOLockUnlock(lock_);
    return result;
}

// ---------------------------------------------------------------------------
// Session client
// ---------------------------------------------------------------------------
bool ReimsSessionClient::initWithTask(task_t owningTask, void *securityID, UInt32 type,
                                      OSDictionary *properties) {
    owningTask_ = owningTask;
    return IOUserClient::initWithTask(owningTask, securityID, type, properties);
}

bool ReimsSessionClient::start(IOService *provider) {
    setProperty("IOUserClientDefaultLocking", true);
    if (!IOUserClient::start(provider))
        return false;
    ReimsSessionClient *expected = nullptr;
    if (!__atomic_compare_exchange_n(&gSession, &expected, this, false, __ATOMIC_ACQ_REL,
                                     __ATOMIC_ACQUIRE)) {
        IOLog("ReimsAPVBridge: second session client refused\n");
        return false;
    }
    return true;
}

void ReimsSessionClient::stop(IOService *provider) {
    releasePhysicalMaps();
    IOUserClient::stop(provider);
}

void ReimsSessionClient::releasePhysicalMaps() {
    if (!gMapLock)
        return;
    IOLockLock(gMapLock);
    for (UInt32 i = 0; i < gPhysicalMapCount; ++i) {
        if (gPhysicalMaps[i].map) {
            gPhysicalMaps[i].map->release();
            gPhysicalMaps[i].map = nullptr;
        }
        gPhysicalMaps[i].targetAddress = 0;
        gPhysicalMaps[i].length = 0;
    }
    gPhysicalMapCount = 0;
    IOLockUnlock(gMapLock);
}

IOReturn ReimsSessionClient::clientClose() {
    ReimsSessionClient *expected = this;
    __atomic_compare_exchange_n(&gSession, &expected,
                                static_cast<ReimsSessionClient *>(nullptr), false,
                                __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE);
    if (gTransport)
        gTransport->invalidate();
    if (gBridge)
        gBridge->disarm();
    releasePhysicalMaps();
    terminate();
    return kIOReturnSuccess;
}

IOReturn ReimsSessionClient::clientDied() { return clientClose(); }

IOReturn ReimsSessionClient::arm() {
    if (!gBridge)
        return kIOReturnNotReady;
    if (__atomic_load_n(&gLive.armed, __ATOMIC_ACQUIRE))
        return kIOReturnSuccess;
    if (!gBridge->armNub())
        return kIOReturnError;
    return kIOReturnSuccess;
}

IOReturn ReimsSessionClient::disarm() {
    if (gBridge)
        gBridge->disarm();
    return kIOReturnSuccess;
}

IOReturn ReimsSessionClient::raiseInterrupt(UInt32 vector) {
    if (vector != 0 || !gNub)
        return kIOReturnBadArgument;
    return gNub->deliverInterrupt();
}

IOReturn ReimsSessionClient::mapPhysical(UInt64 physical, UInt64 length, UInt64 target) {
    if (!owningTask_ || !gMapLock)
        return kIOReturnNotReady;
    if (physical == 0 || (physical & 0xfff) != 0 || length == 0 || (length & 0xfff) != 0 ||
        length > kMaxPhysicalMapLength || (target & 0xfff) != 0 ||
        physical > ~0ULL - length)
        return kIOReturnBadArgument;

    IOMemoryDescriptor *descriptor =
        IOMemoryDescriptor::withPhysicalAddress(physical, length, kIODirectionInOut);
    if (!descriptor)
        return kIOReturnNoMemory;
    IOMemoryMap *map = descriptor->createMappingInTask(
        owningTask_, target, kIOMapCopybackCache | kIOMapOverwrite, 0, length);
    descriptor->release();
    if (!map)
        return kIOReturnNoResources;

    IOLockLock(gMapLock);
    for (UInt32 i = 0; i < gPhysicalMapCount; ++i) {
        const UInt64 start = gPhysicalMaps[i].targetAddress;
        const UInt64 end = start + gPhysicalMaps[i].length;
        if (target < end && start < target + length) {
            IOLockUnlock(gMapLock);
            map->release();
            return kIOReturnBusy;
        }
    }
    if (gPhysicalMapCount >= kMaxPhysicalMaps) {
        IOLockUnlock(gMapLock);
        map->release();
        return kIOReturnNoResources;
    }
    gPhysicalMaps[gPhysicalMapCount].targetAddress = target;
    gPhysicalMaps[gPhysicalMapCount].length = length;
    gPhysicalMaps[gPhysicalMapCount].map = map;
    ++gPhysicalMapCount;
    IOLockUnlock(gMapLock);

    const UInt32 count = gPhysicalMapCount;
    if (count <= 8 || (count % 64) == 0)
        IOLog("ReimsAPVBridge: guest physical 0x%llx+0x%llx -> user 0x%llx\n",
              static_cast<unsigned long long>(physical), static_cast<unsigned long long>(length),
              static_cast<unsigned long long>(target));
    return kIOReturnSuccess;
}

IOReturn ReimsSessionClient::unmapPhysical(UInt64 target, UInt64 length) {
    if (!gMapLock)
        return kIOReturnNotReady;
    IOLockLock(gMapLock);
    for (UInt32 i = 0; i < gPhysicalMapCount; ++i) {
        if (gPhysicalMaps[i].targetAddress == target) {
            if (gPhysicalMaps[i].map) {
                gPhysicalMaps[i].map->release();
                gPhysicalMaps[i].map = nullptr;
            }
            gPhysicalMaps[i] = gPhysicalMaps[gPhysicalMapCount - 1];
            --gPhysicalMapCount;
            IOLockUnlock(gMapLock);
            (void)length;
            return kIOReturnSuccess;
        }
    }
    IOLockUnlock(gMapLock);
    return kIOReturnNotFound;
}

IOReturn ReimsSessionClient::clientMemoryForType(UInt32 type, IOOptionBits *options,
                                                 IOMemoryDescriptor **memory) {
    if (type != 0 || !gBarBacking || !options || !memory)
        return kIOReturnUnsupported;
    gBarBacking->retain();
    *memory = gBarBacking;
    *options = kIOMapCopybackCache;
    return kIOReturnSuccess;
}

IOReturn ReimsSessionClient::externalMethod(uint32_t selector, IOExternalMethodArguments *args,
                                            IOExternalMethodDispatch *, OSObject *, void *) {
    if (!args)
        return kIOReturnBadArgument;

    enum {
        kSelectorInfo = 0,
        kSelectorArm = 1,
        kSelectorRaise = 2,
        kSelectorMapPhysical = 3,
        kSelectorUnmapPhysical = 4,
        kSelectorDisarm = 5,
        kSelectorStats = 6,
    };

    switch (selector) {
    case kSelectorInfo: {
        if (args->scalarInputCount != 0 || args->scalarOutputCount != 4 || !args->scalarOutput)
            return kIOReturnBadArgument;
        args->scalarOutput[0] = 1; // protocol version
        args->scalarOutput[1] = static_cast<UInt64>(kLiveBridgeMode);
        args->scalarOutput[2] = kBARSize;
        args->scalarOutput[3] = __atomic_load_n(&gLive.ready, __ATOMIC_ACQUIRE);
        return kIOReturnSuccess;
    }
    case kSelectorArm: {
        if (args->scalarInputCount != 0 || args->scalarOutputCount != 0)
            return kIOReturnBadArgument;
        if (__atomic_load_n(&gLive.ready, __ATOMIC_ACQUIRE) == 0)
            return kIOReturnNotReady;
        return arm();
    }
    case kSelectorRaise: {
        if (args->scalarInputCount != 1 || args->scalarOutputCount != 0 || !args->scalarInput)
            return kIOReturnBadArgument;
        return raiseInterrupt(static_cast<UInt32>(args->scalarInput[0]));
    }
    case kSelectorMapPhysical: {
        struct Request {
            UInt64 physicalAddress;
            UInt64 length;
            UInt64 targetAddress;
        } request = {};
        if (args->structureInputSize != sizeof(Request) || !args->structureInput ||
            args->scalarInputCount != 0 || args->structureOutputSize != 0)
            return kIOReturnBadArgument;
        __builtin_memcpy(&request, args->structureInput, sizeof(request));
        return mapPhysical(request.physicalAddress, request.length, request.targetAddress);
    }
    case kSelectorUnmapPhysical: {
        struct Request {
            UInt64 targetAddress;
            UInt64 length;
        } request = {};
        if (args->structureInputSize != sizeof(Request) || !args->structureInput ||
            args->scalarInputCount != 0 || args->structureOutputSize != 0)
            return kIOReturnBadArgument;
        __builtin_memcpy(&request, args->structureInput, sizeof(request));
        return unmapPhysical(request.targetAddress, request.length);
    }
    case kSelectorDisarm:
        return disarm();
    case kSelectorStats: {
        if (args->scalarInputCount != 0 || args->scalarOutputCount != 4 || !args->scalarOutput)
            return kIOReturnBadArgument;
        args->scalarOutput[0] = __atomic_load_n(&gLive.dispatchCalls, __ATOMIC_ACQUIRE);
        args->scalarOutput[1] = __atomic_load_n(&gLive.dispatchFailures, __ATOMIC_ACQUIRE);
        args->scalarOutput[2] = __atomic_load_n(&gLive.patched, __ATOMIC_ACQUIRE);
        args->scalarOutput[3] = __atomic_load_n(&gLive.regBaseCount, __ATOMIC_ACQUIRE);
        return kIOReturnSuccess;
    }
    default:
        return kIOReturnUnsupported;
    }
}

// ---------------------------------------------------------------------------
// Control service
// ---------------------------------------------------------------------------
bool ReimsPCIProbe::start(IOService *provider) {
    if (!PE_parse_boot_argn("reimspci", &gMode, sizeof(gMode)) || gMode == 0)
        return false;
    PE_parse_boot_argn("apvpatch", &gPatchEnabled, sizeof(gPatchEnabled));
    PE_parse_boot_argn("apvdsp", &gDispatchSleepAllowed, sizeof(gDispatchSleepAllowed));
    IOLog("ReimsAPVBridge: diagnostics patch=%d dispatch_sleep=%d\n", gPatchEnabled,
          gDispatchSleepAllowed);
    if (gMode != kControlMode && gMode != kAttachOnlyMode && gMode != kRelayMode &&
        gMode != kMMIOBridgeMode && gMode != kLiveBridgeMode && !publishesLegacyNub(gMode) &&
        !allowsAppleMatch(gMode)) {
        IOLog("ReimsAPVBridge: unsupported mode %d\n", gMode);
        return false;
    }
    if (!IOService::start(provider))
        return false;

    gBridge = this;
    setName("ReimsPCIProbe");
    setProperty("reims-probe-mode", static_cast<UInt64>(gMode), 32);
    setProperty("reims-apv-stage", "control-started");
    IOLog("ReimsAPVBridge: control-started mode=%d\n", gMode);

    if (gMode == kLiveBridgeMode) {
        gMapLock = IOLockAlloc();
        if (!gMapLock) {
            IOLog("ReimsAPVBridge: no lock\n");
            return false;
        }
        // Kernel RAM that is mapped both by Apple's IOPCIDevice BAR path and by
        // the daemon (clientMemoryForType type 0), so all BAR0 accesses share
        // one cacheable page. Fall back to the 0.1.x flag set if the shared
        // allocation is refused.
        gBarBacking = IOBufferMemoryDescriptor::inTaskWithOptions(
            kernel_task,
            kIODirectionInOut | kIOMemoryKernelUserShared | kIOMemoryPhysicallyContiguous |
                kIOMemoryMapperNone,
            kBARSize, 4096);
        if (!gBarBacking) {
            IOLog("ReimsAPVBridge: shared BAR backing refused, retrying unshared\n");
            gBarBacking = IOBufferMemoryDescriptor::inTaskWithOptions(
                kernel_task,
                kIODirectionInOut | kIOMemoryPhysicallyContiguous | kIOMemoryMapperNone, kBARSize,
                4096);
        }
        if (!gBarBacking) {
            IOLog("ReimsAPVBridge: no BAR backing\n");
            return false;
        }
        bzero(gBarBacking->getBytesNoCopy(), kBARSize);
        setProperty("reims-apv-live", true);
        setProperty("reims-apv-stage", "live-waiting-for-daemon");
        IOLog("ReimsAPVBridge: live bridge waiting for a console-session daemon\n");
        registerService();
        return true;
    }

    if (gMode == kRelayMode || gMode == kMMIOBridgeMode) {
        setProperty("reims-apv-stage", gMode == kRelayMode ? "relay-ready" : "transport-ready");
        registerService();
        return true;
    }
    if (gMode == kControlMode)
        return true;

    // Diagnostic nub modes (3, 5, 6, 7, 8, 9).
    auto *backing = IOBufferMemoryDescriptor::inTaskWithOptions(
        kernel_task, kIODirectionInOut | kIOMemoryPhysicallyContiguous | kIOMemoryMapperNone,
        kBARSize, 4096);
    if (!backing)
        return true;
    auto nub = new ReimsAPVNub;
    if (!nub || !nub->init(nullptr)) {
        if (nub)
            nub->release();
        backing->release();
        setProperty("reims-apv-stage", "init-failed");
        return true;
    }
    if (!nub->configure(backing, "ReimsPCINub")) {
        nub->release();
        backing->release();
        setProperty("reims-apv-stage", "configure-failed");
        return true;
    }
    backing->release();
    if (!nub->attach(this)) {
        nub->release();
        setProperty("reims-apv-stage", "attach-failed");
        return true;
    }
    setProperty("reims-apv-stage", "attached");
    IOLog("ReimsAPVBridge: attached 106b:eeee with BAR0\n");
    gNub = nub;
    if (allowsAppleMatch(gMode) || publishesLegacyNub(gMode)) {
        setProperty("reims-apv-stage", "register-requested");
        nub->registerService();
        setProperty("reims-apv-stage", "register-returned");
        IOLog("ReimsAPVBridge: registerService returned\n");
    }
    return true;
}

bool ReimsPCIProbe::armNub() {
    if (__atomic_load_n(&gLive.armed, __ATOMIC_ACQUIRE))
        return true;
    if (!gBarBacking)
        return false;
    auto *nub = new ReimsAPVNub;
    if (!nub || !nub->init(nullptr))
        return false;
    if (!nub->configure(gBarBacking, "ReimsPCINub") || !nub->attach(this)) {
        nub->release();
        return false;
    }
    nub->retain();
    gNub = nub;
    // The daemon maps the shared page and serves the transport client before it
    // arms the bridge, so Apple's driver never runs without a live backend.
    __atomic_store_n(&gLive.ready, 1, __ATOMIC_RELEASE);
    __atomic_store_n(&gLive.armed, 1, __ATOMIC_RELEASE);
    setProperty("reims-apv-stage", "arming");
    IOLog("ReimsAPVBridge: arming; publishing AppleParavirtGPU provider\n");
    nub->registerService();
    setProperty("reims-apv-stage", "armed");
    IOLog("ReimsAPVBridge: registerService returned for live nub\n");
    return true;
}

void ReimsPCIProbe::free() {
    if (gNub) {
        gNub->release();
        gNub = nullptr;
    }
    if (gBarBacking) {
        gBarBacking->release();
        gBarBacking = nullptr;
    }
    if (gMapLock) {
        IOLockFree(gMapLock);
        gMapLock = nullptr;
    }
    gBridge = nullptr;
    IOService::free();
}

IOReturn ReimsPCIProbe::newUserClient(task_t owningTask, void *securityID, UInt32 type,
                                       OSDictionary *properties, IOUserClient **handler) {
    if (!handler)
        return kIOReturnBadArgument;
    *handler = nullptr;

    IOUserClient *client = nullptr;
    const bool diagnosticRelay = gMode == kRelayMode && type == 0;
    const bool transport = (gMode == kMMIOBridgeMode || gMode == kLiveBridgeMode) && type == 1;
    const bool session = gMode == kLiveBridgeMode && type == 2;
    if (!diagnosticRelay && !transport && !session)
        return kIOReturnUnsupported;

    // The live bridge is designed for a normal console-session daemon: Metal
    // must not run as root, and the transport is still gated on the boot
    // argument and on the arm step that the session client performs.
    IOReturn allowed = IOUserClient::clientHasPrivilege(securityID, kIOClientPrivilegeLocalUser);
    if (allowed != kIOReturnSuccess)
        allowed = IOUserClient::clientHasPrivilege(securityID, kIOClientPrivilegeAdministrator);
    if (allowed != kIOReturnSuccess) {
        IOLog("ReimsAPVBridge: client refused: not a local or administrative user\n");
        return allowed;
    }

    if (session)
        client = new ReimsSessionClient;
    else if (transport)
        client = new ReimsMMIOClient;
    else
        client = nullptr; // relay class was removed from the live build
    if (!client)
        return kIOReturnUnsupported;

    if (!client->initWithTask(owningTask, securityID, type, properties) ||
        !client->attach(this)) {
        client->release();
        return kIOReturnError;
    }
    if (!client->start(this)) {
        client->detach(this);
        client->release();
        return kIOReturnError;
    }
    if (transport) {
        ReimsMMIOClient *expected = nullptr;
        if (!__atomic_compare_exchange_n(&gTransport, &expected,
                                         static_cast<ReimsMMIOClient *>(client), false,
                                         __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE)) {
            client->detach(this);
            client->release();
            return kIOReturnExclusiveAccess;
        }
    }
    *handler = client;
    return kIOReturnSuccess;
}
