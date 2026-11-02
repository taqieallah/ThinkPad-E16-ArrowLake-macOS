// XeGfxIntelFramebuffer: Apple's IONDRVFramebuffer under a class name with "Intel" in it. CoreDisplay picks the GPU
// vendor from the IOFramebuffer class name, and IONDRVFramebuffer reads as no vendor, which turns IOPresentment off
// for WindowServer (I-108). Lives in the AuxKC because IONDRVSupport is in the system collection.
// <wtl> fork: nvgfx | author: watchthelight </wtl>
#include <IOKit/ndrvsupport/IONDRVFramebuffer.h>
#include <IOKit/IODeviceTreeSupport.h>
#include <IOKit/IOLib.h>
#include <libkern/c++/OSData.h>
#include <pexpert/pexpert.h>
#include <sys/sysctl.h>
#include <IOKit/pci/IOPCIDevice.h>
#include <mach/mach_time.h>
#include <kern/thread_call.h>
#include <kern/clock.h>
#include <IOKit/IOBufferMemoryDescriptor.h>
#include <IOKit/IOLocks.h>

#define XIFBLOG(fmt, ...) IOLog("XeGfxIntelFB: " fmt "\n", ##__VA_ARGS__)

// Boot guard as in NMIntelFB: each start counts in NVRAM, 120 s of uptime after start clears it, and two counted starts
// in a row make probe decline so IONDRVFramebuffer drives the panel again. Boot-arg -xeintelfboff declines always.
#define XIFB_GUARD_VAR "xeintelfb-starts"
// About This Mac shows "model" followed by the VRAM size; name the chip generation and graphics architecture
static const char *xifbModelName(uint16_t dev)
{
    switch (dev) {
    case 0x7d67: case 0x7d41: return "Intel Arrow Lake Xe-LPG";
    case 0x7d51: case 0x7dd1: return "Intel Arrow Lake Xe-LPG+";
    case 0x7d40: case 0x7d45: case 0x7d55: case 0x7dd5: return "Intel Meteor Lake Xe-LPG";
    default: return "Intel Xe Graphics";
    }
}
static unsigned xifbGuardStarts(IORegistryEntry *o)
{
    OSObject *v = o->copyProperty(XIFB_GUARD_VAR); OSData *d = OSDynamicCast(OSData, v);
    unsigned n = (d && d->getLength() >= 1) ? *(const unsigned char *)d->getBytesNoCopy() : 0;
    if (v) v->release();
    return n;
}
static bool xifbGuardTripped()
{
    IORegistryEntry *o = IORegistryEntry::fromPath("/options", gIODTPlane); if (!o) return false;
    bool t = xifbGuardStarts(o) >= 2; o->release(); return t;
}
static void xifbGuardCount()
{
    IORegistryEntry *o = IORegistryEntry::fromPath("/options", gIODTPlane); if (!o) return;
    unsigned char n = (unsigned char)(xifbGuardStarts(o) + 1);
    if (OSData *d = OSData::withBytes(&n, 1)) { if (o->setProperty(XIFB_GUARD_VAR, d)) XIFBLOG("boot guard: start %u without WindowServer so far (off after 2)", n); d->release(); }
    o->release();
}
static void xifbGuardClear()
{
    static bool done; if (done) return; done = true;
    IORegistryEntry *o = IORegistryEntry::fromPath("/options", gIODTPlane); if (!o) return;
    // removeProperty did not reach NVRAM (N-283); a zero count does, the same way the count itself is written
    unsigned char z = 0;
    if (OSData *d = OSData::withBytes(&z, 1)) { if (o->setProperty(XIFB_GUARD_VAR, d)) XIFBLOG("boot guard cleared: still up 120 s after start"); d->release(); }
    o->release();
}

// kmutil places a kext in a kernel collection only with a _kmod_info symbol (Xcode generates it; this build does not)
#include <mach/kmod.h>
extern "C" kern_return_t _start(kmod_info_t *ki, void *d); extern "C" kern_return_t _stop(kmod_info_t *ki, void *d);
extern "C" { KMOD_EXPLICIT_DECL(org.watchthelight.XeGfxIntelFB, "0.9.4", _start, _stop) }
extern "C" kern_return_t _start(kmod_info_t *ki, void *d) { return KERN_SUCCESS; }
extern "C" kern_return_t _stop(kmod_info_t *ki, void *d)  { return KERN_SUCCESS; }


