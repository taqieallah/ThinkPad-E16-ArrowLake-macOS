# E16-APV-Live 0.3.2 — جسر AppleParavirtGPU ↔ Reims + مسار اللوحة

تحديث 15 نوفمبر 2026. النسخة دي بتكمّل 0.2.0 في حاجتين: **تغطية كل مواقع الـpatch**
اللي تدقيق 25G241 طلبها،and **مسار عرض Reims على اللوحة الداخلية** (باتش XeGfxAccel
+ pipeline في الـdaemon). يعني كل حاجة اتنفذت واتبنيت هنا؛ اللي باقي هو **تشغيل
واحد على الـE16 نفسه**.

```
AppleParavirtGPU 25G241 (باينري أبل الحقيقي)
   ↓ 7 مواقع BAR0 داخلية متوقّفة (UUID + بايتات + stubs مولّدة + offline execution test)
ReimsPCIProbe.kext 0.3.0  (وضع reimspci=12، 7 patches، صفحة BAR0 مشتركة، IRQ0، تصدير صفحات)
   ↓
apv-host (جلسة المستخدم) — صاحب جلسة Reims الوحيد + Metal على جهاز XeGfx
   ↓ rvg_device_mmio_read/write                      ↓ Reims display port 0
Reims (backend Metal)                                 Reims frame target
                                                        ↓ encode/readback
                                              IOSurface + patched XeGfxAccel
                                                        ↓ PLANE_SURF / GGTT / FRMCOUNT
                                                   شاشة اللابتوب
```

## الجديد في 0.3.0

1. **7 مواقع patch** بدل 4 (كامل قائمة التدقيق ما عدا cursor الـspin):
   - `0x1034` version write+read (pair) وfallback write
   - `0x1018` stamps، `0x1014` display (read-to-clear)
   - `0x122c` عدد المنافذ (بقى dispatched؛ الخلية المشتركة تفضل fallback)
   - `0x102c` الـfault مع إعادة إنتاج الـ`cmpl/je` (فرعين مطلقين في الـstub)
   - `0x1000` تعطيل الـFIFO عند الـteardown (synchronous، يضمن التطبيق قبل تحرير الصفحات)
   - `0x100c` cursor (spin loop) **مقصود إنه يفضل من الذاكرة المشتركة**: ما ينفعش ينام
     داخل حلقة الـpoll؛ الـdaemon بينشر قيمة الجهاز كل 80µs فيبقى التأخير ≤80µs
     والـguest بيسأل عن مساحة أقل مش أكتر (آمن).
2. **مسار اللوحة**: `apv-host --display` بيعمل:
   - يفتح واجهة XeGfxAccel الجديدة (selector 5) وياخد ملكية اللوحة (ACQUIRE)
   - يعمل Reims display على port 0 بمقاس/معدل اللوحة الحالية
   - يعمل Reims frame target بمقاس اللوحة + IOSurface بـBGRA بنفس الـpitch
   - كل ما الـguest يعرض فريم: encode → commit → wait → readback → نسخ للـIOSurface
     → PRESENT لـXeGfxAccel اللي بيعمل map للـIOSurface في GGTT ويبرمج PLANE_SURF
     وينتظر FRMCOUNT.
   - عند الخروج: RELEASE (بيرجّع سطح العرض الأصلي) وإرجاع الملكية.
3. **باتش XeGfxAccel** (مبني x86_64) + سكربت تركيب/رجوع آمن
   (`scripts/install-xegfx-accel.sh`) بيبدّل الـkext في `/Library/Extensions`
   ويعيد بناء auxiliary kernel collection بنفس طريقة حزمة E16-final، مع backup
   وrestore تلقائي عند الفشل. **من غيره** الاختبار بيكمل عادي، ومسار اللوحة
   بيسجّل إنه غير متاح ويكمّل.

## اللي في الحزمة

| المسار | إيه هو |
|---|---|
| `kext/ReimsPCIProbe.kext` | kext 0.3.0 x86_64 لـ25G241 (7 patches + أوضاع 1..11 القديمة) |
| `host/apv-host` | الـdaemon: جلسة Reims + الـkext + مسار اللوحة (`--display`) |
| `host/lib/libreims_vgpu.dylib` | Reims C API x86_64 من commit `1fe0acb68` |
| `xegfx/XeGfxAccel.kext` | الـkext المعدّل بواجهة اللوحة (selector 5) |
| `xegfx/xegfx-panel.patch` | التغييرات كـunified diff (للمراجعة/إعادة البناء) |
| `xegfx/PANEL-ABI.md` | عقد الواجهة: selector، structs، الأخطاء، lifetimes |
| `scripts/apv-up.sh` | الاختبار كامل بأمر واحد + تقرير على الـDesktop |
| `scripts/install-xegfx-accel.sh` | تركيب/إزالة باتش اللوحة بأمان |
| `scripts/install-efi.sh` | تركيب الـkext في EFI اختبار + مدخل OpenCore |
| `scripts/collect.sh` / `apv-down.sh` | جمع أدلة / إيقاف ورجوع |
| `tools/metal-registry`, `tools/verify-*` | أدوات الفحص والتحقق |
| `docs/` | تدقيق مواقع 25G241، تقرير Reims، تصميم مسار العرض، ABI، تحقق |
| `src/` | السورس الكامل (kext + host + XeGfx patched files + أدوات) |

