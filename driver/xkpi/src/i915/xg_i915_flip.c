// SPDX-License-Identifier: MIT
/*
 * Zero-copy scanout: reserved GGTT slots whose PTEs point at the compositor's own frame pages.  The accelerator
 * (XeGfxAccel) writes PLANE_SURF_1_A itself; this file only owns the GGTT side - reserve, PTE writes, invalidate.
 * A frame that the display scans out of its own memory is not copied at all, so this is the end of the CPU
 * copy path. <wtl> project: xegfx | author: watchthelight </wtl>
 */
#include <linux/pci.h>
#include <linux/string.h>
#include <linux/io.h>

#include "i915_drv.h"
#include "gt/intel_gt.h"
#include "gt/intel_gtt.h"
#include "i915_gem_gtt.h"
#include "gem/i915_gem_object.h"

#include "xg_i915.h"

extern struct drm_i915_private *xg_i915_dev(void);

static struct drm_mm_node gXgFlipNode[XG_FLIP_MAX_SLOTS];
static unsigned int gXgFlipSlots;
static unsigned long long gXgFlipBytes;

static struct i915_ggtt *
xg_flip_ggtt(struct drm_i915_private **i915p)
{
	struct drm_i915_private *i915 = xg_i915_dev();

	if (i915 == NULL)
		return (NULL);
	*i915p = i915;
	return (to_gt(i915)->ggtt);
}

/* reserve `slots` GGTT slots of `surface_bytes` each, below 4 GiB (PLANE_SURF is 32-bit); 0 or -errno */
int
xg_flip_init(unsigned long long surface_bytes, unsigned int slots, unsigned long long *ggtt_out,
    unsigned int *count_out)
{
	struct i915_ggtt *ggtt;
	struct drm_i915_private *i915;
	unsigned long long size;
	unsigned int i, done = 0;
	int err = 0;

	if (ggtt_out == NULL || count_out == NULL || surface_bytes == 0)
		return (-EINVAL);
	if ((ggtt = xg_flip_ggtt(&i915)) == NULL)
		return (-ENODEV);
	size = round_up(surface_bytes, I915_GTT_PAGE_SIZE);
	if (gXgFlipSlots != 0 && gXgFlipBytes >= size) {	/* already reserved, large enough */
		for (i = 0; i < gXgFlipSlots; i++)
			ggtt_out[i] = gXgFlipNode[i].start;
		*count_out = gXgFlipSlots;
		return (0);
	}
	if (slots > XG_FLIP_MAX_SLOTS)
		slots = XG_FLIP_MAX_SLOTS;
	mutex_lock(&ggtt->vm.mutex);
	for (i = 0; i < slots; i++) {
		err = i915_gem_gtt_insert(&ggtt->vm, NULL, &gXgFlipNode[i], size, I915_GTT_PAGE_SIZE,
		    I915_COLOR_UNEVICTABLE, 0x80000000ULL, 0x100000000ULL, PIN_NOEVICT);
		if (err)
			break;
		ggtt_out[i] = gXgFlipNode[i].start;
		done++;
	}
	mutex_unlock(&ggtt->vm.mutex);
	if (done == 0)
		return (err != 0 ? err : -ENOSPC);
	gXgFlipSlots = done;
	gXgFlipBytes = size;
	*count_out = done;
	return (0);
}

/* point slot's PTEs at these physical pages (4 KiB each), then one TLB invalidate for the whole slot */
int
xg_flip_map(unsigned int slot, unsigned long long surface_bytes, const unsigned long long *phys,
    unsigned int npages)
{
	struct i915_ggtt *ggtt;
	struct drm_i915_private *i915;
	unsigned long long size;
	unsigned int i, need;
	unsigned int pat;

	if (slot >= gXgFlipSlots || phys == NULL || surface_bytes == 0)
		return (-EINVAL);
	if ((ggtt = xg_flip_ggtt(&i915)) == NULL)
		return (-ENODEV);
	size = round_up(surface_bytes, I915_GTT_PAGE_SIZE);
	need = (unsigned int)(size >> 12);
	if (npages < need)
		return (-EINVAL);
	/* system-memory scanout: uncached, which on this platform encodes as a plain phys|PRESENT PTE */
	pat = i915_gem_get_pat_index(i915, I915_CACHE_NONE);
	for (i = 0; i < need; i++) {
		u64 pte = ggtt->vm.pte_encode((dma_addr_t)(phys[i] & ~0xfffull), pat, 0);
		writeq(pte, (u64 __iomem *)ggtt->gsm + (gXgFlipNode[slot].start >> 12) + i);
	}
	ggtt->invalidate(ggtt);
	return (0);
}

/* drop the slot's PTEs back to scratch, then one TLB invalidate (clear_range is a no-op on gen8+) */
int
xg_flip_unmap(unsigned int slot, unsigned long long surface_bytes)
{
	struct i915_ggtt *ggtt;
	struct drm_i915_private *i915;
	unsigned long long size;

	if (slot >= gXgFlipSlots || surface_bytes == 0)
		return (-EINVAL);
	if ((ggtt = xg_flip_ggtt(&i915)) == NULL)
		return (-ENODEV);
	size = round_up(surface_bytes, I915_GTT_PAGE_SIZE);
	if (ggtt->vm.scratch_range != NULL)
		ggtt->vm.scratch_range(&ggtt->vm, gXgFlipNode[slot].start, size);
	ggtt->invalidate(ggtt);
	return (0);
}