// The panel's EDID over the eDP AUX channel (AUX A, display version 14 layout), which the firmware left powered for
// its own modeset. Without it macOS sees "Unknown Display" and none of the panel's overrides (name, HiDPI sizes) apply.
#define XIFB_AUX_CTL  0x64010
#define XIFB_AUX_DATA 0x64014
static volatile uint32_t *gRegs;
static uint32_t xr(uint32_t o) { return gRegs[o / 4]; }
static void xw(uint32_t o, uint32_t v) { gRegs[o / 4] = v; }
static int xifbAux(const uint8_t *tx, int ntx, uint8_t *rx, int nrx)
{
    for (int i = 0; i < 100 && (xr(XIFB_AUX_CTL) & (1u << 31)); i++) IODelay(100);
    if (xr(XIFB_AUX_CTL) & (1u << 31)) return -1;
    for (int i = 0; i < ntx; i += 4) {
        uint32_t v = 0;
        for (int j = 0; j < 4 && i + j < ntx; j++) v |= (uint32_t)tx[i + j] << (24 - 8 * j);
        xw(XIFB_AUX_DATA + i, v);
    }
    // send busy, done, irq, timeout/receive error clears, max timeout, size, sync pulses 18 and 32, power request kept
    uint32_t ctl = (1u << 31) | (1u << 30) | (1u << 29) | (1u << 28) | (3u << 26) | (1u << 25) | ((uint32_t)ntx << 20) |
                   ((18u - 1) << 5) | (32u - 1) | (1u << 19);
    xw(XIFB_AUX_CTL, ctl);
    uint32_t st = 0;
    for (int i = 0; i < 200; i++) { st = xr(XIFB_AUX_CTL); if (!(st & (1u << 31))) break; IODelay(50); }
    xw(XIFB_AUX_CTL, st | (1u << 30) | (1u << 28) | (1u << 25));
    if ((st & (1u << 31)) || (st & ((1u << 28) | (1u << 25)))) return -1;
    int n = (st >> 20) & 0x1f; if (n > nrx) n = nrx;
    for (int i = 0; i < n; i++) rx[i] = (uint8_t)(xr(XIFB_AUX_DATA + (i & ~3)) >> (24 - 8 * (i & 3)));
    return n;
}
// one I2C-over-AUX transfer to the EDID address 0x50, retried while the sink defers
static int xifbI2c(uint8_t req, const uint8_t *data, int nd, uint8_t *rx, int nrx)
{
    uint8_t tx[20] = { (uint8_t)(req << 4), 0, 0x50, (uint8_t)(nd ? nd - 1 : (nrx > 1 ? nrx - 2 : 0)) };
    int ntx = (nd || nrx > 1) ? 4 : 3;
    for (int i = 0; i < nd; i++) tx[ntx++] = data[i];
    for (int t = 0; t < 7; t++) {
        int n = xifbAux(tx, ntx, rx, nrx);
        if (n >= 1 && !(rx[0] & 0xf0)) return n;
        IODelay(500);
    }
    return -1;
}
static bool xifbReadEdid(uint8_t *edid, int *len)
{
    uint8_t off = 0, rx[17];
    if (xifbI2c(0x4, &off, 1, rx, 1) < 1) return false;    // write, middle of transaction: offset 0
    int want = 128;
    for (int pos = 0; pos < want; pos += 16) {
        if (xifbI2c(0x5, nullptr, 0, rx, 17) != 17) return false;
        bcopy(rx + 1, edid + pos, 16);
        if (pos == 112) want = edid[126] ? 256 : 128;       // base block plus at most one extension (no segment pointer)
    }
    xifbI2c(0x1, nullptr, 0, rx, 1);                        // stop
    static const uint8_t hdr[8] = { 0, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0 };
    if (memcmp(edid, hdr, 8)) return false;
    for (int b = 0; b < want; b += 128) { uint8_t c = 0; for (int i = 0; i < 128; i++) c += edid[b + i]; if (c) return false; }
    *len = want;
    return true;
}
// pipe A's frame counter over about half a second: the refresh rate the firmware's mode runs at, in 16.16
static uint32_t xifbMeasureHz()
{
    const uint32_t fc = 0x70040;
    uint32_t a = xr(fc), b = a;
    for (int i = 0; i < 100 && (b = xr(fc)) == a; i++) IODelay(500);
    if (b == a) return 0;
    uint64_t t0 = mach_absolute_time(); IOSleep(500);
    uint32_t c = xr(fc); for (int i = 0; i < 100 && xr(fc) == c; i++) IODelay(100);
    uint64_t t1 = mach_absolute_time(), ns; absolutetime_to_nanoseconds(t1 - t0, &ns);
    uint32_t frames = xr(fc) - b;
    return ns ? (uint32_t)(((uint64_t)frames << 16) * 1000000000ull / ns) : 0;
}
// the EDID detailed timing nearest the measured rate, so the reported refresh is the panel's exact one
static uint32_t xifbSnapHz(const uint8_t *e, int len, uint32_t meas)
{
    uint32_t best = meas, bd = ~0u;
    auto dtd = [&](const uint8_t *d) {
        uint32_t clk = (d[0] | d[1] << 8) * 10000u; if (!clk) return;
        uint32_t ht = d[2] | (d[4] & 0xf0) << 4, hb = d[3] | (d[4] & 0x0f) << 8;
        uint32_t vt = d[5] | (d[7] & 0xf0) << 4, vb = d[6] | (d[7] & 0x0f) << 8;
        uint64_t tot = (uint64_t)(ht + hb) * (vt + vb); if (!tot) return;
        uint32_t hz = (uint32_t)(((uint64_t)clk << 16) / tot), d0 = hz > meas ? hz - meas : meas - hz;
        if (d0 < bd) { bd = d0; best = hz; }
    };
    for (int i = 0; i < 4; i++) dtd(e + 54 + 18 * i);
    if (len >= 256 && e[128] == 0x02) for (int o = e[130]; o >= 4 && o + 18 <= 127; o += 18) dtd(e + 128 + o);
    return (meas && bd > meas / 50) ? meas : best;    // more than 2 % off: keep the measurement
}



