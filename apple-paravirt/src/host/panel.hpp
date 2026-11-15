// Reims -> XeGfx panel path.
//
// The daemon renders no GPU work itself for the panel: it asks Reims to encode
// the display's current frame into a frame target (a Metal texture Reims owns),
// waits for the GPU, reads the pixels back, copies them into an IOSurface, and
// hands that IOSurface to the patched XeGfxAccel, which scans it out on the
// internal panel.
//
// The guest (AppleParavirtGPU) drives the display: Reims' display port 0 is the
// guest's display, whose modes are the panel's modes. A frame is presented only
// after the guest has presented one (the guest present count advances), so the
// panel keeps showing its previous content until the paravirtual display has
// something to show.
#pragma once

#include <stddef.h>
#include <stdint.h>

struct RvgDevice;
struct RvgDisplay;
struct RvgFrameTarget;

namespace e16 {

struct PanelMode {
    uint32_t width = 0;
    uint32_t height = 0;
    uint32_t pitch = 0;
    uint32_t format = 0;
    uint32_t refresh_hz = 0;
    uint32_t pipe = 0;
};

class PanelClient {
public:
    ~PanelClient();
    bool open(const char *serviceName, uint32_t clientType);
    void close();
    bool usable() const { return connection_ != 0; }

    bool info(PanelMode &mode);
    bool acquire();
    // Present an IOSurfaceID (BGRA rows, pitch from info()).
    bool present(uint32_t surfaceId, uint32_t sequence, uint32_t timeoutMs);
    bool release(bool restoreOriginal);

private:
    uint32_t request(uint32_t op, uint32_t surfaceId, uint32_t sequence, uint32_t timeoutMs,
                     uint32_t flags, PanelMode *mode);

    uint32_t connection_ = 0;
    uint32_t service_ = 0;
    uint64_t presentCount_ = 0;
};

struct DisplayPipeline {
    RvgDevice *device = nullptr;
    RvgDisplay *display = nullptr;
    RvgFrameTarget *target = nullptr;
    // Three surfaces so the plane never scans a surface being rewritten: the
    // kext retains the last two it presented, the daemon writes the third.
    static constexpr int kSurfaces = 3;
    void *surfaces[kSurfaces] = {};
    uint32_t nextSurface = 0;
    uint64_t presented = 0;
    void *staging = nullptr;   // readback buffer
    size_t stagingLength = 0;
    PanelMode mode;
    PanelClient *panel = nullptr;
    uint64_t guestPresents = 0;
    uint64_t hostPresents = 0;
    uint64_t framesSent = 0;
    bool active = false;
};

// Creates the Reims display (port 0) with the panel's mode and a frame target
// of the panel's size. Returns false and leaves `pipeline` inactive on failure.
bool displayStart(DisplayPipeline &pipeline, RvgDevice *device, PanelClient *panel,
                  char *why, size_t whyLength);

// One frame if the guest presented a new one: encode -> wait -> read -> copy to
// the IOSurface -> present. Returns true when a frame was handed to the panel.
bool displayFrame(DisplayPipeline &pipeline);

void displayStop(DisplayPipeline &pipeline);

} // namespace e16
