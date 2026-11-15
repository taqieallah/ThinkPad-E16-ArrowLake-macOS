#include <mach/mach_types.h>

extern kern_return_t _start(kmod_info_t *, void *);
extern kern_return_t _stop(kmod_info_t *, void *);
__attribute__((visibility("default"))) KMOD_EXPLICIT_DECL(org.reimsprobe.ReimsPCIProbe, "0.3.2", _start, _stop)

static kern_return_t probe_start(kmod_info_t *info, void *data) {
    (void)info;
    (void)data;
    return KERN_SUCCESS;
}

static kern_return_t probe_stop(kmod_info_t *info, void *data) {
    (void)info;
    (void)data;
    // The probe's published objects and their mappings are retired by reboot.
    return KERN_FAILURE;
}

__private_extern__ kmod_start_func_t *_realmain = probe_start;
__private_extern__ kmod_stop_func_t *_antimain = probe_stop;
__private_extern__ int _kext_apple_cc = __APPLE_CC__;
