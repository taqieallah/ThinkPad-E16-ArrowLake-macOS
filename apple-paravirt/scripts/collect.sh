#!/bin/bash
# Collect evidence only (no install, no daemon). Safe to run any time.
#
#   bash scripts/collect.sh
#
# Prints a report folder path on the Desktop.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
report="$HOME/Desktop/E16-APV-collect-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$report"
{
    echo "== sw_vers =="; sw_vers
    echo "== uname =="; uname -a
    echo "== bootargs =="; sysctl -n kern.bootargs
    echo "== loaded =="; kmutil showloaded
    echo "== ReimsPCIProbe =="; ioreg -p IOService -r -n ReimsPCIProbe -l -w0
    echo "== ReimsPCINub =="; ioreg -p IOService -r -n ReimsPCINub -l -w0
    echo "== AppleParavirtGPU services =="; ioreg -p IOService -l -w0 | grep -i -A3 -B3 paravirt
} > "$report/system.txt" 2>&1
ioreg -p IOService -l -w0 > "$report/ioreg-full.txt" 2>/dev/null || true
log show --last 30m --style compact 2>/dev/null \
    | grep -iE 'ReimsAPV|ReimsPCIProbe|AppleParavirtGPU|AppleParavirtAccelerator' \
    > "$report/kernel.log" || true
"$here/tools/metal-registry" > "$report/metal.txt" 2>&1 || true
ls -lt "$HOME/Library/Logs/DiagnosticReports" 2>/dev/null | head -8 > "$report/panic-reports.txt" || true
( cd "$(dirname "$report")" && ditto -c -k --keepParent "$(basename "$report")" "$report.zip" ) 2>/dev/null || true
echo "report: $report"
[ -f "$report.zip" ] && echo "zip   : $report.zip"
