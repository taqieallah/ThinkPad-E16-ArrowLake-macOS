#!/bin/bash
# On the laptop, after xe-up (the GPU must be up):   bash ~/Desktop/k20-laptop/k20-run.sh [area ...]
# Runs reims-vgpu's host side on our ANV, driven by its own runner the way Apple's paravirtual GPU driver drives it in a
# VM. Each scenario: OK (ran to its end), DIED (the host side crashed), HUNG (60 s), plus how its output compares with
# what Apple's Metal produced on the reims developers' Mac. Results: k20/results/ and k20/summary.txt.
HERE=$(cd "$(dirname "$0")" && pwd); GB=/Library/GPUBundles/nvmtl; R=$HERE/results; mkdir -p "$R"; S=$HERE/summary.txt
export VK_ICD_FILENAMES=$GB/intel_icd.json VK_DRIVER_FILES=$GB/intel_icd.json DYLD_FALLBACK_LIBRARY_PATH=$GB
T=/tmp/k20; rm -rf "$T"; mkdir -p "$T"; cp "$HERE/pgrun" "$HERE/libreims_vgpu.dylib" "$T/"; chmod +x "$T/pgrun"
ln -sf "$GB/libvulkan.dylib" "$T/libvulkan.dylib"; ln -sf "$GB/libvulkan.dylib" "$T/libvulkan.1.dylib"
AREAS=${*:-$(ls "$HERE/scenarios")}
ok=0; died=0; hung=0; same=0; diff=0; n=0
echo "== $(date)  areas: $AREAS" > "$S"
for a in $AREAS; do for f in "$HERE/scenarios/$a"/*.jsonl; do
  s=$(basename "$f" .jsonl); e=$(ls "$HERE/expected/$a/$s/" 2>/dev/null | grep -v -- - | head -1); setup=${e%%[.@]*}; setup=${setup:-map}
  out=$R/$s.$setup.jsonl; n=$((n+1))
  ( cd "$T" && perl -e 'alarm 60; exec @ARGV' ./pgrun "$f" "$out" --setup "$setup" --fixtures "$HERE/fixtures" ) > "$R/$s.err" 2>&1; rc=$?
  case $rc in 0) st=OK; ok=$((ok+1));; 142) st=HUNG; hung=$((hung+1));; *) st="DIED($rc)"; died=$((died+1));; esac
  cmpv=-; if [ -f "$HERE/expected/$a/$s/$e" ] && [ -f "$out" ]; then
    if diff -q <(grep -v '"t_\|"d_' "$HERE/expected/$a/$s/$e" | sed 's/"t_[a-z_]*":[0-9.]*,\{0,1\}//g') <(grep -v '"t_\|"d_' "$out" | sed 's/"t_[a-z_]*":[0-9.]*,\{0,1\}//g') >/dev/null; then cmpv=same; same=$((same+1)); else cmpv=differs; diff=$((diff+1)); fi; fi
  printf '%-60s %-10s %s\n' "$a/$s" "$st" "$cmpv" | tee -a "$S"
done; done
echo "== $n scenarios: OK $ok, DIED $died, HUNG $hung | same as Apple's Metal $same, differs $diff" | tee -a "$S"
echo "(send the folder $HERE back to the Mac by AnyDesk: summary.txt and results/)"
