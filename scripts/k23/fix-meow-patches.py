#!/usr/bin/env python3
"""fix-meow-patches.py <MeowXE3 checkout>: makes MeowXE3's published patch order apply as setup-nmxgpu-wcl.sh runs it.
0104-drm-kmod-client-pid-is-the-process.patch repeats, as its last hunk, ericek's drm-kmod 0001 (no synchronize_rcu
in drm_file_update_pid on FreeBSD), which the setup applies first; git refuses the repeated hunk. Drop it. Idempotent."""
import pathlib, sys
p = pathlib.Path(sys.argv[1]) / "patches/nmxgpu/0104-drm-kmod-client-pid-is-the-process.patch"
s = p.read_text()
i = s.find("@@ -498,7 +500,14 @@ void drm_file_update_pid")
if i < 0:
    print("0104: already without the repeated hunk"); sys.exit(0)
j = s.find("\n@@ ", i + 1); k = s.find("\ndiff --git", i + 1)
ends = [x for x in (j, k) if x >= 0]
s = s[:i] + (s[min(ends) + 1:] if ends else "")
p.write_text(s); print("0104: repeated drm_file_update_pid hunk dropped (ericek's drm-kmod 0001 has it)")
