// dlprobe: what pace does WindowServer give this display? CGDisplayMode refresh, CVDisplayLink nominal and actual
// period, and the measured callback rate over 3 s.
#include <CoreVideo/CoreVideo.h>
#include <CoreGraphics/CoreGraphics.h>
#include <stdio.h>
#include <unistd.h>
#include <mach/mach_time.h>
static volatile int gN; static uint64_t gT0, gT1;
static CVReturn cb(CVDisplayLinkRef l, const CVTimeStamp *now, const CVTimeStamp *out, CVOptionFlags fi, CVOptionFlags *fo, void *ctx) {
    uint64_t t = mach_absolute_time(); if (!gN) gT0 = t; gT1 = t; gN++; return kCVReturnSuccess; }
int main(void) {
    CGDirectDisplayID d = CGMainDisplayID();
    CGDisplayModeRef m = CGDisplayCopyDisplayMode(d);
    printf("display 0x%x  mode %zux%zu (pixels %zux%zu)  CGDisplayMode refresh %.3f Hz\n", d,
           CGDisplayModeGetWidth(m), CGDisplayModeGetHeight(m), CGDisplayModeGetPixelWidth(m), CGDisplayModeGetPixelHeight(m),
           CGDisplayModeGetRefreshRate(m));
    CVDisplayLinkRef l = NULL;
    if (CVDisplayLinkCreateWithCGDisplay(d, &l) != kCVReturnSuccess || !l) { printf("CVDisplayLinkCreate failed\n"); return 1; }
    CVTime nom = CVDisplayLinkGetNominalOutputVideoRefreshPeriod(l);
    printf("CVDisplayLink nominal: %lld/%d -> %.3f Hz\n", nom.timeValue, nom.timeScale, nom.timeValue ? (double)nom.timeScale / nom.timeValue : 0);
    CVDisplayLinkSetOutputCallback(l, cb, NULL); CVDisplayLinkStart(l); sleep(3);
    printf("CVDisplayLink actual : %.3f Hz\n", 1.0 / CVDisplayLinkGetActualOutputVideoRefreshPeriod(l));
    CVDisplayLinkStop(l);
    mach_timebase_info_data_t tb; mach_timebase_info(&tb);
    double s = (double)(gT1 - gT0) * tb.numer / tb.denom / 1e9;
    printf("callbacks: %d in %.2f s -> %.2f per second  <== the pace WindowServer gives this display\n", gN, s, gN > 1 ? (gN - 1) / s : 0);
    return 0;
}
