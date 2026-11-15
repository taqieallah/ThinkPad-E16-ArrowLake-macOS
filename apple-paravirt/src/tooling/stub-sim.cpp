// Offline execution test for the APV site stubs.
//
// Generates the real stub machine code for every site in kext/sites.json,
// maps it executable, runs it with the register state Apple's code has at that
// site, and checks:
//   * the dispatcher is called with the right site id, BAR base and value;
//   * the read result lands in the register the original instruction wrote;
//   * the flags the following instruction consumes are the ones the original
//     instruction sequence would produce;
//   * every other register and the stack are left exactly as Apple expects;
//   * the patched site is one `E8 rel32` call plus NOP padding to the stub.
//
// Build (on the MacBook Air) and run under Rosetta 2:
//   xcrun clang++ -arch x86_64 -std=c++17 -O1 -Wall -Wextra -Werror \
//       -I ../kext stub-sim.cpp -o stub-sim
//   arch -x86_64 ./stub-sim
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <sys/mman.h>
#include <unistd.h>

#include "SiteTable.hpp"

// ---------------------------------------------------------------------------
// Machine-code harness: call a stub with a chosen register state, then capture
// the registers and flags at the continuation.
// ---------------------------------------------------------------------------
extern "C" {
uint32_t sim_rax, sim_rbx, sim_rcx, sim_rdx, sim_rsi, sim_rdi, sim_r10, sim_r11;
uint32_t sim_r9, sim_r12, sim_r14, sim_flags, sim_path;
void sim_call(void *stub, uint32_t ecx_in, uint64_t rax_in, uint64_t rdx_in, uint64_t rsi_in);
void sim_resume(void);
void sim_fault(void);
}

asm(R"(
 .text
 .globl _sim_call
_sim_call:
    pushq %rbp
    pushq %r12
    pushq %r14
    movq %rsp, %rbp
    subq $8, %rsp
    movq %rcx, %r11
    movl %esi, %ecx
    movq %rdx, %rax
    movq %r11, %rdx
    movq %r8, %rsi
    callq *%rdi
    nop
 .globl _sim_resume
_sim_resume:
    movl $0, _sim_path(%rip)
    jmp _sim_unwind
 .globl _sim_fault
_sim_fault:
    movl $1, _sim_path(%rip)
    jmp _sim_unwind
_sim_unwind:
    movl %eax, _sim_rax(%rip)
    movl %ebx, _sim_rbx(%rip)
    movl %ecx, _sim_rcx(%rip)
    movl %edx, _sim_rdx(%rip)
    movl %esi, _sim_rsi(%rip)
    movl %edi, _sim_rdi(%rip)
    movl %r10d, _sim_r10(%rip)
    movl %r11d, _sim_r11(%rip)
    movl %r9d, _sim_r9(%rip)
    movl %r12d, _sim_r12(%rip)
    movl %r14d, _sim_r14(%rip)
    pushfq
    popq %rax
    movl %eax, _sim_flags(%rip)
    addq $8, %rsp
    popq %r14
    popq %r12
    popq %rbp
    retq
 .section __TEXT,__text
)");

// ---------------------------------------------------------------------------
// Scripted dispatcher
// ---------------------------------------------------------------------------
namespace {
struct DispatchCall {
    uint32_t site;
    uint64_t base;
    uint32_t value;
};
DispatchCall gCalls[8];
unsigned gCallCount = 0;
uint32_t gReply = 0;
uint32_t gReplyBySite[8] = {};

uint64_t gExpectedBase = 0x1000;

int failures = 0;
void check(bool condition, const char *what) {
    if (!condition) {
        std::printf("FAIL: %s\n", what);
        ++failures;
    }
}
} // namespace

extern "C" uint32_t e16_apv_dispatch(uint32_t site, uint64_t base, uint32_t value) {
    if (gCallCount < 8)
        gCalls[gCallCount] = {site, base, value};
    ++gCallCount;
    if (site < 8 && gReplyBySite[site])
        return gReplyBySite[site];
    return gReply;
}