## قبل الاختبار (مرة واحدة)

1. الـE16 على **EFI الاختبار**، macOS 26.7.1 `25G241`، والـEFI اليومي محفوظ كمسار رجوع.
2. ركّب الـkext: `bash scripts/install-efi.sh /Volumes/EFI` (أو `--edit`)، وأضف
   `reimspci=12` للـboot-args، واعمل reboot.
3. ركّب باتش اللوحة (اختياري لكنه مطلوب للعرض):
   `sudo bash scripts/install-xegfx-accel.sh /Volumes/1401/xegfx-e16/final` ثم restart.
4. بعد الدخول: `sudo bash /Volumes/1401/xegfx-e16/final/xe-up.sh` (زي اليومي).
5. شغّل الاختبار: `bash scripts/apv-up.sh` (مش sudo؛ من Terminal في جلسة المستخدم).

## علامات النتيجة

| العلامة | معناها |
|---|---|
| `kernel bridge stats: dispatch=.. patched=7 bar_bases=..` | الـpatch اشتغل على نص التعريف المحمّل |
| `map_memory[0..]: gpa 0x... -> 0x...` | صفحات Apple الفيزيائية اتحوّلت لعناوين في الـdaemon |
| `IRQ0 delivered to the kernel` | مقاطعة Reims وصلت لتعريف أبل |
| `panel: XeGfx pipe .. WxH pitch ..` | واجهة اللوحة الجديدة اتفتحت |
| `display: guest=.. host=.. sent=..` | فريمات الـguest اتعرضت على اللوحة |
| `apv-host exit status: 0` + مفيش `.panic` | الرن خلص من غير كارثة |

## الحدود (بصراحة كاملة)

1. **مفيش أي حاجة اتحققت على الـE16 بعد**. كل اللي اتبنى هنا اتبني واتحقق منه
   أوفلاين على الـAir (شوف `VERIFICATION.md`): الـstubs اتنفذت فعليًا تحت Rosetta،
   والـkext اتلينك ضد BootKernelExtensions.kc بتاع 25G241، والـdaemon اشتغل على
   Reims حقيقي على Metal بتاع الـAir، وXeGfxAccel اتبنى.
2. **مسار اللوحة مثبت على فرضيتين** لازم يتأكدوا على الجهاز:
   (أ) الـkext المعدّل يقدر يعمل lookup للـIOSurface بتاع الـdaemon في نفس الـtask
   ويـmap صفحاته في GGTT؛ (ب) Reims display port 0 هو فعلاً اللي الـguest بيربط
   عليه وبيعرض عليه، فالفريم اللي بنعمله encode هو سطح المكتب الحقيقي.
3. **الـteardown**: موقع تعطيل الـFIFO بقى patch متزامن، لكن السيناريو الكامل
   (daemon يقفل → Apple teardown) لسه محتاج تجربة على الجهاز.
4. **لو الـdaemon مات**: تعريف أبل هيستنى (dispatch يرجع صفر) — مش بانيك، لكن
   الأفضل reboot بعد كل تجربة.
5. لو ظهر panic أو وقفة: ارجع للـEFI اليومي، وشيل الـkext من EFI الاختبار
   (والـXeGfxAccel الأصلي يرجع بـ`install-xegfx-accel.sh --undo`)، وابعت تقرير
   `E16-APV-live-*.zip` من الـDesktop.

## الرجوع

```sh
bash scripts/apv-down.sh
sudo reboot
# لرجوع XeGfxAccel:
sudo bash scripts/install-xegfx-accel.sh --undo && sudo reboot
# لرجوع الـkext: شيل المدخل من EFI الاختبار أو ارجع للـEFI اليومي
```

---

## تحديث 0.3.2 — إصلاحات التشخيص بعد أول فريزين

- **إصلاح `apv-up.sh`**: كان بيفشل على bash 3.2 (اللي في macOS) عند `APV_DISPLAY=0`
  (`display[@]: unbound variable`) قبل ما يشغّل الـhost أصلًا.
- **الافتراضي بقى bridge-only**: `APV_DISPLAY=1` هو اللي بيشغّل مسار اللوحة، غير كده الـpanel بره المعادلة.
- **خيارين تشخيصيين جديدين في `apv-host`**:
  - `--no-publish`: يفتح الـbridge ويعمل map ويُنشئ Reims device **من غير ما يعمل arm**
    (تعريف أبل ما بيتطابقش خالص).
  - `--no-guest-writes`: يعمل arm لكن **ما يطبّقش** كتابات الـguest على جهاز Reims
    (يسجّلها بس)، لعزل مسار كتابة السجلات.
- **كل التحليل وخطة العزل في `docs/FREEZE-ANALYSIS.md`**: محاولتين فريز كامل، الأولى 0.3.0
  بكامل الـpatch والـdisplay، والتانية 0.3.1 بـ`apvpatch=0` (بدون patch) — يعني الـpatch
  مش هو السبب. الخطوة القادمة: المرحلة A0 ثم A1 ثم B ثم C.
- مهم: بعد أي فريز **اللوجات بتضيع** مع الهارد ريسِت؛ لازم تسيب نافذة
  `sudo log stream --style compact --predicate 'process == "kernel"'` مفتوحة وصوّرها.
