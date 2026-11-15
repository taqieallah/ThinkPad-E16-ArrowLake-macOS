#!/bin/bash
# One-shot integrated test harness for the E16 AppleParavirtGPU <-> Reims bridge.
#
# Run it from Terminal in the logged-in GUI session, NOT with sudo:
#
#   cd /path/to/E16-APV-Live-0.2
#   bash scripts/apv-up.sh
#
# Optional environment:
#   APV_SECONDS=60      how long the daemon runs (default 45)
#   APV_REGISTRY_ID=... force the Metal registry id (otherwise tools/metal-registry)
#
# It writes a self-contained report folder (and a .zip of it) to the Desktop and
# prints the path. The report is what a follow-up session needs: host log, kernel
# log lines, ioreg, loaded kexts, Metal devices, panic reports.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
stamp="$(date +%Y%m%d-%H%M%S)"
report="$HOME/Desktop/E16-APV-live-$stamp"
mkdir -p "$report"
exec > >(tee -ia "$report/run.log") 2>&1

echo "=============================================================="
echo " E16 AppleParavirtGPU <-> Reims live test"
echo " report: $report"
echo "=============================================================="

# ---------------------------------------------------------------- 1. preflight
{
    echo "== sw_vers =="; sw_vers 2>&1
    echo "== uname =="; uname -a
    echo "== bootargs =="; sysctl -n kern.bootargs 2>&1
    echo "== loaded kexts =="; kmutil showloaded 2>&1 | grep -iE 'ReimsPCIProbe|XeGfx|NMIntelFB|AppleParavirtGPU' || true
    echo "== ReimsPCIProbe service =="; ioreg -p IOService -r -n ReimsPCIProbe -l -w0 2>&1 | head -30 || true
    echo "== ReimsPCINub =="; ioreg -p IOService -r -n ReimsPCINub -l -w0 2>&1 | head -30 || true
} > "$report/preflight.txt" 2>&1
cat "$report/preflight.txt"

if ! grep -q 'reimspci=12' "$report/preflight.txt"; then
    echo
    echo "WARNING: the boot argument reimspci=12 was not found. Add it to"
    echo "         NVRAM boot-args (or the OpenCore config) and reboot first."
fi
if ! grep -qi 'ReimsPCIProbe' "$report/preflight.txt"; then
    echo
    echo "WARNING: ReimsPCIProbe (this kext) does not appear in kmutil showloaded."
    echo "         Install kext/ReimsPCIProbe.kext into OpenCore first:"
    echo "         bash scripts/install-efi.sh /Volumes/EFI"
fi

# ------------------------------------------------------- 2. Metal device / id
regid=0
if [ -n "${APV_REGISTRY_ID:-}" ]; then
    regid="$APV_REGISTRY_ID"
    echo "Metal registry id forced: $regid"
elif [ -x "$here/tools/metal-registry" ]; then
    "$here/tools/metal-registry" > "$report/metal.txt" 2>&1 || true
    cat "$report/metal.txt"
    line="$(grep -m1 'REIMS_METAL_REGISTRY_ID=' "$report/metal.txt" || true)"
    [ -n "$line" ] && regid="${line#REIMS_METAL_REGISTRY_ID=}"
else
    echo "tools/metal-registry missing; using the system default Metal device (id 0)"
fi
echo "Metal registry id used: $regid"
if ! grep -qi 'Intel Arrow Lake' "$report/metal.txt" 2>/dev/null; then
    echo "NOTE: the XeGfx Metal device was not seen. If Metal devices are missing,"
    echo "      run the daily XeGfx start first:  sudo bash /Volumes/1401/xegfx-e16/final/xe-up.sh"
fi

# ------------------------------------------------------------- 3. run the test
seconds="${APV_SECONDS:-45}"
host_args=(--registry-id "$regid" --seconds "$seconds" --log "$report/host.log")
if [ "${APV_DISPLAY:-0}" = "1" ]; then
    host_args+=(--display)
    echo "Display path requested (needs the patched XeGfxAccel; otherwise it logs and continues)."
else
    echo "APV_DISPLAY not set to 1: bridge-only run, the panel is left to XeGfx."
fi
echo
echo "== running apv-host for ${seconds}s =="
"$here/host/apv-host" "${host_args[@]}"
host_status=$?
echo "apv-host exit status: $host_status"

# ------------------------------------------------- 4. collect after-the-fact state
ioreg -p IOService -l -w0 > "$report/ioreg-full.txt" 2>/dev/null || true
kmutil showloaded > "$report/loaded.txt" 2>/dev/null || true
sysctl -n kern.bootargs > "$report/bootargs.txt" 2>/dev/null || true

{
    echo "== kernel log (last 10 minutes, this boot) =="
    log show --last 10m --style compact --predicate '
        process == "kernel" AND (
            eventMessage CONTAINS[c] "ReimsAPV" OR
            eventMessage CONTAINS[c] "ReimsPCIProbe" OR
            eventMessage CONTAINS[c] "AppleParavirtGPU" OR
            eventMessage CONTAINS[c] "AppleParavirtAccelerator")' 2>/dev/null
} > "$report/kernel.log" || true
if [ ! -s "$report/kernel.log" ]; then
    echo "(kernel log filter produced nothing; trying without predicate)" > "$report/kernel.log"
    log show --last 10m --style compact 2>/dev/null | grep -iE 'ReimsAPV|ReimsPCIProbe|AppleParavirtGPU' >> "$report/kernel.log" || true
fi

ls -lt "$HOME/Library/Logs/DiagnosticReports" 2>/dev/null | head -8 > "$report/panic-reports.txt" || true
cp "$HOME/Library/Logs/DiagnosticReports/"*.panic "$report/" 2>/dev/null || true

# ---------------------------------------------------------------- 5. summary
echo
echo "======================= summary =============================="
grep -E 'apv-host exit|Reims device created|bridge clients open|BAR0 cells|bridge armed|stage |map_memory|FATAL|WATCHDOG|IRQ0 delivered|kernel bridge stats|teardown complete|self-check|panel:|display:' "$report/host.log" 2>/dev/null | tail -70
echo
echo "Kernel-side markers:"
grep -E 'ReimsAPVBridge|ReimsAPV' "$report/kernel.log" 2>/dev/null | tail -60
echo
echo "=============================================================="
echo "Write down the markers you see:"
echo "  SUCCESS CANDIDATE : 'patched' + 'kernel bridge stats: dispatch=.. patched=4'"
echo "                      + one or more 'IRQ0 delivered' + map_memory lines"
echo "  PATCH PROBLEM     : 'patch-no-apv-image' / 'patch-byte-mismatch' / 'patch refused'"
echo "  DAEMON PROBLEM    : 'session not ready' / 'transport timeout' / FATAL map_memory"
echo "  PANEL PATH        : 'panel: XeGfx pipe ...' + 'display: guest=.. host=.. sent=..'"
echo "                      (only with the patched XeGfxAccel installed)"
echo "  KERNEL PANIC      : a .panic file appeared in $report"
echo "=============================================================="

( cd "$(dirname "$report")" && ditto -c -k --keepParent "$(basename "$report")" "$report.zip" ) 2>/dev/null || true
echo "Report folder: $report"
[ -f "$report.zip" ] && echo "Report zip   : $report.zip"
exit 0