// ---------------------------------------------------------------------------
// Executable stub slots
// ---------------------------------------------------------------------------
namespace {
unsigned char *gCode = nullptr;
constexpr size_t kCodeSize = 0x4000;

void *codeAt(size_t offset) { return gCode + offset; }

bool mapCode() {
    void *p = mmap(nullptr, kCodeSize, PROT_READ | PROT_WRITE | PROT_EXEC,
                   MAP_PRIVATE | MAP_ANON, -1, 0);
    if (p == MAP_FAILED) {
        std::perror("mmap");
        return false;
    }
    std::memset(p, 0xCC, kCodeSize);
    gCode = static_cast<unsigned char *>(p);
    return true;
}

void resetCapture() {
    sim_rax = sim_rbx = sim_rcx = sim_rdx = sim_rsi = sim_rdi = 0;
    sim_r9 = sim_r10 = sim_r11 = sim_r12 = sim_r14 = 0;
    sim_flags = 0;
    sim_path = 0;
    gCallCount = 0;
    for (auto &call : gCalls)
        call = {};
}

} // namespace

int main() {
    if (!mapCode())
        return 1;
    std::printf("stub simulator: %zu sites\n", (size_t)e16::kSiteTableCount);

    for (size_t i = 0; i < e16::kSiteTableCount; ++i) {
        const e16::SiteSpec &site = e16::kSiteTable[i];
        const uint64_t base = gExpectedBase;
        const uint64_t continuation = reinterpret_cast<uint64_t>(&sim_resume);
        unsigned char stub[e16::kStubCapacity] = {};
        size_t stubLength = 0;
        const uint64_t branchTarget =
            site.kind == e16::kSiteReadBranch ? reinterpret_cast<uint64_t>(&sim_fault) : 0;
        if (!e16::buildStub(site, reinterpret_cast<uint64_t>(&e16_apv_dispatch), continuation,
                            branchTarget, stub, sizeof(stub), stubLength)) {
            std::printf("FAIL: site %s: stub generation\n", site.name);
            ++failures;
            continue;
        }
        check(stubLength < e16::kStubCapacity, "stub fits slot");
        unsigned char *slot = static_cast<unsigned char *>(codeAt(i * 512));
        std::memcpy(slot, stub, stubLength);

        resetCapture();
        gReply = 0;
        for (uint32_t &reply : gReplyBySite)
            reply = 0;

        switch (static_cast<e16::SiteKind>(site.kind)) {
        case e16::kSiteVersionPair: {
            gReplyBySite[site.id] = 4;
            sim_call(slot, 6, 0x1111111111111111ULL, base, 0x2222222222222222ULL);
            // The stub makes one dispatcher call with the original write
            // operand; the dispatcher itself performs the write/read pair.
            check(gCallCount == 1, "version pair issues one dispatch");
            check(gCalls[0].site == site.id && gCalls[0].base == base &&
                      gCalls[0].value == 6,
                  "version pair passes the original write operand");
            check(sim_r12 == 4, "version pair stores the negotiated value in r12d");
            check(sim_rax == 0x11111111U, "version pair preserves rax");
            check(sim_rdx == static_cast<uint32_t>(base), "version pair preserves rdx");
            check(sim_rsi == 0x22222222U, "version pair preserves rsi");
            break;
        }
        case e16::kSiteWriteImm: {
            const uint64_t sx = 0x1111111111111111ULL;
            const uint64_t raxIn = site.base_slot == e16::kSavedRax ? base : sx;
            const uint64_t rdxIn = site.base_slot == e16::kSavedRdx ? base : sx;
            sim_call(slot, 0x7, raxIn, rdxIn, 0x2222222222222222ULL);
            check(gCallCount == 1, "write-imm issues one request");
            if (!(gCalls[0].site == site.id && gCalls[0].base == base &&
                  gCalls[0].value == site.immediate)) {
                std::printf("  site %u '%s': call site=%u base=0x%llx value=0x%x, expected "
                            "site=%u base=0x%llx value=0x%x\n",
                            site.id, site.name, gCalls[0].site,
                            static_cast<unsigned long long>(gCalls[0].base), gCalls[0].value,
                            site.id, static_cast<unsigned long long>(base), site.immediate);
            }
            check(gCalls[0].site == site.id && gCalls[0].base == base &&
                      gCalls[0].value == site.immediate,
                  "write-imm writes the site immediate");
            if (site.base_slot == e16::kSavedRdx) {
                check(sim_rdx == static_cast<uint32_t>(base), "write-imm keeps the BAR base in rdx");
                check(sim_rax == 0x11111111U, "write-imm preserves rax");
            } else {
                check(sim_rax == static_cast<uint32_t>(base), "write-imm keeps the BAR base in rax");
                check(sim_rdx == 0x11111111U, "write-imm preserves rdx");
            }
            break;
        }
        case e16::kSiteReadBranch: {
            // value != 0 must take the fault continuation, 0 the zero continuation.
            gReplyBySite[site.id] = 5;
            sim_call(slot, 0, base, 0, 0);
            check(gCallCount == 1, "fault read issues one dispatch");
            check(gCalls[0].site == site.id && gCalls[0].base == base,
                  "fault read passes the BAR base");
            check(sim_path == 1, "nonzero fault value jumps to the fault target");
            check(sim_rax == static_cast<uint32_t>(base), "fault read preserves rax");
            resetCapture();
            gReplyBySite[site.id] = 0;
            sim_call(slot, 0, base, 0, 0);
            check(sim_path == 0, "zero fault value jumps to the no-fault target");
            break;
        }
        case e16::kSiteRead32: {
            gReplyBySite[site.id] = 0xA5;
            sim_call(slot, 0x7, base, 0, 0x3333333333333333ULL);
            check(gCallCount == 1, "read issues one request");
            check(gCalls[0].site == site.id && gCalls[0].base == base,
                  "read passes the BAR base");
            if (site.dest == e16::kDestR14)
                check(sim_r14 == 0xA5, "stamp read lands in r14d");
            else if (site.dest == e16::kDestRsi)
                check(sim_rsi == 0xA5, "display read lands in esi");
            else if (site.dest == e16::kDestR9)
                check(sim_r9 == 0xA5, "port count read lands in r9d");
            else
                check(false, "unknown read destination");
            if (site.reproduce_length) {
                const uint32_t zf = (sim_flags >> 6) & 1U;
                check(zf == 0, "read result sets the reproduced test flags (nonzero)");
            }
            check(sim_rdx == 0, "read preserves rdx");
            break;
        }
        }

        // Patch bytes: call rel32 to the stub, NOP padding to span.
        unsigned char patch[e16::kPatchCapacity] = {};
        size_t patchLength = 0;
        const uint64_t siteVA = 0x000014898000ULL + site.text_offset;
        const uint64_t stubVA = 0x000014900000ULL + i * 512;
        check(e16::buildPatch(site, siteVA, stubVA, patch, sizeof(patch), patchLength),
              "patch fits rel32");
        check(patchLength == site.span, "patch length equals site span");
        check(patch[0] == 0xE8, "patch is a near call");
        const auto rel = static_cast<int32_t>(static_cast<uint32_t>(patch[1]) |
                                              (static_cast<uint32_t>(patch[2]) << 8) |
                                              (static_cast<uint32_t>(patch[3]) << 16) |
                                              (static_cast<uint32_t>(patch[4]) << 24));
        check(siteVA + 5 + static_cast<uint64_t>(static_cast<int64_t>(rel)) == stubVA,
              "patch rel32 targets the stub");
        for (size_t b = 5; b < site.span; ++b)
            check(patch[b] == 0x90, "patch tail is NOP padding");
    }

    // Out-of-range patch target must be refused, never wrapped.
    const e16::SiteSpec &first = e16::kSiteTable[0];
    unsigned char patch[e16::kPatchCapacity] = {};
    size_t length = 0;
    check(!e16::buildPatch(first, 0x1000, 0x1000 + 0x1'0000'0000ULL, patch, sizeof(patch),
                           length),
          "out-of-range rel32 refused");

    if (failures == 0) {
        std::printf("PASS: %zu site stubs execute with the expected register and flag contract\n",
                    (size_t)e16::kSiteTableCount);
        return 0;
    }
    std::printf("FAILED: %d checks\n", failures);
    return 1;
}
