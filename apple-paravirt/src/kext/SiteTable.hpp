// APV site table and stub generator for the E16 AppleParavirtGPU <-> Reims
// live bridge.
//
// Pure C++17: this header is compiled into the x86_64 kernel extension and into
// the userspace stub simulator (tooling/stub-sim.cpp, run under Rosetta). It has
// no IOKit, libc, exception or RTTI dependency.
//
// The patched site is replaced by `E8 rel32` (call to a stub) plus NOP padding
// covering the rest of the site span. The stub:
//   1. saves every GPR it may clobber and the flags;
//   2. calls e16_apv_dispatch(site, bar_base, value) through an absolute
//      indirect call (no distance limit, no register clobber outside the saved
//      frame);
//   3. restores every register, puts the read result into the destination
//      register the original instruction wrote;
//   4. re-executes the original instructions that the span swallowed (so the
//      flags the following instruction consumes are correct);
//   5. drops the return address and jumps to the continuation with an absolute
//      indirect jump, exactly as if the original instructions had run inline.
//
// Saved-frame layout (rsp-relative inside the stub):
//   +0 rax  +8 rcx  +16 rdx  +24 rsi  +32 rdi  +40 r8  +48 r9  +56 r10
//   +64 r11 +72 rbx +80 rbp  +88 flags +96 pad +104 return address
#pragma once

#include <stddef.h>
#include <stdint.h>

