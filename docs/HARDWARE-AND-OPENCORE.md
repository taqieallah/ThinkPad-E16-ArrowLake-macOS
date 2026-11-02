# Hardware, BIOS and OpenCore

## Machine

| Part | Details |
|---|---|
| Laptop | Lenovo ThinkPad E16 (subsystem `17aa:5134`) |
| CPU | Intel Core Ultra 7 255H (Arrow Lake-H, CPUID model `0xC5`), 16 cores, no HT |
| iGPU | Intel Arc 140T `8086:7D51` rev `0x03`, Graphics IP 12.74 (GMD_ID `0x03128004`), Media 13.00, 8 Xe-cores / 128 EUs, Display IP 14, at `PciRoot(0x0)/Pci(0x2,0x0)` (`\_SB.PC00.GFX0`) |
| Panel | 1920×1200 eDP, 60 Hz (157.5 MHz pixel clock, 2120×1238 total) |
| NVMe | KIOXIA BG6 `1E0F:001A` at `PciRoot(0x0)/Pci(0x6,0x2)/Pci(0x0,0x0)` |
| Ethernet | Intel I219-V `8086:550B` |
| Wi-Fi / BT | Intel CNVi `8086:7740` |
| Audio | HDA at `Pci(0x1F,0x3)`, AppleALC `layout-id 11` |
| BIOS | Insyde |
| macOS | Tahoe 26.x, installed on the internal NVMe next to Windows |
| OpenCore | on a USB stick (`EFI/OC`) |

## BIOS

- X2APIC **Off** (has to go first, then VT-d becomes editable)
- VT-d **Off**
- Secure Boot **Off**
- Graphics: the iGPU must stay enabled (no `disable-gpu`)

## OpenCore

**Booter quirks:** DevirtualiseMmio, RebuildAppleMemoryMap, SyncRuntimePermissions, ProtectUefiServices,
SetupVirtualMap, ProvideCustomSlide = true; EnableWriteUnprotector = false.

**Kernel quirks:** `ProvideCurrentCpuInfo` = true (without it: panic in `x86_validate_topology`),
`SetApfsTrimTimeout` = 0 (without it storagekitd/fskit crash-loop every 10 s), `DisableIoMapper` = true,
`AppleXcpmForceBoost` = false.

**Kexts (load order matters):** Lilu, VirtualSMC, ECEnabler, SMCBatteryManager, AppleALC, CpuTscSync,
AppleMCEReporterDisabler, RestrictEvents, USBToolBox + UTBDefault, VoodooPS2 (keyboard), VoodooI2C chain
(touchpad), WhateverGreen (with `-wegoff`), IntelMausiEthernet, AirportItlwm (MinKernel 25). The GPU kexts
(XeGfx, XeGfxAccel, XeGfxIntelFB) are **not** injected by OpenCore: they live in the auxiliary kernel collection.

**DeviceProperties:** `Pci(0x15,0x0)` device-id `e8a00000` (I2C for the touchpad); `Pci(0x1F,0x3)` layout-id
`0b000000`.

**SMBIOS:** MacBookPro16,2 (MacPro7,1 was tried for diagnosis and changed nothing).

**NVRAM:** `boot-args` is in `NVRAM > Delete` so config edits apply every boot; `PollAppleHotKeys` = true
(Win+S at the picker = single-user mode).

**boot-args (daily):**
```
-v debug=0x100 keepsyms=1 -vi2c-force-polling -ibtcompatbeta revpatch=sbvmm -wegoff -nmintelfboff
amfi_get_out_of_my_way=0x1 ipc_control_port_options=0 nvrmacpibl=1
```
(`amfi_get_out_of_my_way` is needed for the ad-hoc signed Metal plugin; `nvrmacpibl=1` = backlight through ACPI.)
The ArcMTL experiment adds `arcxe=1` (test) or `arcxe=1 arcfb=1 arcaccel=1 -xeintelfboff` (desktop) through
`scripts/arc/arc-mode.sh`.

## ACPI (the hard part)

The **firmware's own DSDT** is used, not a dumped `DSDT.aml` (an old dump had stale GNVS/MNVS/ONVA addresses from
before the VT-d/X2APIC change). macOS's ACPICA (`20160930`) rejects the whole stock DSDT because of
module-level `If` blocks, so they are patched into `Scope`s (same idea as WTLLegionOpenCore):

1. `If (PCHS != 4)` → `Scope (PC00)` / `Scope (\)`, ×3
2. `If (PCHA != 0)` → `Scope (\_SB)` / `Scope (\)`, ×3 (one holds `Device (PC02)`)
3. Legion-style: `SBRG` store → Method ×2, XHCI `DUWS/PU2C/PU3C` stores → Methods
4. `EC._INI` → `XINI`, and the `OINI ()` call removed from `PC00._INI` (both reach an SMI that spins forever in
   `While (ERR == One)`, confirmed with acpiexec 20160930)
5. `EC._Q4F` → `XQ4F` (UCSI event storm: `UBTC.ECSI` has no handler)
6. Renames: EC `_STA→XSTA`, GPI0 `_STA→XSTA`, `NBCF 0→1`, `PNLF→XNLF`, `_OSI→XOSI`

**SSDTs:** SBUS, EC, GPI0, MCHC, PLUG-ALT, RTCAWAC, USBX, XOSI, **SSDT-PC02-OFF**. The `If (PCHA)` patch makes the
phantom root bridge `PC02` always present, macOS then enumerates bus 0 twice, AppleNVMe fails `fIOMapRegs` and
the boot ends at "Still waiting for root device"; SSDT-PC02-OFF returns `_STA = 0` for it on Darwin.

## Order things were solved

1. Hang at EXITBS → VT-d off (after X2APIC off)
2. `x86_validate_topology` panic → `ProvideCurrentCpuInfo`
3. DSDT not loading → If→Scope patches on the stock DSDT
4. SMI infinite loop → `EC._INI` / `OINI` removed (temporary)
5. NVMe missing → SSDT-PC02-OFF
6. `_Q4F` storm → rename
7. Hard freeze as soon as the iGPU was visible → isolated by hiding PCI devices; solved by the XeGfx stack
   bring-up order (core → accelerator → AGDC K5 → one WindowServer restart), see GPU-STACK.md
