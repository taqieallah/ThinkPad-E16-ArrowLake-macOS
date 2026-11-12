/* k12 test: lists the DRM devices and opens the render node through the patched libdrm, then asks the driver its
 * name. Run plain, with XEGFX_KOPEN=1, and inside a sandbox that refuses /dev/dri (k12-test.sh does all three). */
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <xf86drm.h>

extern int drmXeGfxOpen(const char *path, int flags);

int main(void)
{
    drmDevicePtr dev[8];
    int n = drmGetDevices2(0, dev, 8), fd = -1;

    printf("drmGetDevices2: %d\n", n);
    for (int i = 0; i < n; i++) {
        printf("  device %d: %04x:%04x nodes 0x%x render %s\n", i,
               dev[i]->bustype == DRM_BUS_PCI ? dev[i]->deviceinfo.pci->vendor_id : 0,
               dev[i]->bustype == DRM_BUS_PCI ? dev[i]->deviceinfo.pci->device_id : 0, dev[i]->available_nodes,
               (dev[i]->available_nodes & (1 << DRM_NODE_RENDER)) ? dev[i]->nodes[DRM_NODE_RENDER] : "-");
        if (fd < 0 && (dev[i]->available_nodes & (1 << DRM_NODE_RENDER)))
            fd = drmXeGfxOpen(dev[i]->nodes[DRM_NODE_RENDER], O_RDWR | O_CLOEXEC);
    }
    if (fd < 0)
        fd = drmXeGfxOpen("/dev/dri/renderD128", O_RDWR | O_CLOEXEC);
    if (fd < 0) {
        perror("open renderD128");
        return 1;
    }
    drmVersionPtr v = drmGetVersion(fd);
    if (!v) {
        perror("drmGetVersion");
        return 1;
    }
    printf("fd %d: driver %s %d.%d.%d\n", fd, v->name, v->version_major, v->version_minor, v->version_patchlevel);
    drmFreeVersion(v);
    drmDevicePtr d;
    if (drmGetDevice2(fd, 0, &d) == 0) {
        printf("drmGetDevice2(fd): ok, render %s\n", (d->available_nodes & (1 << DRM_NODE_RENDER)) ? d->nodes[DRM_NODE_RENDER] : "-");
        drmFreeDevice(&d);
    } else
        printf("drmGetDevice2(fd): failed\n");
    close(fd);
    printf("PASS\n");
    return 0;
}
