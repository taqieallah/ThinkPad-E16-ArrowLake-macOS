# E16-APV-Live 0.3.0 manifest

## Binaries

| file | arch | sha256 |
|---|---|---|
| kext/ReimsPCIProbe.kext/Contents/MacOS/ReimsPCIProbe | x86_64 | 784e48ca59f9d5f08e79103e8e3aff7c8081109f04471e33ba8bd96d113eab38 |
| host/apv-host | x86_64 | 230a95588de5baaac41960a0acf7d4b7e984940221de45c0fdee74227220eede |
| host/lib/libreims_vgpu.dylib | x86_64 | 4b95ce07c052b109035cbb8fbfbead4e5128b7f3ed4fa619455600119cc7e918 |
| tools/metal-registry | x86_64 | 545c791a211d114a7b28fe61bf00b067b57ec4a3c91c8c22d45cc95e7942c1ba |
| xegfx/XeGfxAccel.kext/Contents/MacOS/XeGfxAccel | x86_64 | 0114f3f2ef433360e88a8747c6d631bd6d7d074a60718023f6e4bf4fe04c8f5a |

## Sources

| file | sha256 |
|---|---|
| src/ReimsAPVBridge.cpp | adda32aff7d14aa267518e9e0a6e57c504af970f534d2d1530d24a62b7a61e8f |
| src/SiteTable.hpp | 204217974384d7e8136c613098cc99de40cb5c14873282c48f73806eac1be34a |
| src/sites.json | 20f6207166b825dcef5df519475b1ce252e11b8c6d76efa31e84fccc91e7a74b |
| src/APVSites.generated.hpp | 9cdc3b1b7eb3a760f303de686678e8d195df0bf04c7739d3e9fe9e1c21df708b |
| src/MMIOTransaction.hpp | e20fa8cbd957469421647a29ee25b86b3728f19ede7007b8138d1b6bc74855d1 |
| src/Info.plist | c19d46ea86ddca59c7549241523fa9cf31751a1e5e9f3368d0b6653bad219025 |
| src/kmod.c | ba241e1350d35985e9299dd2dd7c5c23e94e599908b5c902e9613ebfd763952c |
| src/build.sh | e28265593c002f78272f8a2bf545a2797b3fbd61df33612d8df58f364ac40767 |
| src/host/apv-host.cpp | 07fa22ba28e6071e55617953bcb1448b8193950bd44ed3bd5fd0cb34c8a28556 |
| src/host/panel.cpp | ce47c905e818d4c459a5095a4e5ff417f6f87afa0a7d5be2332497df36d6e0f0 |
| src/host/panel.hpp | c2b02b183d74e4a208e73634e30794d02b27a7285fb4698f6237c0e79ce6b4ee |
| src/host/xg_panel_abi.h | 4afa1fd7995fcfc9ab5217c7139052045719293d200032e86a94208f3d172671 |
| src/host/build.sh | 549c57435c1861d6018e22c33fc0a0471f191a473e83118beb57068545b692d9 |
| src/tooling/verify-sites.py | 351e26d15b5240c2ff56d2a8c76085f5502d86e1bff89f555712aa53f3710c07 |
| src/tooling/gen-site-table.py | 9c15e9014847d7dec531aa4e2b3434431e4f331526d2ba3e85a59b95cb0cfeaa |
| src/tooling/stub-sim.cpp | e70801db73cff939068c0bb185a0bcaa59cb00e6afec763750830bf175bedb92 |
| src/tooling/run-verification.sh | f42097296b92c5065b0ebad5a8e713e8443237636b466e307f7ab9a44f335c84 |
| src/xegfx/build-xegfx-accel.sh | d54fb5e31d3b70d1ee817937475bdd539435d404b60bfec7973ce88e45a15b8f |
| xegfx/patched/nvrm-accel.cpp | 37b110c7c3b71736653fdf1ddd25e914ccff028b858ff7be88fdf95516353d68 |
| xegfx/patched/xg_panel_abi.h | 4afa1fd7995fcfc9ab5217c7139052045719293d200032e86a94208f3d172671 |
| xegfx/xegfx-panel.patch | fc19fa94a109ab8d29e5628a81bfff10e5a8aef3fb5dccdcb368072f746e85bf |
| xegfx/PANEL-ABI.md | 035299d3da9176364b77ee56f0a11f4844cae34510a8bcdd9f373448adf3265e |

## Provenance

- AppleParavirtGPU: macOS 26.7.1 build 25G241, UUID 0CAE9E29-BC33-315D-82A7-A7D30E9B971E, sha256 14985840a5d1f7b2859b25b21413860aa0f6de66bf845f505a777ae8a174d51c; 19 BAR0 instructions audited, 7 patched.
- Reims: commit 1fe0acb68b287db36f1e6c7b9f45383940b8a76f; C library built for x86_64-apple-darwin with SDKROOT=MacOSX26.5.sdk.
- XeGfx: WTLIntelGfx ff64f83 + local E16 modifications, built with OGKM 615.78.08; the only change is the selector-5 panel interface (no new undefined symbols vs the installed accelerator).
- Package zip: ditto with --norsrc --noextattr (AppleDouble files break kext code signatures).

