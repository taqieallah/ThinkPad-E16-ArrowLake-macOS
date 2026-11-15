#include "panel.hpp"

#include <IOKit/IOKitLib.h>
#include <IOSurface/IOSurface.h>
#include <CoreFoundation/CoreFoundation.h>

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "reims_vgpu.h"
#include "xg_panel_abi.h"

namespace e16 {
namespace {

IOReturn panelCall(uint32_t connection, struct xg_panel_request *request,
                   struct xg_panel_reply *reply) {
    size_t replySize = sizeof(*reply);
    request->struct_size = sizeof(*request);
    reply->struct_size = sizeof(*reply);
    return IOConnectCallStructMethod(connection, XG_PANEL_SELECTOR, request, sizeof(*request),
                                     reply, &replySize);
}

} // namespace

PanelClient::~PanelClient() { close(); }

bool PanelClient::open(const char *serviceName, uint32_t clientType) {
    close();
    CFMutableDictionaryRef matching = IOServiceMatching(serviceName);
    if (!matching)
        return false;
    service_ = IOServiceGetMatchingService(kIOMainPortDefault, matching);
    if (!service_)
        return false;
    const IOReturn kr = IOServiceOpen(service_, mach_task_self(), clientType, &connection_);
    if (kr != kIOReturnSuccess) {
        std::printf("panel: IOServiceOpen('%s', type 0x%x) failed: 0x%08x\n", serviceName,
                    clientType, kr);
        IOObjectRelease(service_);
        service_ = 0;
        connection_ = 0;
        return false;
    }
    PanelMode mode = {};
    if (!info(mode)) {
        std::printf("panel: XeGfx panel interface did not answer INFO\n");
        close();
        return false;
    }
    std::printf("panel: XeGfx pipe %u %ux%u pitch %u format 0x%x @ %u Hz\n", mode.pipe, mode.width,
                mode.height, mode.pitch, mode.format, mode.refresh_hz);
    return true;
}

void PanelClient::close() {
    if (connection_) {
        IOServiceClose(connection_);
        connection_ = 0;
    }
    if (service_) {
        IOObjectRelease(service_);
        service_ = 0;
    }
}

uint32_t PanelClient::request(uint32_t op, uint32_t surfaceId, uint32_t sequence,
                              uint32_t timeoutMs, uint32_t flags, PanelMode *mode) {
    if (!connection_)
        return XG_PANEL_ERR_STATE;
    struct xg_panel_request req = {};
    struct xg_panel_reply rep = {};
    req.op = op;
    req.surface_id = surfaceId;
    req.sequence = sequence;
    req.timeout_ms = timeoutMs;
    req.flags = flags;
    const IOReturn kr = panelCall(connection_, &req, &rep);
    if (kr != kIOReturnSuccess) {
        std::printf("panel: op %u failed: 0x%08x\n", op, kr);
        return XG_PANEL_ERR_STATE;
    }
    if (rep.status == XG_PANEL_OK && mode) {
        mode->pipe = rep.pipe;
        mode->width = rep.width;
        mode->height = rep.height;
        mode->pitch = rep.pitch;
        mode->format = rep.format;
        mode->refresh_hz = rep.refresh_hz;
    }
    if (rep.status == XG_PANEL_OK)
        presentCount_ = rep.present_count;
    return rep.status;
}

bool PanelClient::info(PanelMode &mode) {
    return request(XG_PANEL_OP_INFO, 0, 0, 0, 0, &mode) == XG_PANEL_OK && mode.width &&
           mode.height && mode.pitch;
}

bool PanelClient::acquire() {
    const uint32_t status = request(XG_PANEL_OP_ACQUIRE, 0, 0, 0, 0, nullptr);
    if (status != XG_PANEL_OK)
        std::printf("panel: ACQUIRE refused (status %u)\n", status);
    return status == XG_PANEL_OK;
}

bool PanelClient::present(uint32_t surfaceId, uint32_t sequence, uint32_t timeoutMs) {
    const uint32_t status =
        request(XG_PANEL_OP_PRESENT, surfaceId, sequence, timeoutMs, 0, nullptr);
    if (status != XG_PANEL_OK) {
        std::printf("panel: PRESENT surface %u refused (status %u)\n", surfaceId, status);
        return false;
    }
    return true;
}

bool PanelClient::release(bool restoreOriginal) {
    return request(XG_PANEL_OP_RELEASE, 0, 0, 0, restoreOriginal ? 1u : 0u, nullptr) ==
           XG_PANEL_OK;
}

// ---------------------------------------------------------------------------
// Display pipeline
// ---------------------------------------------------------------------------
namespace {

void logFrames(const DisplayPipeline &p) {
    std::printf("display: guest=%llu host=%llu sent=%llu\n",
                static_cast<unsigned long long>(p.guestPresents),
                static_cast<unsigned long long>(p.hostPresents),
                static_cast<unsigned long long>(p.framesSent));
}

} // namespace

bool displayStart(DisplayPipeline &pipeline, RvgDevice *device, PanelClient *panel, char *why,
                  size_t whyLength) {
    auto fail = [&](const char *message) {
        std::snprintf(why, whyLength, "%s", message);
        displayStop(pipeline);
        return false;
    };
    pipeline.device = device;
    pipeline.panel = panel;

    if (!panel || !panel->usable())
        return fail("no XeGfx panel client");

    RvgDisplayConfig config = {};
    config.struct_size = sizeof(RvgDisplayConfig);
    config.serial_number = 1;
    config.port = 0;
    config.name = "XeGfx Panel";
    config.name_length = std::strlen("XeGfx Panel");
    config.width_millimeters = 330.0;
    config.height_millimeters = 210.0;
    config.callbacks = nullptr;
    config.window = nullptr;
    RvgStatus status = rvg_display_create(device, &config, &pipeline.display);
    if (status != RVG_OK || !pipeline.display) {
        std::snprintf(why, whyLength, "rvg_display_create: %u (%s)", status,
                      rvg_status_message(status));
        return false;
    }

    RvgDisplayMode mode = {};
    mode.width = static_cast<uint16_t>(panel->usable() ? pipeline.mode.width : 0);
    PanelMode panelMode = {};
    if (!panel->info(panelMode))
        return fail("panel INFO before display start");
    pipeline.mode = panelMode;
    mode.width = static_cast<uint16_t>(panelMode.width);
    mode.height = static_cast<uint16_t>(panelMode.height);
    mode.flags = 0;
    mode.refresh_rate_hz = panelMode.refresh_hz ? panelMode.refresh_hz : 60.0;
    rvg_display_set_modes(pipeline.display, &mode, 1);

    RvgFrameTargetConfig targetConfig = {};
    targetConfig.struct_size = sizeof(RvgFrameTargetConfig);
    targetConfig.width = panelMode.width;
    targetConfig.height = panelMode.height;
    targetConfig.format = RVG_PIXEL_FORMAT_BGRA8_UNORM;
    status = rvg_frame_target_create(device, &targetConfig, &pipeline.target);
    if (status != RVG_OK || !pipeline.target) {
        std::snprintf(why, whyLength, "rvg_frame_target_create: %u (%s)", status,
                      rvg_status_message(status));
        return false;
    }

    const size_t rowBytes = static_cast<size_t>(panelMode.width) * 4;
    pipeline.stagingLength = rowBytes * panelMode.height;
    pipeline.staging = std::calloc(1, pipeline.stagingLength);
    if (!pipeline.staging)
        return fail("no staging buffer");

    CFMutableDictionaryRef properties = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (!properties)
        return fail("no IOSurface properties");
    int32_t width = static_cast<int32_t>(panelMode.width);
    int32_t height = static_cast<int32_t>(panelMode.height);
    int32_t bytesPerRow = static_cast<int32_t>(panelMode.pitch ? panelMode.pitch : rowBytes);
    int32_t pixelFormat = static_cast<int32_t>('BGRA');
    CFNumberRef widthRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &width);
    CFNumberRef heightRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &height);
    CFNumberRef rowRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &bytesPerRow);
    CFNumberRef formatRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &pixelFormat);
    if (!widthRef || !heightRef || !rowRef || !formatRef) {
        fail("IOSurface property allocation");
        if (widthRef) CFRelease(widthRef);
        if (heightRef) CFRelease(heightRef);
        if (rowRef) CFRelease(rowRef);
        if (formatRef) CFRelease(formatRef);
        CFRelease(properties);
        return false;
    }
    CFDictionarySetValue(properties, kIOSurfaceWidth, widthRef);
    CFDictionarySetValue(properties, kIOSurfaceHeight, heightRef);
    CFDictionarySetValue(properties, kIOSurfaceBytesPerRow, rowRef);
    CFDictionarySetValue(properties, kIOSurfacePixelFormat, formatRef);
    CFDictionarySetValue(properties, kIOSurfaceIsGlobal, kCFBooleanTrue);
    for (int i = 0; i < DisplayPipeline::kSurfaces; ++i)
        pipeline.surfaces[i] = IOSurfaceCreate(properties);
    CFRelease(widthRef);
    CFRelease(heightRef);
    CFRelease(rowRef);
    CFRelease(formatRef);
    CFRelease(properties);
    for (int i = 0; i < DisplayPipeline::kSurfaces; ++i) {
        if (!pipeline.surfaces[i])
            return fail("IOSurfaceCreate");
    }
    pipeline.active = true;
    rvg_display_present_counts(pipeline.display, &pipeline.guestPresents, &pipeline.hostPresents);
    std::printf("display: Reims display port 0 at %ux%u, frame target %ux%u, %d IOSurfaces "
                "(first id %u)\n",
                panelMode.width, panelMode.height, panelMode.width, panelMode.height,
                DisplayPipeline::kSurfaces,
                IOSurfaceGetID(static_cast<IOSurfaceRef>(pipeline.surfaces[0])));
    return true;
}

