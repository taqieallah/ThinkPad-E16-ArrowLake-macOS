#!/bin/bash
# On the laptop, after xe-up:   bash /Volumes/1401/xegfx-e16/k14/k14c-profile.sh
# Samples where the CPU goes while each stack draws the desktop-like scene (blur scene, ~1500 frames), 10 s each. Writes
# old-sample.txt and new-sample.txt next to this script. Then, on the Mac:  cp /Volumes/1401/xegfx-e16/k14/*-sample.txt ~/Desktop/xe-update/k14/
HERE=$(cd "$(dirname "$0")" && pwd); GB=/Library/GPUBundles/nvmtl
T=/tmp/xe-m2v-bench; cp "$HERE/xe-m2v-bench" "$T"; chmod +x "$T"; mkdir -p /tmp/xe-m2v-cache
export VK_ICD_FILENAMES=$GB/intel_icd.json VK_DRIVER_FILES=$GB/intel_icd.json XE_FRAMES=1500 XE_SCENE=blur
for mode in old new; do
  echo "== $mode: warming up (shaders), then sampling 10 s"
  "$T" $mode "$GB/libvulkan.dylib" /tmp/xe-m2v-cache > "/tmp/xe-$mode.out" 2>&1 & P=$!
  # wait until the first frame is out (the shader compile can take ~20 s on the old stack)
  for i in $(seq 1 60); do sleep 1; kill -0 $P 2>/dev/null || break; [ $i -ge 8 ] && [ $mode = new ] && break; [ $i -ge 25 ] && break; done
  sample $P 10 -file "$HERE/$mode-sample.txt" >/dev/null 2>&1 && echo "   $HERE/$mode-sample.txt" || echo "   sample failed"
  kill $P 2>/dev/null; wait $P 2>/dev/null
done
top -l 1 -n 0 | grep -E "CPU usage|PhysMem"
echo "done - copy the two *-sample.txt files to the Mac (see the top of this script)"