// E16 (0.9.3): the record XeGfxAGDC's K5 answers AGDC 0x921 (kAGDCLinkConfig) from. Without it K5 falls back to a
// 2560x1600 panel, and with K5 off CoreDisplay gets "Unsupported", finds no plane capabilities ("capabilities with no
// devices", "No plane indices") and never submits a display-pipe transaction (iop_ok, pipe_perform stay 0).
// Words: tag, pixel clock Hz, hact, hsync start, hsync end, htotal, vact, vsync start, vsync end, vtotal, mHz, h+, v+.
static bool xifbTimingFromDtd(const uint8_t *d, uint32_t w, uint32_t h, uint32_t *t)
{
    uint32_t clk = (d[0] | d[1] << 8) * 10000u; if (!clk) return false;
    uint32_t ha = d[2] | (d[4] & 0xf0) << 4, hb = d[3] | (d[4] & 0x0f) << 8;
    uint32_t va = d[5] | (d[7] & 0xf0) << 4, vb = d[6] | (d[7] & 0x0f) << 8;
    uint32_t hso = d[8] | (d[11] & 0xc0) << 2, hsw = d[9] | (d[11] & 0x30) << 4;
    uint32_t vso = (d[10] >> 4) | (d[11] & 0x0c) << 2, vsw = (d[10] & 0x0f) | (d[11] & 0x03) << 4;
    if (ha != w || va != h || !hsw || !vsw) return false;
    uint64_t tot = (uint64_t)(ha + hb) * (va + vb); if (!tot) return false;
    t[0] = 0x4b350001u; t[1] = clk; t[2] = ha; t[3] = ha + hso; t[4] = ha + hso + hsw; t[5] = ha + hb;
    t[6] = va; t[7] = va + vso; t[8] = va + vso + vsw; t[9] = va + vb;
    t[10] = (uint32_t)((uint64_t)clk * 1000ull / tot); t[11] = (d[17] >> 1) & 1; t[12] = (d[17] >> 2) & 1;
    return t[3] < t[4] && t[4] <= t[5] && t[7] < t[8] && t[8] <= t[9];
}
static bool xifbTiming(volatile uint32_t *r, const uint8_t *e, int len, uint32_t w, uint32_t h, uint32_t hz16, uint32_t *t)
{
    if (len >= 128) {
        for (int i = 0; i < 4; i++) if (xifbTimingFromDtd(e + 54 + 18 * i, w, h, t)) return true;
        if (len >= 256 && e[128] == 0x02)
            for (int o = e[130]; o >= 4 && o + 18 <= 127; o += 18) if (xifbTimingFromDtd(e + 128 + o, w, h, t)) return true;
    }
    if (!r || !w || !h) return false;
    static const uint32_t trans[2] = { 0x60000, 0x6f000 };   // transcoder A, then eDP
    for (uint32_t b : trans) {
        uint32_t ht = r[b / 4], hs = r[(b + 0x08) / 4], vt = r[(b + 0x0c) / 4], vs = r[(b + 0x14) / 4];
        if ((ht & 0x1fff) + 1 != w || (vt & 0x1fff) + 1 != h) continue;
        t[0] = 0x4b350001u; t[2] = w; t[3] = (hs & 0x1fff) + 1; t[4] = ((hs >> 16) & 0x1fff) + 1; t[5] = ((ht >> 16) & 0x1fff) + 1;
        t[6] = h; t[7] = (vs & 0x1fff) + 1; t[8] = ((vs >> 16) & 0x1fff) + 1; t[9] = ((vt >> 16) & 0x1fff) + 1;
        uint32_t hz = hz16 ? hz16 : (60u << 16);
        t[1] = (uint32_t)((uint64_t)t[5] * t[9] * hz >> 16); t[10] = (uint32_t)(((uint64_t)hz * 1000) >> 16); t[11] = 1; t[12] = 1;
        if (t[2] <= t[3] && t[3] < t[4] && t[4] <= t[5] && t[6] <= t[7] && t[7] < t[8] && t[8] <= t[9]) return true;
    }
    return false;
}

