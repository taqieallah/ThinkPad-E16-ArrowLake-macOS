#!/usr/bin/env python3
# E16 fixes on top of ArcMTL's ArcXe (idempotent). Usage: patch-arcxe-e16.py <ArcMTL root>
import sys
from pathlib import Path
root = Path(sys.argv[1])
def patch(rel, old, new, marker):
    p = root / rel; s = p.read_text()
    if marker in s: print(f"  {rel}: {marker} already"); return
    assert s.count(old) == 1, f"{rel}: anchor for {marker} not found exactly once"
    p.write_text(s.replace(old, new, 1)); print(f"  {rel}: {marker}")

# 1) opt-in: the E16 normally runs XeGfx (i915) on the same GPU
patch("kexts/ArcXe/ArcXeService.cpp",
 '''    uint32_t off = 0;
    if (PE_parse_boot_argn("-arcoff", &off, sizeof(off))) {''',
 '''    /* E16 opt-in: the E16 normally runs the XeGfx (i915) stack, which drives the same GPU. Two drivers on one GPU
     * corrupt each other, so ArcXe only attaches when OpenCore passes arcxe=1 (arc-mode.sh on). */
    uint32_t e16on = 0;
    if (!PE_parse_boot_argn("arcxe", &e16on, sizeof(e16on)) || !e16on) return nullptr;
    uint32_t off = 0;
    if (PE_parse_boot_argn("-arcoff", &off, sizeof(off))) {''', "E16 opt-in")

# 2) E16-NBB: legacy (non-nested) MI_BATCH_BUFFER_START semantics, as i915 does on Xe_HPG+
#    (intel_workarounds.c fakewa_disable_nestedbb_mode: RING_MI_MODE masked-disable TGL_NESTED_BB_EN = BIT(12)).
#    Xe-LPG resets with nested-BB ON (the arc2 hang dump showed MI_MODE=0x1000); Mesa ANV's chained/second-level
#    batches are written for the legacy meaning. MI_MODE is context-saved, so it goes into every LRC's init ring.
patch("kexts/ArcXe/ArcXeExec.cpp",
 '''    if (initDw & 1u)
        q->ringCpu[initDw++] = ARC_MI_NOOP;
    q->initRingTail = initDw * 4u;''',
 '''    /* E16-NBB: legacy nested-batch semantics in every context (i915 fakewa_disable_nestedbb_mode) */
    q->ringCpu[initDw++] = ARC_MI_LOAD_REGISTER_IMM(1u) | ARC_MI_LRI_CS_MMIO;
    q->ringCpu[initDw++] = 0x09Cu; /* RING_MI_MODE */
    q->ringCpu[initDw++] = ARC_MASKED_DISABLE(1u << 12);
    if (initDw & 1u)
        q->ringCpu[initDw++] = ARC_MI_NOOP;
    q->initRingTail = initDw * 4u;''', "E16-NBB")
# and on the engine itself when it is armed (the idle/default context)
patch("kexts/ArcXe/ArcXeExec.cpp",
 '''        const bool rstOk = resetEngineHw(e.base, e.hwsp);
''',
 '''        const bool rstOk = resetEngineHw(e.base, e.hwsp);
        wr32(ARC_RING_MI_MODE(e.base), ARC_MASKED_DISABLE(1u << 12));   /* E16-NBB-ENG */
''', "E16-NBB-ENG")

# 3) E16-FAULT: on a hang also log the GPU page-fault registers and where the batch stopped, so a fault is visible
#    (i915 XEHP_RING_FAULT_REG 0xcec4, XEHP_FAULT_TLB_DATA0/1 0xceb8/0xcebc; RING_BBADDR/_UDW, RING_DMA_FADD, RING_EIR)
patch("kexts/ArcXe/ArcXeExec.cpp",
 '''    d->mi_mode          = svc->rd32(ARC_RING_MI_MODE(b));
}''',
 '''    d->mi_mode          = svc->rd32(ARC_RING_MI_MODE(b));
    /* E16-FAULT */
    AXELOG("E16-FAULT base=0x%05x FAULT_REG=0x%08x TLB0=0x%08x TLB1=0x%08x BBADDR=0x%08x_%08x DMA_FADD=0x%08x_%08x EIR=0x%08x EMR=0x%08x",
           b, svc->rd32(0xcec4u), svc->rd32(0xceb8u), svc->rd32(0xcebcu),
           svc->rd32(b + 0x168u), svc->rd32(b + 0x140u), svc->rd32(b + 0x60u), svc->rd32(b + 0x78u),
           svc->rd32(b + 0xb0u), svc->rd32(b + 0xb4u));
}''', "E16-FAULT")
