# Building on an Apple Silicon Mac, installing on the laptop

Everything is cross-built on an M-series Mac (macOS 26, Command Line Tools with the 26.x SDK) and carried to the
laptop on the OpenCore USB stick (`/Volumes/1401/xegfx-e16`). The laptop has no developer tools.

## Sources on the Mac

```
~/src/xe-e16/wtl     WTLIntelGfx clone (ff64f83) + patches/wtlintelgfx-e16.diff
~/src/xe-e16/nm      NullMoth translator (v2.6.6) for build-perf.sh
~/src/kcabi          kcabi (kernel collection ABI tools, needed by WTLIntelGfx's link checks)
~/src/xe-src         FreeBSD sys (sparse, d2145e9b96448da34d3cfede24c509af6d830c92),
                     drm-kmod c16de0f9fa84f70b9551f69fde837a7f3a73c0e9, GuC firmware
```

Apply the E16 changes: `cd ~/src/xe-e16/wtl && git apply /path/to/patches/wtlintelgfx-e16.diff`
(the flip core file `xkpi/src/i915/xg_i915_flip.c` is created by the same diff).

## The laptop's kernel collection

The core links against the **laptop's** `BootKernelExtensions.kc`, so after every macOS update copy it:
```
# laptop
cp /System/Library/KernelCollections/BootKernelExtensions.kc /Volumes/1401/xegfx-e16/
```
`build-core.sh` picks it up from the stick.

## Full source build (core + accelerator + plugin)

```
# Mac, stick plugged in
bash ~/Desktop/xe-update/core/build-core.sh          # ends with DONE, copies to the stick
# laptop
sudo bash /Volumes/1401/xegfx-e16/full-install.sh    # backs up, installs into /Library/Extensions,
                                                     # rebuilds the aux collection, checks no kext was dropped
# restart (approve in Privacy & Security if asked), log in
sudo bash /Volumes/1401/xegfx-e16/xe-up.sh           # v10 turns on flip + K9b by itself
```
Undo: `sudo bash /Volumes/1401/xegfx-e16/full-install.sh --undo` (restores the previous collection and kexts).

Other scripts: `build-perf.sh`/`perf-install.sh` (plugin + translator only), `fb-install.sh` (XeGfxIntelFB only),
`efi-apply.sh`, `wifi-apply.sh`, `cpu-apply.sh` (WTLLegionCpuPower, not applied), `colors-test.sh`.

## Gotchas found while building

- `kmutil libraries` on an arm64 Mac only knows arm64 KPIs: WTLIntelGfx's `kpi_check.py` fails on every symbol.
  It is skipped on arm64 hosts; the laptop's `kmutil create` enforces the same rule at install.
- `strings` is not on the laptop (no CLT): scripts use `grep -a`.
- macOS `grep -q` at the end of a pipe under `set -o pipefail` makes `nm` die of SIGPIPE: capture into a variable first.
- `otool -L` prints the library's own install name first: exclude it when checking for external dependencies.
- Homebrew no longer installs on Intel/Rosetta: x86_64 userspace (Mesa) is cross-compiled from arm64 Homebrew
  (see ARCMTL-EXPERIMENT.md, `build-arc-anv.sh`).
- The FAT USB stick sometimes drops from `/Volumes`: re-plug, or write through the stick's real path.
