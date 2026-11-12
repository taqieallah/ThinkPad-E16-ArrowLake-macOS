// xe-m2v-bench (K14 phase 2a): the same desktop-like CoreAnimation work timed on two Metal devices of the E16:
//   old - MTLCreateSystemDefaultDevice(): today's NVMTLDriver (Metal -> our translator -> ANV)
//   new - UniXNU's AdrenoMetal frontend + metal2vulkan bridge, opened in this process over the same ANV
// Nothing is installed: the new stack lives only in this program. Usage: xe-m2v-bench old|new <loader> <cache> [quartzcore.metallib]
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreImage/CoreImage.h>
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <set>
#include <string>
#include <vector>
#include "NativeBridgeMetalFrontend.h"

static std::set<std::string> gMissing;
static void onMissing(const char *cls, const char *sel) {
    if (gMissing.insert(std::string(cls) + " " + sel).second) std::fprintf(stderr, "  missing: %s %s\n", cls, sel);
}
static CGColorRef rgba(double r, double g, double b, double a) {
    static CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    const CGFloat c[4] = {(CGFloat)r, (CGFloat)g, (CGFloat)b, (CGFloat)a};
    return (CGColorRef)CFAutorelease(CGColorCreate(space, c));
}
static double ms(uint64_t ns) { return ns / 1e6; }
static uint64_t now() { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

// A desktop-ish tree: wallpaper, 12 rounded shadowed translucent "windows", 2 blurred panels (Dock/menu bar), all moving every frame.
static void scene(CALayer *root, CGFloat w, CGFloat h, std::vector<CALayer *> &moving, bool blur) {
    root.frame = CGRectMake(0, 0, w, h);
    root.backgroundColor = rgba(0.15, 0.35, 0.6, 1);
    for (int i = 0; i < 12; i++) {
        CALayer *win = [CALayer layer];
        win.frame = CGRectMake(60 + i * 90, 80 + (i % 4) * 160, 640, 420);
        win.backgroundColor = rgba(0.95, 0.95, 0.97, 0.92);
        win.cornerRadius = 12;
        win.shadowOpacity = 0.45; win.shadowRadius = 22; win.shadowOffset = CGSizeMake(0, -8);
        win.borderWidth = 1; win.borderColor = rgba(0, 0, 0, 0.15);
        for (int k = 0; k < 6; k++) {
            CALayer *row = [CALayer layer];
            row.frame = CGRectMake(16, 20 + k * 60, 600, 40);
            row.backgroundColor = rgba(0.2 + k * 0.1, 0.5, 0.8 - k * 0.1, 0.6);
            row.cornerRadius = 6;
            [win addSublayer:row];
        }
        [root addSublayer:win];
        moving.push_back(win);
    }
    if (blur) {
        for (int i = 0; i < 2; i++) {
            CALayer *panel = [CALayer layer];
            panel.frame = i ? CGRectMake(0, h - 30, w, 30) : CGRectMake(w / 2 - 500, 10, 1000, 90);
            panel.backgroundColor = rgba(1, 1, 1, 0.25);
            panel.cornerRadius = i ? 0 : 20;
            panel.masksToBounds = YES;
            CIFilter *f = [CIFilter filterWithName:@"CIGaussianBlur"];
            [f setValue:@20 forKey:kCIInputRadiusKey];
            panel.backgroundFilters = @[f];
            [root addSublayer:panel];
        }
    }
}

static void run(id<MTLDevice> dev, const char *label, bool blur, int frames) {
    const NSUInteger W = 1920, H = 1200;
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:W height:H mipmapped:NO];
    d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    d.storageMode = MTLStorageModePrivate;
    id<MTLTexture> target = [dev newTextureWithDescriptor:d];
    id<MTLCommandQueue> queue = [dev newCommandQueue];
    if (!target || !queue) { std::printf("%-10s FAIL target/queue\n", label); return; }
    CALayer *root = [CALayer layer];
    std::vector<CALayer *> moving;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    scene(root, W, H, moving, blur);
    [CATransaction commit]; [CATransaction flush];
    CARenderer *r = [CARenderer rendererWithMTLTexture:target options:@{kCARendererMetalCommandQueue: queue}];
    if (!r) { std::printf("%-10s FAIL CARenderer\n", label); return; }
    r.layer = root; r.bounds = root.frame;
    std::vector<double> t;
    double first = 0;
    for (int f = 0; f < frames; f++) {
        @autoreleasepool {
            [CATransaction begin]; [CATransaction setDisableActions:YES];
            for (size_t i = 0; i < moving.size(); i++) {
                CALayer *l = moving[i];
                l.position = CGPointMake(400 + i * 90 + 200 * sin((f + i * 7) * 0.05), 300 + (i % 4) * 150 + 120 * cos((f + i * 3) * 0.04));
            }
            [CATransaction commit]; [CATransaction flush];
            const uint64_t t0 = now();
            [r beginFrameAtTime:CACurrentMediaTime() timeStamp:NULL];
            [r addUpdateRect:r.bounds];
            [r render];
            [r endFrame];
            id<MTLCommandBuffer> fence = [queue commandBuffer];
            [fence commit]; [fence waitUntilCompleted];
            const double dt = ms(now() - t0);
            if (f == 0) first = dt; else t.push_back(dt);
        }
    }
    std::sort(t.begin(), t.end());
    double sum = 0; for (double v : t) sum += v;
    const double avg = t.empty() ? 0 : sum / t.size();
    std::printf("%-10s %-8s first %7.1f ms | avg %6.2f ms (%5.1f fps)  p95 %6.2f  max %6.2f\n", label, blur ? "blur" : "plain", first, avg,
                avg > 0 ? 1000.0 / avg : 0, t.empty() ? 0 : t[t.size() * 95 / 100], t.empty() ? 0 : t.back());
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 4) { std::fprintf(stderr, "usage: %s old|new loader cache [metallib]\n", argv[0]); return 2; }
        const bool isNew = !strcmp(argv[1], "new");
        const uint64_t t0 = now();
        id<MTLDevice> dev = isNew ? native_bridge_metal_open(argv[2], argv[3], 0x7865, onMissing) : MTLCreateSystemDefaultDevice();
        if (!dev) { std::printf("%s: FAIL no device\n", argv[1]); return 1; }
        std::printf("%s device: %s (open %.1f ms)\n", argv[1], dev.name.UTF8String, ms(now() - t0));
        const char *label = isNew ? "NEW(m2v)" : "OLD(nvmtl)";
        // XE_FRAMES: frames per scene (default 120); XE_SCENE=plain|blur: only that scene (k14c-profile samples a long run)
        const int frames = getenv("XE_FRAMES") ? atoi(getenv("XE_FRAMES")) : 120;
        const char *only = getenv("XE_SCENE");
        if (!only || !strcmp(only, "plain")) run(dev, label, false, frames);
        if (!only || !strcmp(only, "blur")) run(dev, label, true, frames);
        if (argc > 4 && argv[4][0]) {
            char out[2048] = {};
            native_bridge_metal_benchmark(dev, argv[4], 40, out, sizeof out);
            std::printf("%s quartzcore pipelines:\n%s\n", label, out);
        }
        if (!gMissing.empty()) std::printf("%zu missing selectors (listed above on stderr)\n", gMissing.size());
        if (isNew) { char s[512] = {}; native_bridge_metal_status(s, sizeof s); std::printf("status: %s\n", s); }
    }
    return 0;
}
