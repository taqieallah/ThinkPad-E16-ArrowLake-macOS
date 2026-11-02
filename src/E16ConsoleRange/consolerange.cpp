// E16ConsoleRange: the firmware on Arrow Lake-H laptops lights the panel from stolen memory (DSM) in RAM, an address
// that is in none of the iGPU's PCI BARs. Add that range to the iGPU's device memory so IONDRVFramebuffer / IOGraphics
// treat it as the device's own framebuffer (the job IGPUConsoleRange does on the HONOR MagicBook 255H).
// probe() records the range and declines, so the real framebuffer (IONDRV or NMIntelFB) still matches next.
#include <IOKit/IOService.h>
#include <IOKit/IOLib.h>
#include <IOKit/IODeviceMemory.h>
#include <IOKit/IOPlatformExpert.h>
#include <IOKit/IODeviceTreeSupport.h>
#include <IOKit/IONVRAM.h>
#include <IOKit/pci/IOPCIDevice.h>
#include <libkern/c++/OSArray.h>
#include <libkern/c++/OSData.h>
#include <pexpert/pexpert.h>
#include <mach/kmod.h>

#define CRLOG(fmt, ...) IOLog("E16ConsoleRange: " fmt "\n", ##__VA_ARGS__)

extern "C" kern_return_t _start(kmod_info_t *ki, void *d); extern "C" kern_return_t _stop(kmod_info_t *ki, void *d);
extern "C" { KMOD_EXPLICIT_DECL(org.e16.ConsoleRange, "0.2", _start, _stop) }
extern "C" kern_return_t _start(kmod_info_t *ki, void *d) { return KERN_SUCCESS; }
extern "C" kern_return_t _stop(kmod_info_t *ki, void *d)  { return KERN_SUCCESS; }

static void crNv(const char *s)
{
    if (IORegistryEntry *o = IORegistryEntry::fromPath("/options", gIODTPlane)) {
        if (OSData *d = OSData::withBytes(s, (unsigned)strlen(s))) { o->setProperty("e16cr-info", d); d->release(); }
        if (IODTNVRAM *nv = OSDynamicCast(IODTNVRAM, o)) nv->sync();
        o->release();
    }
}

class E16ConsoleRange : public IOService {
    OSDeclareDefaultStructors(E16ConsoleRange)
public:
    IOService *probe(IOService *provider, SInt32 *score) override;
};
OSDefineMetaClassAndStructors(E16ConsoleRange, IOService)

IOService *E16ConsoleRange::probe(IOService *provider, SInt32 *score)
{
    char msg[200];
    if (PE_parse_boot_argn("-e16croff", nullptr, 0)) { CRLOG("off by boot-arg"); return nullptr; }
    IOPCIDevice *pci = OSDynamicCast(IOPCIDevice, provider);
    if (!pci || provider->getProperty("watchthelight-console-range")) return nullptr;
    PE_Video v; bzero(&v, sizeof v);
    if (!getPlatform() || getPlatform()->getConsoleInfo(&v) != kIOReturnSuccess || !v.v_baseAddr || !v.v_rowBytes || !v.v_height) {
        CRLOG("no boot console"); crNv("no boot console"); return nullptr;
    }
    uint64_t base = (uint64_t)v.v_baseAddr & ~3ull;
    uint64_t len = ((uint64_t)v.v_rowBytes * v.v_height + 4095) & ~4095ull;
    OSArray *mem = provider->getDeviceMemory();
    unsigned n = mem ? mem->getCount() : 0;
    for (unsigned i = 0; i < n; i++) {
        // IODeviceMemory objects are IOMemoryDescriptors underneath; cast by name, not through IODeviceMemory's metaclass
        OSObject *o = mem->getObject(i);
        IOMemoryDescriptor *m = o ? (IOMemoryDescriptor *)o->metaCast("IOMemoryDescriptor") : nullptr;
        if (!m) continue;
        IOByteCount sl = 0; addr64_t mb = m->getPhysicalSegment(0, &sl, kIOMemoryMapperNone);
        if (base >= mb && base + len <= mb + m->getLength()) {
            snprintf(msg, sizeof msg, "console 0x%llx already in device memory %u - nothing to add", (unsigned long long)base, i);
            CRLOG("%s", msg); crNv(msg); return nullptr;
        }
    }
    IODeviceMemory *range = IODeviceMemory::withRange((IOPhysicalAddress)base, (IOPhysicalLength)len);
    OSArray *nmem = mem ? OSArray::withArray(mem, n + 1) : OSArray::withCapacity(1);
    if (!range || !nmem) { OSSafeReleaseNULL(range); OSSafeReleaseNULL(nmem); CRLOG("no memory"); return nullptr; }
    nmem->setObject(range);
    provider->setDeviceMemory(nmem);
    provider->setProperty("watchthelight-console-range", base, 64);
    provider->setProperty("e16-console-range", base, 64);
    snprintf(msg, sizeof msg, "v0.2 console 0x%llx (%lux%lu rowBytes %lu) len 0x%llx added as device memory %u",
             (unsigned long long)base, v.v_width, v.v_height, v.v_rowBytes, (unsigned long long)len, n);
    CRLOG("%s", msg); crNv(msg);
    range->release(); nmem->release();
    return nullptr;   // decline: the framebuffer driver matches next
}