namespace e16 {

enum SiteKind : uint8_t {
    kSiteRead32 = 0,      // read bar_offset, result -> dest
    kSiteWriteImm = 1,    // write the site's immediate to bar_offset
    kSiteVersionPair = 2, // write value to bar_offset, then read it back -> dest
    kSiteReadBranch = 3,  // read bar_offset, then tail-jump on value != 0
};

enum DestReg : uint8_t {
    kDestNone = 0xFF,
    kDestRax = 0, kDestRcx = 1, kDestRdx = 2, kDestRbx = 3, kDestRbp = 5,
    kDestRsi = 6, kDestRdi = 7, kDestR8 = 8, kDestR9 = 9, kDestR10 = 10,
    kDestR11 = 11, kDestR12 = 12, kDestR14 = 14,
};

// Offsets inside the stub's saved-register frame.
constexpr uint8_t kSavedRax = 0;
constexpr uint8_t kSavedRcx = 8;
constexpr uint8_t kSavedRdx = 16;
constexpr uint8_t kSavedRsi = 24;
constexpr uint8_t kSavedRdi = 32;
constexpr uint8_t kSavedR8 = 40;
constexpr uint8_t kSavedR9 = 48;
constexpr uint8_t kSavedR10 = 56;
constexpr uint8_t kSavedR11 = 64;
constexpr uint8_t kSavedRbx = 72;
constexpr uint8_t kSavedRbp = 80;
constexpr uint8_t kSavedFlags = 88;
constexpr uint8_t kSavedFrameBytes = 96;
constexpr uint8_t kSavedReturnAddress = 104;

struct SiteSpec {
    uint8_t id;
    uint32_t text_offset;   // relative to the __TEXT segment (Mach-O file offset)
    uint8_t span;           // bytes replaced by call + NOPs, >= 5
    uint8_t original[16];   // expected original bytes, zero padded
    uint32_t continuation;  // text_offset + span, checked by the verifier
    uint32_t branch_target; // kSiteReadBranch: target when the value is nonzero
    uint16_t bar_offset;    // absolute BAR0 register offset
    uint8_t base_slot;      // saved-frame offset of the GPR holding the BAR base
    uint8_t value_slot;     // saved-frame offset of the write value GPR, or 0xff
    uint8_t dest;           // DestReg for reads, kDestNone otherwise
    uint32_t immediate;     // value for kSiteWriteImm
    uint8_t reproduce[8];   // original instructions to re-run for their flags
    uint8_t reproduce_length;
    uint8_t kind;           // SiteKind
    const char *name;
};

#include "APVSites.generated.hpp"

constexpr size_t kStubCapacity = 320;
constexpr size_t kPatchCapacity = 16;

namespace detail {

inline void emit8(uint8_t *p, size_t &n, uint8_t v) { p[n++] = v; }
inline void emit32(uint8_t *p, size_t &n, uint32_t v) {
    p[n++] = static_cast<uint8_t>(v);
    p[n++] = static_cast<uint8_t>(v >> 8);
    p[n++] = static_cast<uint8_t>(v >> 16);
    p[n++] = static_cast<uint8_t>(v >> 24);
}
inline void emit64(uint8_t *p, size_t &n, uint64_t v) {
    emit32(p, n, static_cast<uint32_t>(v));
    emit32(p, n, static_cast<uint32_t>(v >> 32));
}

inline void emitPush64(uint8_t *p, size_t &n, uint8_t enc) {
    if (enc >= 8) {
        emit8(p, n, 0x41);
        emit8(p, n, static_cast<uint8_t>(0x50 + (enc - 8)));
    } else {
        emit8(p, n, static_cast<uint8_t>(0x50 + enc));
    }
}

// mov reg64, [rsp + disp8]; reg is 0..15.
inline void emitMovRegFromStack(uint8_t *p, size_t &n, uint8_t reg, uint8_t disp) {
    emit8(p, n, reg >= 8 ? 0x4C : 0x48);
    emit8(p, n, 0x8B);
    emit8(p, n, static_cast<uint8_t>(0x44 | ((reg & 7) << 3)));
    emit8(p, n, 0x24);
    emit8(p, n, disp);
}

// mov edi, imm32 (zero extends into rdi).
inline void emitMovEdiImm32(uint8_t *p, size_t &n, uint32_t v) {
    emit8(p, n, 0xBF);
    emit32(p, n, v);
}
inline void emitMovEdxImm32(uint8_t *p, size_t &n, uint32_t v) {
    emit8(p, n, 0xBA);
    emit32(p, n, v);
}
// mov edx, [rsp + disp8].
inline void emitMovEdxFromStack(uint8_t *p, size_t &n, uint8_t disp) {
    emitMovRegFromStack(p, n, 2, disp);
}
// mov r10d, eax.
inline void emitMovR10dEax(uint8_t *p, size_t &n) {
    emit8(p, n, 0x41);
    emit8(p, n, 0x89);
    emit8(p, n, 0xC2);
}
// mov dest32, r10d.
inline void emitMovDestR10d(uint8_t *p, size_t &n, uint8_t dest) {
    emit8(p, n, static_cast<uint8_t>(0x40 | 0x04 | (dest >= 8 ? 0x01 : 0x00)));
    emit8(p, n, 0x89);
    emit8(p, n, static_cast<uint8_t>(0xC0 | ((10 & 7) << 3) | (dest & 7)));
}
inline void emitAddRspImm8(uint8_t *p, size_t &n, uint8_t v) {
    emit8(p, n, 0x48);
    emit8(p, n, 0x83);
    emit8(p, n, 0xC4);
    emit8(p, n, v);
}
// FF 15 disp32: call [rip + disp32]. The disp32 is filled by the caller later.
inline size_t emitCallIndirect(uint8_t *p, size_t &n) {
    emit8(p, n, 0xFF);
    emit8(p, n, 0x15);
    const size_t disp_pos = n;
    emit32(p, n, 0);
    return disp_pos;
}
// FF 25 disp32: jmp [rip + disp32].
inline size_t emitJmpIndirect(uint8_t *p, size_t &n) {
    emit8(p, n, 0xFF);
    emit8(p, n, 0x25);
    const size_t disp_pos = n;
    emit32(p, n, 0);
    return disp_pos;
}
inline void fillRel32(uint8_t *p, size_t disp_pos, size_t instruction_end,
                      size_t target) {
    const auto rel = static_cast<int32_t>(static_cast<int64_t>(target) -
                                               static_cast<int64_t>(instruction_end));
    p[disp_pos + 0] = static_cast<uint8_t>(static_cast<uint32_t>(rel));
    p[disp_pos + 1] = static_cast<uint8_t>(static_cast<uint32_t>(rel) >> 8);
    p[disp_pos + 2] = static_cast<uint8_t>(static_cast<uint32_t>(rel) >> 16);
    p[disp_pos + 3] = static_cast<uint8_t>(static_cast<uint32_t>(rel) >> 24);
}

constexpr uint8_t savedRegisters[] = {
    0, 1, 2, 6, 7, 8, 9, 11, 3, 5, // rax rcx rdx rsi rdi r8 r9 r11 rbx rbp
};
constexpr uint8_t savedRegisterSlots[] = {
    kSavedRax, kSavedRcx, kSavedRdx, kSavedRsi, kSavedRdi,
    kSavedR8, kSavedR9, kSavedR11, kSavedRbx, kSavedRbp,
};

} // namespace detail

// Build the machine-code stub for one site.
//   dispatcher   address of e16_apv_dispatch (in the kext's text or, for the
//                simulator, the test dispatcher)
//   continuation runtime address the stub must resume at
// Returns false when the site is malformed or the fixed capacity is too small.
inline bool buildStub(const SiteSpec &site, uint64_t dispatcher, uint64_t continuation,
                      uint64_t branch_target, uint8_t *out, size_t capacity,
                      size_t &out_length) {
    if (capacity < kStubCapacity || site.span < 5)
        return false;
    uint8_t *p = out;
    size_t n = 0;

    // Frame: pad, flags, then every register the stub may clobber.
    detail::emit8(p, n, 0x48); // sub rsp, 8  (16-byte alignment)
    detail::emit8(p, n, 0x83);
    detail::emit8(p, n, 0xEC);
    detail::emit8(p, n, 0x08);
    detail::emit8(p, n, 0x9C); // pushfq
    const uint8_t pushes[] = {5, 3, 11, 10, 9, 8, 7, 6, 2, 1, 0};
    for (size_t push = 0; push < sizeof(pushes); ++push)
        detail::emitPush64(p, n, pushes[push]);

    // Arguments: rdi = site id, rsi = BAR base, rdx = value (write sites).
    detail::emitMovEdiImm32(p, n, site.id);
    detail::emitMovRegFromStack(p, n, 6, site.base_slot); // mov rsi, [rsp+base_slot]
    if (site.kind == kSiteWriteImm) {
        detail::emitMovEdxImm32(p, n, site.immediate);
    } else if (site.kind == kSiteVersionPair) {
        detail::emitMovRegFromStack(p, n, 2, site.value_slot); // mov rdx, [rsp+value_slot]
    } else {
        detail::emit8(p, n, 0x31); // xor edx, edx
        detail::emit8(p, n, 0xD2);
    }
    const size_t call_pos = detail::emitCallIndirect(p, n);
    detail::emitMovR10dEax(p, n);

    if (site.kind == kSiteReadBranch) {
        // Keep the result in the frame's alignment pad, restore every GPR, then
        // reproduce the cmpl/je with a compare and two absolute tail jumps.
        // 44 89 54 24 60 = mov %r10d,0x60(%rsp)
        const uint8_t stash[] = {0x44, 0x89, 0x54, 0x24, 0x60};
        for (uint8_t byte : stash)
            detail::emit8(p, n, byte);
        for (size_t i = 0; i < sizeof(detail::savedRegisters); ++i) {
            detail::emitMovRegFromStack(p, n, detail::savedRegisters[i],
                                        detail::savedRegisterSlots[i]);
        }
        detail::emitAddRspImm8(p, n, kSavedFlags); // rsp -> flags slot
        detail::emit8(p, n, 0x9D);                 // popfq -> rsp -> pad
        const uint8_t cmpPad[] = {0x83, 0x3C, 0x24, 0x00}; // cmpl $0,(%rsp)
        for (uint8_t byte : cmpPad)
            detail::emit8(p, n, byte);
        const uint8_t leaRsp[] = {0x48, 0x8D, 0x64, 0x24, 0x10}; // lea 0x10(%rsp),%rsp
        for (uint8_t byte : leaRsp)
            detail::emit8(p, n, byte);
        detail::emit8(p, n, 0x74); // jz zero block (skips the 6-byte jump below)
        detail::emit8(p, n, 0x06);
        const size_t nonzero_pos = detail::emitJmpIndirect(p, n);
        const size_t zero_pos = detail::emitJmpIndirect(p, n);
        const size_t dispatcherLit = n;
        detail::emit64(p, n, dispatcher);
        const size_t nonzeroLit = n;
        detail::emit64(p, n, branch_target);
        const size_t zeroLit = n;
        detail::emit64(p, n, continuation);
        detail::fillRel32(p, call_pos, call_pos + 4, dispatcherLit);
        detail::fillRel32(p, nonzero_pos, nonzero_pos + 4, nonzeroLit);
        detail::fillRel32(p, zero_pos, zero_pos + 4, zeroLit);
        out_length = n;
        return true;
    }

    // Restore the saved registers; r10 is restored last because it carries the
    // read result for the destination register.
    for (size_t i = 0; i < sizeof(detail::savedRegisters); ++i) {
        detail::emitMovRegFromStack(p, n, detail::savedRegisters[i],
                                    detail::savedRegisterSlots[i]);
    }
    if (site.dest != kDestNone)
        detail::emitMovDestR10d(p, n, site.dest);
    detail::emitMovRegFromStack(p, n, 10, kSavedR10);

    // Unwind the saved frame, restore the flags, keep the reproduce bytes'
    // flags live, drop the CALL return address and tail-jump to the site's
    // continuation.
    detail::emitAddRspImm8(p, n, kSavedFlags); // rsp -> flags slot
    detail::emit8(p, n, 0x9D);                 // popfq
    detail::emitAddRspImm8(p, n, 0x08);        // rsp -> return address
    for (uint8_t i = 0; i < site.reproduce_length; ++i)
        detail::emit8(p, n, site.reproduce[i]);
    detail::emitAddRspImm8(p, n, 0x08); // drop the CALL return address
    const size_t jmp_pos = detail::emitJmpIndirect(p, n);

    // Absolute literals after the code.
    const size_t dispatcherLit = n;
    detail::emit64(p, n, dispatcher);
    const size_t continuationLit = n;
    detail::emit64(p, n, continuation);

    detail::fillRel32(p, call_pos, call_pos + 4, dispatcherLit);
    detail::fillRel32(p, jmp_pos, jmp_pos + 4, continuationLit);
    out_length = n;
    return true;
}

// Build the in-place patch: E8 rel32 to the stub plus NOP padding.
inline bool buildPatch(const SiteSpec &site, uint64_t site_va, uint64_t stub_va,
                       uint8_t *out, size_t capacity, size_t &out_length) {
    if (capacity < site.span || site.span < 5)
        return false;
    const int64_t delta = static_cast<int64_t>(stub_va) -
                               static_cast<int64_t>(site_va + 5);
    if (delta > 0x7fffffffLL || delta < -0x80000000LL)
        return false;
    out[0] = 0xE8;
    out[1] = static_cast<uint8_t>(static_cast<uint32_t>(delta));
    out[2] = static_cast<uint8_t>(static_cast<uint32_t>(delta) >> 8);
    out[3] = static_cast<uint8_t>(static_cast<uint32_t>(delta) >> 16);
    out[4] = static_cast<uint8_t>(static_cast<uint32_t>(delta) >> 24);
    for (size_t i = 5; i < site.span; ++i)
        out[i] = 0x90;
    out_length = site.span;
    return true;
}

inline const SiteSpec *findSite(uint8_t id) {
    for (size_t i = 0; i < kSiteTableCount; ++i) {
        if (kSiteTable[i].id == id)
            return &kSiteTable[i];
    }
    return nullptr;
}

} // namespace e16
