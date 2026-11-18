#!/bin/bash
# On the laptop (boot "MeowXE3: start once without driver" is fine):
#   sudo bash /Volumes/1401/xegfx-e16/MeowARL/k23-metal-check.sh
# Why: with nullmoth-fbflags 1833 WindowServer logs "Cannot find executable for CFBundle /Library/GPUBundles/
# NVMTLDriver.bundle (not loaded)" ~35 times, and the console fills with "disallowing unsupported code signature page
# shift: 14 / unable to create a validated cs_blob object: 85" before CoreDisplay's assert. So: what is installed in
# /Library/GPUBundles, how each Mach-O there is signed (page size 4096 is the only one x86 macOS accepts), and which
# process the kernel's page-shift refusals came from. Reads only. Output: xegfx-e16/logs/metal-<time>/ on the stick.
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
B=/Volumes/1401/xegfx-e16/logs; mkdir -p "$B" 2>/dev/null || B=/Users/Shared
D=$B/metal-$(date +%m%d-%H%M%S); mkdir -p "$D"
G=/Library/GPUBundles
{ sw_vers; echo; ls -la "$G"; echo; ls -laR "$G" 2>&1 | head -200; } > "$D/tree.txt" 2>&1
{ for p in "$G"/*.bundle/Contents/Info.plist; do echo "== $p"; plutil -p "$p"; done; } > "$D/infoplist.txt" 2>&1
xattr -lr "$G" > "$D/xattr.txt" 2>&1
# every Mach-O under the GPU bundles, the kexts and the MeowARL support folder: arch + signature page size
{ find "$G" /Library/Extensions/MeowXE3.kext "/Library/Application Support/MeowARL" -type f ! -name '._*' 2>/dev/null | while IFS= read -r f; do
    t=$(file -b "$f"); case "$t" in *Mach-O*) ;; *) continue;; esac
    echo "== $f"; echo "   $t"
    codesign -dvvv "$f" 2>&1 | grep -E "Identifier=|Format=|CodeDirectory|Page size|Signature|flags=|TeamIdentifier" | sed 's/^/   /'
  done; } > "$D/signatures.txt" 2>&1
grep -B4 "Page size=16384" "$D/signatures.txt" | grep "^== " > "$D/pagesize-16k.txt"
# the kernel's code-signing refusals with their thread ids (kernel[0:<tid>] = the same tid as the process line)
log show --last 4h --predicate 'eventMessage CONTAINS "page shift" OR eventMessage CONTAINS "cs_blob" OR eventMessage CONTAINS "NVMTLDriver" OR eventMessage CONTAINS[c] "library validation" OR (sender == "AppleMobileFileIntegrity")' --style compact > "$D/cs-log.txt" 2>&1
log show --last 4h --predicate 'process == "WindowServer" AND (eventMessage CONTAINS "Cannot find executable" OR eventMessage CONTAINS "dlopen" OR eventMessage CONTAINS "MTL")' --style compact > "$D/ws-metal.txt" 2>&1
echo "Mach-O files: $(grep -c '^== ' "$D/signatures.txt")   with 16 KiB pages: $(wc -l < "$D/pagesize-16k.txt" | tr -d ' ')"
echo "page-shift refusals logged: $(grep -c 'page shift' "$D/cs-log.txt")"
echo "saved in $D"
