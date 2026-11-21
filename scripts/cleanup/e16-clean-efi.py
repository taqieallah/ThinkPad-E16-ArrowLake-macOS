#!/usr/bin/env python3
"""On the Mac M5 with the stick in:   python3 e16-clean-efi.py [/Volumes/1401/EFI/OC/config.plist] [--apply]

Takes the experiments out of the E16's OpenCore config.plist and leaves a plain OpenCore for macOS:
  - boot-args: drops nmxintel=, nmxtrace=, -nvoff, reimspci=, apvpatch= (the MeowXE3 / NullMoth / Reims switches);
    keeps everything else (verbose, AMFI, -wegoff, -nmintelfb*, nvrmacpibl, ...).
  - NVRAM: removes nullmoth-fbflags (Add and Delete).
  - Kernel > Add: removes MeowXE3Boot, ReimsPCIProbe, Apv*/AppleParavirt*, LegionCpuPower, NMX*/NullMoth* entries.
    E16ConsoleRange stays (boot hangs on the verbose text without it); WhateverGreen, Lilu, VirtualSMC etc. untouched.
  - Misc > Tools / Entries: removes "MeowXE3: start once without driver" (NullMothSafe.efi) and other NullMoth/MeowXE3 items.
Without --apply it only prints what it would change. With --apply it first copies config.plist to
config.plist.before-clean-<time>, writes the new file and reads it back. The kext folders in EFI/OC/Kexts are left on
the stick (an entry that is gone from config.plist is not loaded).
"""
import datetime, pathlib, plistlib, shutil, sys

args = [a for a in sys.argv[1:] if not a.startswith("--")]
apply = "--apply" in sys.argv
cfg = pathlib.Path(args[0] if args else "/Volumes/1401/EFI/OC/config.plist")
p = plistlib.loads(cfg.read_bytes())
G = "7C436110-AB2A-4BBB-A880-FE41995C9F82"
changes = []

DROP_ARG = ("nmxintel=", "nmxtrace=", "reimspci=", "apvpatch=")
nv = p["NVRAM"]["Add"].setdefault(G, {})
ba = nv.get("boot-args", "")
kept = [t for t in ba.split() if t != "-nvoff" and not t.startswith(DROP_ARG)]
if kept != ba.split():
    changes.append(f"boot-args: drop {[t for t in ba.split() if t not in kept]}")
    nv["boot-args"] = " ".join(kept)
if "nullmoth-fbflags" in nv:
    changes.append("NVRAM Add: remove nullmoth-fbflags"); del nv["nullmoth-fbflags"]
dl = p["NVRAM"].get("Delete", {}).get(G, [])
if "nullmoth-fbflags" in dl:
    changes.append("NVRAM Delete: remove nullmoth-fbflags"); dl.remove("nullmoth-fbflags")

BAD_KEXT = ("MeowXE3", "ReimsPCIProbe", "Apv", "AppleParavirt", "LegionCpuPower", "NMX", "NullMoth")
ka = p["Kernel"]["Add"]
keep = [k for k in ka if not k.get("BundlePath", "").startswith(BAD_KEXT)]
for k in ka:
    if k not in keep: changes.append(f"Kernel Add: remove {k.get('BundlePath')} (Enabled={k.get('Enabled')})")
p["Kernel"]["Add"] = keep

def bad(item):
    s = " ".join(str(item.get(x, "")) for x in ("Name", "Path", "Arguments", "Comment"))
    return any(w in s for w in ("MeowXE3", "NullMoth", "nvoff"))
for sect in ("Tools", "Entries"):
    lst = p["Misc"].get(sect, [])
    for it in [i for i in lst if bad(i)]:
        changes.append(f"Misc {sect}: remove {it.get('Name')} ({it.get('Path')})"); lst.remove(it)

ec = [k for k in p["Kernel"]["Add"] if "E16ConsoleRange" in k.get("BundlePath", "")]
print(f"config: {cfg}")
print("E16ConsoleRange:", "kept, Enabled=%s" % ec[0].get("Enabled") if ec else "NOT in config.plist (fine only if the boot does not hang)")
print("boot-args after:", nv.get("boot-args"))
print("\n".join("  - " + c for c in changes) if changes else "  nothing to change: already clean")
if apply and changes:
    bak = cfg.with_name(f"config.plist.before-clean-{datetime.datetime.now():%m%d-%H%M%S}")
    shutil.copy2(cfg, bak)
    cfg.write_bytes(plistlib.dumps(p))
    plistlib.loads(cfg.read_bytes())
    print(f"written (backup: {bak.name}). Eject the stick before you pull it out.")
elif changes:
    print("dry run: add --apply to write it")