bool displayFrame(DisplayPipeline &pipeline) {
    if (!pipeline.active || !pipeline.panel || !pipeline.panel->usable())
        return false;
    uint64_t guest = 0;
    uint64_t host = 0;
    rvg_display_present_counts(pipeline.display, &guest, &host);
    if (guest == pipeline.guestPresents)
        return false; // nothing new from the guest
    pipeline.guestPresents = guest;
    pipeline.hostPresents = host;

    RvgFrame *frame = nullptr;
    RvgStatus status = rvg_display_encode_frame(pipeline.display, pipeline.target, nullptr, &frame);
    if (status != RVG_OK || !frame) {
        std::printf("display: encode failed %u (%s)\n", status, rvg_status_message(status));
        return false;
    }
    status = rvg_frame_commit(frame);
    if (status != RVG_OK) {
        std::printf("display: commit failed %u (%s)\n", status, rvg_status_message(status));
        rvg_frame_release(frame);
        return false;
    }
    status = rvg_frame_wait(frame);
    rvg_frame_release(frame);
    if (status != RVG_OK) {
        std::printf("display: frame wait failed %u (%s)\n", status, rvg_status_message(status));
        return false;
    }

    const size_t rowBytes = static_cast<size_t>(pipeline.mode.width) * 4;
    status = rvg_frame_target_read_pixels(pipeline.target, pipeline.staging, rowBytes,
                                          pipeline.stagingLength);
    if (status != RVG_OK) {
        std::printf("display: read_pixels failed %u (%s)\n", status, rvg_status_message(status));
        return false;
    }

    IOSurfaceRef surface =
        static_cast<IOSurfaceRef>(pipeline.surfaces[pipeline.nextSurface]);
    pipeline.nextSurface = (pipeline.nextSurface + 1) % DisplayPipeline::kSurfaces;
    const size_t surfacePitch = static_cast<size_t>(pipeline.mode.pitch);
    if (IOSurfaceLock(surface, 0, nullptr) != kIOReturnSuccess) {
        std::printf("display: IOSurfaceLock failed\n");
        return false;
    }
    auto *base = static_cast<uint8_t *>(IOSurfaceGetBaseAddress(surface));
    for (uint32_t row = 0; row < pipeline.mode.height; ++row)
        std::memcpy(base + row * surfacePitch, static_cast<uint8_t *>(pipeline.staging) +
                                                    row * rowBytes, rowBytes);
    IOSurfaceUnlock(surface, 0, nullptr);

    if (!pipeline.panel->present(IOSurfaceGetID(surface), static_cast<uint32_t>(++pipeline.framesSent),
                                 0)) {
        return false;
    }
    if ((pipeline.framesSent % 60) == 1)
        logFrames(pipeline);
    return true;
}

void displayStop(DisplayPipeline &pipeline) {
    if (pipeline.panel && pipeline.panel->usable()) {
        pipeline.panel->release(true);
        pipeline.panel->close();
    }
    if (pipeline.target) {
        rvg_frame_target_release(pipeline.target);
        pipeline.target = nullptr;
    }
    for (int i = 0; i < DisplayPipeline::kSurfaces; ++i) {
        if (pipeline.surfaces[i]) {
            CFRelease(static_cast<IOSurfaceRef>(pipeline.surfaces[i]));
            pipeline.surfaces[i] = nullptr;
        }
    }
    if (pipeline.display) {
        rvg_display_release(pipeline.display);
        pipeline.display = nullptr;
    }
    if (pipeline.staging) {
        std::free(pipeline.staging);
        pipeline.staging = nullptr;
    }
    pipeline.active = false;
}

} // namespace e16
