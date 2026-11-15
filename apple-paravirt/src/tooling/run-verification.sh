#!/bin/bash
# Run every offline verification for the E16 APV live bridge and print a log.
# Run on the MacBook Air (Xcode + Rosetta 2 required for the stub simulator).
#
#   bash tooling/run-verification.sh [output-log]
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
out="${1:-$here/VERIFICATION.log}"
fail=0

section() { echo; echo "############ $* ############"; }
check() {
    if "$@" >>"$out" 2>&1; then
        echo "PASS: $*"
    else
        echo "FAIL: $*"
        fail=1
    fi
}

: > "$out"
{
    echo "E16 APV live bridge — offline verification"
    echo "date: $(date)"
    echo "host: $(uname -a)"
    echo
} >> "$out"

section "1. Apple image identity"
check shasum -a 256 "$here/apv/com.apple.driver.AppleParavirtGPU"
check shasum -a 256 "/Volumes/1401/xegfx-e16/diag-25G241/com.apple.driver.AppleParavirtGPU"

section "2. Site plan against the real 25G241 Mach-O"
check python3 "$here/tooling/verify-sites.py"

section "3. Generated stubs, executed (Rosetta 2)"
check bash -c "cd '$here/tooling' && xcrun clang++ -arch x86_64 -std=c++17 -O1 -Wall -Wextra -Werror -I ../kext stub-sim.cpp -o stub-sim && arch -x86_64 ./stub-sim"

section "4. Kext build (x86_64, MacKernelSDK)"
rm -rf "$here/kext/build/ReimsPCIProbe.kext"
check bash -c "cd '$here/kext' && bash build.sh '$HOME/Downloads/ReimsPCIProbe/MacKernelSDK'"

section "5. Kext link check against the target boot collection"
check python3 "$HOME/src/kcabi/linkcheck.py" "$here/kext/build/ReimsPCIProbe.kext" \
    --kc /Volumes/1401/xegfx-e16/diag-25G241/BootKernelExtensions.kc \
    --baseline "$HOME/Documents/Codex/2026-11-15/new-chat-2/work/reference-0.1.10.kext"

section "6. Kext Mach-O shape and executable stub section"
check bash -c "cd '$here/kext' && xcrun lipo -verify_arch x86_64 build/ReimsPCIProbe.kext/Contents/MacOS/ReimsPCIProbe"
check bash -c "cd '$here/kext' && otool -l build/ReimsPCIProbe.kext/Contents/MacOS/ReimsPCIProbe | grep -A4 'sectname __apvstubs'"
check bash -c "cd '$here/kext' && nm build/ReimsPCIProbe.kext/Contents/MacOS/ReimsPCIProbe | grep -E ' _e16_apv_dispatch| gStubArea'"

section "7. Host daemon build and no-kext self-check (Rosetta 2)"
check bash -c "cd '$here/host' && bash build.sh"
check bash -c "cd '$here/host' && arch -x86_64 ./apv-host --no-arm --seconds 1"

section "8. Host daemon against the real Reims library"
check bash -c "cd '$here/host-proto' && arch -x86_64 ./reims-probe --phase main --registry-id 0x1000003de"

section "9. XeGfx panel patch (rebuild + sign)"
check bash -c "cd '$here/xegfx' && bash build-xegfx-accel.sh"
XK="$here/xegfx/kexts/XeGfxAccel/26/XeGfxAccel.kext"
XB="/Volumes/1401/xegfx-e16/final/kexts/XeGfxAccel.kext"
check bash -c "xcrun lipo -verify_arch x86_64 '$XK/Contents/MacOS/XeGfxAccel'"
check bash -c "grep -aq 'XG_PANEL ABI 1' '$XK/Contents/MacOS/XeGfxAccel'"
check bash -c "codesign --verify --strict '$XK'"
if [ -d "$XB" ]; then
    check bash -c "nm -um '$XK/Contents/MacOS/XeGfxAccel' | awk '{print \$NF}' | sort -u > /tmp/xg-new.txt; nm -um '$XB/Contents/MacOS/XeGfxAccel' | awk '{print \$NF}' | sort -u > /tmp/xg-base.txt; test -z \"\$(comm -23 /tmp/xg-new.txt /tmp/xg-base.txt)\""
    check python3 "$HOME/src/kcabi/linkcheck.py" "$XK" \
        --kc /Volumes/1401/xegfx-e16/diag-25G241/BootKernelExtensions.kc --baseline "$XB"
else
    echo "SKIP: installed E16 XeGfxAccel baseline not mounted"
fi

section "10. Package integrity"
pkgdir="$here/pkg/E16-APV-Live-0.3.0"
check bash -c "plutil -lint '$pkgdir/kext/ReimsPCIProbe.kext/Contents/Info.plist'"
check bash -c "for s in '$pkgdir'/scripts/*.sh; do bash -n \"\$s\" || exit 1; done"
check bash -c "xcrun lipo -verify_arch x86_64 '$pkgdir/xegfx/XeGfxAccel.kext/Contents/MacOS/XeGfxAccel'"
check bash -c "grep -aq 'XG_PANEL ABI 1' '$pkgdir/xegfx/XeGfxAccel.kext/Contents/MacOS/XeGfxAccel'"
check bash -c "test -f '$pkgdir/xegfx/PANEL-ABI.md' -a -f '$pkgdir/xegfx/xegfx-panel.patch'"
check bash -c "codesign --verify --strict '$pkgdir/xegfx/XeGfxAccel.kext'"
check bash -c "for f in '$pkgdir/host/apv-host' '$pkgdir/host/lib/libreims_vgpu.dylib' '$pkgdir/tools/metal-registry'; do xcrun lipo -verify_arch x86_64 \"\$f\" || exit 1; done"
check bash -c "codesign --verify --strict '$pkgdir/host/apv-host' '$pkgdir/host/lib/libreims_vgpu.dylib' '$pkgdir/tools/metal-registry'"
check bash -c "for s in '$pkgdir'/scripts/*.sh; do bash -n \"\$s\" || exit 1; done"
check bash -c "xcrun lipo -verify_arch x86_64 '$pkgdir/xegfx/XeGfxAccel.kext/Contents/MacOS/XeGfxAccel'"
check bash -c "grep -aq 'XG_PANEL ABI 1' '$pkgdir/xegfx/XeGfxAccel.kext/Contents/MacOS/XeGfxAccel'"
check bash -c "test -f '$pkgdir/xegfx/PANEL-ABI.md' -a -f '$pkgdir/xegfx/xegfx-panel.patch'"
check bash -c "codesign --verify --strict '$pkgdir/xegfx/XeGfxAccel.kext'"

echo
if [[ $fail -eq 0 ]]; then
    echo "RESULT: PASS (all sections ok); log: $out"
    exit 0
fi
echo "RESULT: FAIL; log: $out"
exit 1