// Hardware cursor on pipe A's cursor plane. Without one IOFramebuffer draws a software cursor, every move damages a
// rect around it, and WindowServer recomposites blurred window backdrops there (the I-119 square).
// The GOP maps a 16 MB GGTT block at 0xff000000 for its 16,384,000-byte framebuffer; the 96 pages after it lie in
// i915's reserved top of GGTT, so pointing 64 of them at our own pages leaves everything else alone.
#define XIFB_CUR_DIM   256u
#define XIFB_CUR_GGTT  0xfffa0000u
#define XIFB_GSM       0x800000u                     // GGTT PTEs in BAR0
#define XIFB_CUR_CTL   0x70080
#define XIFB_CUR_BASE  0x70084
#define XIFB_CUR_POS   0x70088
#define XIFB_CUR_WM0   0x70140
#define XIFB_CUR_SAGV  0x70158
#define XIFB_CUR_BUF   0x7017c
#define XIFB_P1_BUF    0x7027c
#define XIFB_P1_SURF   0x7019c

class XeGfxIntelFramebuffer : public IONDRVFramebuffer {
    OSDeclareDefaultStructors(XeGfxIntelFramebuffer)
    uint8_t fEdid[256]; int fEdidLen = 0; uint32_t fHz16 = 0;
    uint32_t fW = 0, fH = 0, fRowBytes = 0;
    uint32_t fTiming[13] = {}; bool fTimingValid = false;   // 0.9.4: NVRMTiming words, also the detailed timing   // the raster pipe A scans (E16, after the HONOR A-22 patch)
    IOMemoryMap *fMmio = nullptr; volatile uint32_t *fR = nullptr;
    IOBufferMemoryDescriptor *fCurMem = nullptr; IOMemoryMap *fCurMap = nullptr; uint32_t *fCurKva = nullptr;
    uint64_t fCurPte[XIFB_CUR_DIM * XIFB_CUR_DIM * 4 / 4096] = {};
    IOSimpleLock *fCurLock = nullptr; bool fCurReady = false, fCurDdb = false, fCurOn = false;
    uint32_t rd(uint32_t o) { return fR[o / 4]; }
    void wr(uint32_t o, uint32_t v) { fR[o / 4] = v; }
    void waitFrame() { uint32_t a = rd(0x70040); for (int i = 0; i < 50 && rd(0x70040) == a; i++) IODelay(500); }
    // our PTEs, rewritten when anything else changed them; PAT index 2 (uncached) like i915 gives scanout on MTL
    void curPtes() {
        volatile uint64_t *g = (volatile uint64_t *)((volatile uint8_t *)fR + XIFB_GSM) + (XIFB_CUR_GGTT >> 12);
        bool chg = false;
        for (unsigned i = 0; i < sizeof fCurPte / sizeof fCurPte[0]; i++) if (g[i] != fCurPte[i]) { g[i] = fCurPte[i]; chg = true; }
        if (chg) { wr(0x101008, 1); (void)rd(0x101008); }
    }
    bool curSetup() {
        int off = 0;
        if (PE_parse_boot_argn("-xeintelfbnohwc", &off, sizeof off) || !fR) return false;
        if (rd(XIFB_CUR_CTL) || rd(XIFB_P1_SURF) != 0xff000000u || rd(XIFB_P1_BUF) != 0x07ff0000u) {
            XIFBLOG("hw cursor off: display not as the GOP left it (cur %08x surf %08x buf %08x)", rd(XIFB_CUR_CTL),
                    rd(XIFB_P1_SURF), rd(XIFB_P1_BUF));
            return false;
        }
        const size_t bytes = XIFB_CUR_DIM * XIFB_CUR_DIM * 4;
        fCurMem = IOBufferMemoryDescriptor::inTaskWithPhysicalMask(kernel_task, kIODirectionInOut, bytes, 0x7ffffff000ull);
        if (!fCurMem || fCurMem->prepare() != kIOReturnSuccess) { XIFBLOG("hw cursor off: no memory"); return false; }
        fCurMap = fCurMem->createMappingInTask(kernel_task, 0, kIOMapAnywhere | kIOMapWriteCombineCache);
        if (!fCurMap) { XIFBLOG("hw cursor off: no mapping"); return false; }
        fCurKva = (uint32_t *)fCurMap->getVirtualAddress();
        for (unsigned i = 0; i < sizeof fCurPte / sizeof fCurPte[0]; i++) {
            IOByteCount len = 0; addr64_t pa = fCurMem->getPhysicalSegment((IOByteCount)i * 4096, &len, kIOMemoryMapperNone);
            if (!pa || (pa & 0xfff)) { XIFBLOG("hw cursor off: page %u at %llx", i, (unsigned long long)pa); return false; }
            fCurPte[i] = pa | 1 | (1ull << 53);
        }
        bzero(fCurKva, bytes); __asm__ __volatile__("sfence" ::: "memory");
        fCurLock = IOSimpleLockAlloc();
        fCurReady = fCurLock != nullptr;
        XIFBLOG("hw cursor ready: %ux%u ARGB at GGTT %08x", XIFB_CUR_DIM, XIFB_CUR_DIM, XIFB_CUR_GGTT);
        return fCurReady;
    }
    // the GOP gave plane 1 all 2048 DBUF blocks; the cursor takes the last 32 (i915's single-pipe cursor share)
    void curDdb() {
        if (fCurDdb) return;
        wr(XIFB_P1_BUF, 0x07df0000u); wr(XIFB_P1_SURF, rd(XIFB_P1_SURF)); waitFrame(); waitFrame();
        wr(XIFB_CUR_BUF, 0x07ff07e0u);
        wr(XIFB_CUR_WM0, (1u << 31) | (3u << 14) | 8u);
        wr(XIFB_CUR_SAGV, (1u << 31) | (6u << 14) | 16u);
        fCurDdb = true;
    }
    void curRegs(SInt32 x, SInt32 y, bool on) {
        uint32_t pos = (x < 0 ? (1u << 15) | (uint32_t)(-x & 0xfff) : (uint32_t)(x & 0xfff)) |
                       (y < 0 ? (1u << 31) | ((uint32_t)(-y & 0xfff) << 16) : ((uint32_t)(y & 0xfff) << 16));
        wr(XIFB_CUR_POS, pos);
        wr(XIFB_CUR_CTL, on ? (1u << 14) | 0x23u : 0);  // trickle feed off, 256x256 ARGB (0x27 is 64x64)
        wr(XIFB_CUR_BASE, XIFB_CUR_GGTT);                // arms CTL, POS, WM and BUF_CFG
    }
    SInt32 fCurX = 0, fCurY = 0; bool fCurVis = false, fCurImg = false;
public:
    IOReturn getAttribute(IOSelect attr, uintptr_t *value) override {
        if (attr == kIOHardwareCursorAttribute) { if (value) *value = fCurReady; return kIOReturnSuccess; }
        return IONDRVFramebuffer::getAttribute(attr, value);
    }
    IOReturn setCursorImage(void *img) override {
        if (!fCurReady) return IONDRVFramebuffer::setCursorImage(img);
        const size_t bytes = XIFB_CUR_DIM * XIFB_CUR_DIM * 4;
        uint32_t *st = (uint32_t *)IOMalloc(bytes); if (!st) return kIOReturnNoMemory;
        bzero(st, bytes);
        IOHardwareCursorDescriptor d; bzero(&d, sizeof d);
        d.majorVersion = kHardwareCursorDescriptorMajorVersion; d.minorVersion = kHardwareCursorDescriptorMinorVersion;
        d.width = XIFB_CUR_DIM; d.height = XIFB_CUR_DIM; d.bitDepth = 32; d.supportedSpecialEncodings = kTransparentEncodedPixel;
        IOHardwareCursorInfo ci; bzero(&ci, sizeof ci);
        ci.majorVersion = kHardwareCursorInfoMajorVersion; ci.minorVersion = kHardwareCursorInfoMinorVersion;
        ci.hardwareCursorData = (UInt8 *)st;
        bool ok = convertCursorImage(img, &d, &ci) && ci.cursorWidth && ci.cursorHeight &&
                  ci.cursorWidth <= XIFB_CUR_DIM && ci.cursorHeight <= XIFB_CUR_DIM;
        if (ok) {
            // premultiplied ARGB, rows of 256 pixels
            for (unsigned y = 0; y < XIFB_CUR_DIM; y++)
                for (unsigned x = 0; x < XIFB_CUR_DIM; x++) {
                    uint32_t p = (y < ci.cursorHeight && x < ci.cursorWidth) ? st[y * ci.cursorWidth + x] : 0, a = p >> 24;
                    uint32_t r = (((p >> 16) & 255) * a + 127) / 255, g = (((p >> 8) & 255) * a + 127) / 255, b = ((p & 255) * a + 127) / 255;
                    fCurKva[y * XIFB_CUR_DIM + x] = (a << 24) | (r << 16) | (g << 8) | b;
                }
            __asm__ __volatile__("sfence" ::: "memory");
        }
        IOFree(st, bytes);
        static unsigned n; if (++n <= 4) XIFBLOG("hw cursor image %u: %s %ux%u", n, ok ? "ok" : "declined", (unsigned)ci.cursorWidth, (unsigned)ci.cursorHeight);
        if (!ok) return kIOReturnUnsupported;
        curDdb();   // once: waits two frames, so here (thread context) and not in setCursorState
        IOInterruptState is = IOSimpleLockLockDisableInterrupt(fCurLock);
        curPtes(); fCurImg = true; if (fCurDdb) curRegs(fCurX, fCurY, fCurVis);
        IOSimpleLockUnlockEnableInterrupt(fCurLock, is);
        return kIOReturnSuccess;
    }
    IOReturn setCursorState(SInt32 x, SInt32 y, bool visible) override {
        if (!fCurReady) return IONDRVFramebuffer::setCursorState(x, y, visible);
        IOInterruptState is = IOSimpleLockLockDisableInterrupt(fCurLock);
        fCurX = x; fCurY = y; fCurVis = visible;
        if (fCurDdb) curRegs(x, y, visible && fCurImg);
        IOSimpleLockUnlockEnableInterrupt(fCurLock, is);
        static unsigned n; if (++n <= 3) XIFBLOG("hw cursor state %u: %d,%d %s", n, (int)x, (int)y, visible ? "shown" : "hidden");
        return kIOReturnSuccess;
    }
    IOService *probe(IOService *provider, SInt32 *score) override {
        int off = 0;
        if (PE_parse_boot_argn("-xeintelfboff", &off, sizeof off)) { XIFBLOG("off by boot-arg"); return nullptr; }
        if (xifbGuardTripped()) { XIFBLOG("boot guard tripped (two starts without WindowServer): declining"); return nullptr; }
        return IONDRVFramebuffer::probe(provider, score);
    }
    bool start(IOService *provider) override {
        xifbGuardCount();
        // System Profiler names the GPU from the PCI device's "model"; without it About This Mac shows a bare "Display"
        if (!provider->getProperty("model")) {
            IOPCIDevice *pci = OSDynamicCast(IOPCIDevice, provider);
            const char *model = xifbModelName(pci ? pci->configRead16(kIOPCIConfigDeviceID) : 0);
            if (OSData *m = OSData::withBytes(model, (unsigned)strlen(model) + 1)) { provider->setProperty("model", m); m->release(); }
        }
        // System Profiler shows VRAM,totalMB of an Intel PCI device as "VRAM (Dynamic, Max)", else the 15 MB GOP
        // framebuffer. Same size ANV gives its heap: 3/4 of RAM above 4 GB, half below. xeintelfbvram=<MB> overrides.
        if (!provider->getProperty("VRAM,totalMB")) {
            uint32_t mb = 0;
            if (!PE_parse_boot_argn("xeintelfbvram", &mb, sizeof mb)) {
                uint64_t ram = 0; size_t len = sizeof ram;
                if (!sysctlbyname("hw.memsize", &ram, &len, nullptr, 0) && ram)
                    mb = (uint32_t)((ram <= (4ull << 30) ? ram / 2 : ram / 4 * 3) >> 20);
            }
            if (mb) { provider->setProperty("VRAM,totalMB", (unsigned long long)mb, 32); XIFBLOG("VRAM,totalMB %u", mb); }
        }
        // the guard is for boots that hang: still running 120 s after start clears it. IOGraphics keeps the
        // WindowServer-active attribute and WindowServer's connection skips newUserClient here (N-282 to N-284)
        static thread_call_t tc;
        if (!tc) tc = thread_call_allocate([](thread_call_param_t, thread_call_param_t) { xifbGuardClear(); }, nullptr);
        if (tc) { uint64_t dl; clock_interval_to_deadline(120, kSecondScale, &dl); thread_call_enter_delayed(tc, dl); }
        if (IOPCIDevice *pci = OSDynamicCast(IOPCIDevice, provider)) {
            int off = 0;
            if (!PE_parse_boot_argn("-xeintelfbnoedid", &off, sizeof off))
                if (IOMemoryMap *m = pci->mapDeviceMemoryWithRegister(kIOPCIConfigBaseAddress0)) {
                    gRegs = (volatile uint32_t *)m->getVirtualAddress();
                    if (xifbReadEdid(fEdid, &fEdidLen))
                        XIFBLOG("EDID %d B, maker %02x%02x product %02x%02x, %ux%u mm", fEdidLen, fEdid[8], fEdid[9], fEdid[11],
                                fEdid[10], fEdid[21] * 10, fEdid[22] * 10);
                    else { fEdidLen = 0; XIFBLOG("EDID: AUX A read failed, the display stays unnamed"); }
                    uint32_t meas = xifbMeasureHz();
                    fHz16 = fEdidLen ? xifbSnapHz(fEdid, fEdidLen, meas) : meas;
                    XIFBLOG("refresh measured %u.%02u Hz, reported %u.%02u Hz", meas >> 16, ((meas & 0xffff) * 100) >> 16,
                            fHz16 >> 16, ((fHz16 & 0xffff) * 100) >> 16);
                    gRegs = nullptr; fMmio = m; fR = (volatile uint32_t *)m->getVirtualAddress();
                    {   // PLANE_SIZE holds (h-1)<<16 | (w-1); a linear PLANE_STRIDE counts 64-byte units
                        uint32_t size = fR[0x70190 / 4], stride = fR[0x70188 / 4] & 0x7ff;
                        fW = (size & 0xffff) + 1; fH = ((size >> 16) & 0xffff) + 1; fRowBytes = stride * 64u;
                        if (!fRowBytes) fRowBytes = fW * 4;
                        XIFBLOG("scanout geometry for accel: %ux%u rowBytes %u", fW, fH, fRowBytes);
                    }
                    {
                        uint32_t t[13] = {};
                        if (xifbTiming(fR, fEdid, fEdidLen, fW, fH, fHz16, t)) {
                            memcpy(fTiming, t, sizeof fTiming); fTimingValid = true;
                            if (OSData *d = OSData::withBytes(t, sizeof t)) { setProperty("NVRMTiming", d); d->release(); }
                            XIFBLOG("NVRMTiming for AGDC K5: %u Hz clock, %u %u %u %u / %u %u %u %u, %u mHz, sync %c%c", t[1], t[2], t[3],
                                    t[4], t[5], t[6], t[7], t[8], t[9], t[10], t[11] ? '+' : '-', t[12] ? '+' : '-');
                        } else XIFBLOG("NVRMTiming: no timing for %ux%u (no matching EDID DTD or transcoder)", fW, fH);
                    }
                }
        }
        if (!curSetup()) fCurReady = false;
        // E16 (as the HONOR 255H's A-20 patch): XeGfxAGDC builds its slot table from IOFBDependentIndex, and a
        // framebuffer without one is left out ("n=0"), so IOPresentment finds no display pipe. Set before start().
        setProperty("IOFBDependentID", 0x5845474600000001ull, 64);
        setProperty("IOFBDependentIndex", 0ull, 32);
        xifbPublishDetailedTimings();
        const bool started = IONDRVFramebuffer::start(provider);
        if (started) xifbPublishDetailedTimings();   // after the base class built its mode list
        return started;
    }
    // The accelerator and CoreDisplay ask these while wiring the display pipe; IONDRVFramebuffer forwards them to an NDRV
    // this machine does not have ("Failed to obtain mode info"), so answer from the raster measured above. The mode ID is
    // the one the base class published: CoreDisplay indexes its mode list with it. (HONOR 255H A-22/A-22b)
    IOReturn getCurrentDisplayMode(IODisplayModeID *mode, IOIndex *depth) override {
        if (!mode || !depth) return kIOReturnBadArgument;
        if (kIOReturnSuccess == IONDRVFramebuffer::getCurrentDisplayMode(mode, depth)) return kIOReturnSuccess;
        IODisplayModeID m = 0;
        if (getDisplayModeCount() && kIOReturnSuccess == getDisplayModes(&m)) { *mode = m; *depth = 0; return kIOReturnSuccess; }
        XIFBLOG("getCurrentDisplayMode: no mode list to answer from");
        return kIOReturnUnsupported;
    }
    IOReturn getStartupDisplayMode(IODisplayModeID *mode, IOIndex *depth) override { return getCurrentDisplayMode(mode, depth); }
    IOReturn getPixelInformation(IODisplayModeID mode, IOIndex depth, IOPixelAperture aperture, IOPixelInformation *pi) override {
        if (!pi || aperture != kIOFBSystemAperture) return kIOReturnUnsupportedMode;
        if (!fW || !fH || !fRowBytes) return IONDRVFramebuffer::getPixelInformation(mode, depth, aperture, pi);
        IODisplayModeInformation mi; bzero(&mi, sizeof mi);
        if (kIOReturnSuccess != IONDRVFramebuffer::getInformationForDisplayMode(mode, &mi)) return kIOReturnUnsupportedMode;
        bzero(pi, sizeof(*pi));
        pi->bytesPerRow = fRowBytes; pi->bytesPerPlane = 0; pi->bitsPerPixel = 32; pi->pixelType = kIORGBDirectPixels;
        pi->componentCount = 3; pi->bitsPerComponent = 8;
        pi->componentMasks[0] = 0x00FF0000; pi->componentMasks[1] = 0x0000FF00; pi->componentMasks[2] = 0x000000FF;
        strlcpy(pi->pixelFormat, IO32BitDirectPixels, sizeof(pi->pixelFormat));
        pi->activeWidth = fW; pi->activeHeight = fH;
        static unsigned logged; if (logged++ < 4) XIFBLOG("scanout described: mode %#x depth %u %ux%u rowBytes %u", (unsigned)mode, (unsigned)depth, fW, fH, fRowBytes);
        return kIOReturnSuccess;
    }
    bool hasDDCConnect(IOIndex ci) override { return fEdidLen ? true : IONDRVFramebuffer::hasDDCConnect(ci); }
    IOReturn getDDCBlock(IOIndex ci, UInt32 block, IOSelect type, IOOptionBits opt, UInt8 *data, IOByteCount *len) override {
        if (!fEdidLen) return IONDRVFramebuffer::getDDCBlock(ci, block, type, opt, data, len);
        if (!data || !len || block < 1 || (int)(block * 128) > fEdidLen) return kIOReturnUnsupported;
        IOByteCount n = *len < 128 ? *len : 128; bcopy(fEdid + (block - 1) * 128, data, n); *len = n;
        return kIOReturnSuccess;
    }
    IOReturn getAttributeForConnection(IOIndex ci, IOSelect attr, uintptr_t *value) override {
        if (fEdidLen && attr == kConnectionSupportsHLDDCSense) return kIOReturnSuccess;
        return IONDRVFramebuffer::getAttributeForConnection(ci, attr, value);
    }
    // the panel's size and refresh, and ValidForHiRes so the 2x sizes reach Displays settings (I-059 on NVRMFB)
    // 0.9.4 (ArrowWhatever 0003/0010, refresh.md): an IONDRV framebuffer describes its mode with no detailed timing,
    // so IOFBBuildModeList records IOFB0Hz, CGDisplayMode reports 0 Hz and WindowServer paces CVDisplayLink at 30 Hz.
    // Publish the panel's timing (the record K5 answers from) both ways: IOFBDetailedTimings and
    // getTimingInfoForDisplayMode for the panel's own mode. min == max pixel clock, or setVBLTiming drops the VBL delta.
    static bool xifbNoDt() { int v = 0; return PE_parse_boot_argn("-xeintelfbnodt", &v, sizeof v); }
    void xifbFillDetailedTiming(IODetailedTimingInformationV2 &d) const {
        bzero(&d, sizeof d);
        d.pixelClock = fTiming[1]; d.minPixelClock = d.pixelClock; d.maxPixelClock = d.pixelClock;
        d.horizontalActive = fTiming[2]; d.horizontalBlanking = fTiming[5] - fTiming[2];
        d.horizontalSyncOffset = fTiming[3] - fTiming[2]; d.horizontalSyncPulseWidth = fTiming[4] - fTiming[3];
        d.verticalActive = fTiming[6]; d.verticalBlanking = fTiming[9] - fTiming[6];
        d.verticalSyncOffset = fTiming[7] - fTiming[6]; d.verticalSyncPulseWidth = fTiming[8] - fTiming[7];
        d.horizontalSyncConfig = fTiming[11] ? kIOSyncPositivePolarity : 0;
        d.verticalSyncConfig = fTiming[12] ? kIOSyncPositivePolarity : 0;
        d.numLinks = 1; d.pixelEncoding = 1; d.bitsPerColorComponent = 1; d.colorimetry = 1; d.dynamicRange = 1;
        d.horizontalScaled = d.horizontalActive; d.verticalScaled = d.verticalActive;
    }
    void xifbPublishDetailedTimings() {
        if (!fTimingValid || xifbNoDt()) return;
        IODetailedTimingInformationV2 d; xifbFillDetailedTiming(d);
        OSData *o = OSData::withBytes(&d, sizeof d); OSArray *a = o ? OSArray::withCapacity(1) : nullptr;
        if (a) { a->setObject(o); setProperty("IOFBDetailedTimings", a); }
        OSSafeReleaseNULL(a); OSSafeReleaseNULL(o);
        static int said; if (said++ < 2) XIFBLOG("IOFBDetailedTimings: %ux%u, %u kHz, %u mHz", fTiming[2], fTiming[6], fTiming[1] / 1000, fTiming[10]);
    }
    IOReturn getTimingInfoForDisplayMode(IODisplayModeID mode, IOTimingInformation *info) override {
        if (!info) return kIOReturnBadArgument;
        if (!fTimingValid || xifbNoDt()) return IONDRVFramebuffer::getTimingInfoForDisplayMode(mode, info);
        IODisplayModeInformation mi = {};
        if (kIOReturnSuccess != IONDRVFramebuffer::getInformationForDisplayMode(mode, &mi) || mi.nominalWidth != fTiming[2] || mi.nominalHeight != fTiming[6])
            return IONDRVFramebuffer::getTimingInfoForDisplayMode(mode, info);
        xifbFillDetailedTiming(info->detailedInfo.v2);
        info->flags |= kIODetailedTimingValid; info->flags &= ~kIOScalingInfoValid;
        info->appleTimingID = (IOAppleTimingID)kIOTimingIDInvalid;
        static int said; if (said++ < 3) XIFBLOG("detailed timing for mode %#x: %ux%u, %u kHz", (unsigned)mode, fTiming[2], fTiming[6], fTiming[1] / 1000);
        return kIOReturnSuccess;
    }
    IOReturn validateDetailedTiming(void *, IOByteCount) override { return kIOReturnUnsupported; }
    IOReturn setDetailedTimings(OSArray *) override { return kIOReturnUnsupported; }
    IOReturn getInformationForDisplayMode(IODisplayModeID mode, IODisplayModeInformation *info) override {
        IOReturn r = IONDRVFramebuffer::getInformationForDisplayMode(mode, info);
        if (r != kIOReturnSuccess || !info) return r;
        if (fHz16) info->refreshRate = fHz16;
        if (fEdidLen && fEdid[21] && fEdid[22]) { info->imageWidth = fEdid[21] * 10; info->imageHeight = fEdid[22] * 10; }
        info->flags |= kDisplayModeValidForHiResFlag;
        return r;
    }
};

OSDefineMetaClassAndStructors(XeGfxIntelFramebuffer, IONDRVFramebuffer)
