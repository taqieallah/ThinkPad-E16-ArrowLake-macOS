MeowARL (E16 k23) - MeowXE3 على كارت Arrow Lake بتاع الـ ThinkPad E16
=================================================================

ده إيه: MeowXE3 (cuadra8998) معمول لكروت Intel Xe3، وبيقول إن الديسكتوب بيترسم على الكارت والأنيميشن سلس.
التعريف بتاعه هو NMXGPU بتاع NullMoth، وده تعريف xe بتاع لينكس 6.14 شغال جوه كيرنل macOS.
تعريف xe في لينكس 6.14 بيعرف كارتك (7D51) أصلًا، بس لازم يتجبر عليه (force probe).
فإحنا بنبني تعريفهم تاني من نفس الكود، وبنعمل فيه حاجتين:
  - بنضيف 7D51 لـ xe.
  - بنشيله من i915، عشان التعريفين ميمسكوش نفس الكارت.
وبعدين بنحطه في حزمة MeowXE3 الرسمية، ومعاه firmware بتاع Meteor Lake (هو اللي بيستخدمه Arrow Lake).
ده أول تشغيل على Arrow Lake، فممكن ميشتغلش من أول مرة.

=== 1) على الماك M5: البناء ===
   git clone https://github.com/taqieallah/ThinkPad-E16-ArrowLake-macOS ~/src/xe-e16/e16-repo
      (لو موجود عندك:  git -C ~/src/xe-e16/e16-repo pull)
   bash ~/src/xe-e16/e16-repo/scripts/k23/build-k23.sh
   - أول مرة بياخد من 30 لـ 90 دقيقة، ومحتاج نت. بينزّل الكود من NullMoth ولينكس وFreeBSD وMesa.
   - لو التنزيل فشل: نزّل MeowXE3-1.0.12.zip من صفحة Releases على GitHub بتاع MeowXE3، وحطه في Downloads،
     وبعدين شغّل السكريبت تاني.
   - لو طلع "compile failures": ابعتلي الملف ~/nmx/build/gpu-src/xkpi/k23-build.log
   - النتيجة: مجلد ~/Desktop/MeowARL، والسكريبت بينسخه للفلاشة في xegfx-e16/MeowARL ويتأكد من النسخ.

=== 2) على اللابتوب: macOS من الأول ===
   - نزّل macOS Tahoe 26 بالـ EFI اللي عندك وكمّل الإعداد عادي. ما تركّبش XeGfx ولا LegionCpuPower.
   - في الـ EFI بتاعك (config.plist) لازم يبقى فيه الحاجات دي. الـ installer هيقولك لو حاجة ناقصة:
       SIP: csr-active-config = 030A0000 (عشان الـ kexts اللي مش موقّعة من أبل)
       AMFI: boot-args فيها  amfi_get_out_of_my_way=0x1 amfi=0x80 ipc_control_port_options=0
       SecureBootModel = Disabled

=== 3) على اللابتوب: التركيب ===
   cp -R /Volumes/1401/xegfx-e16/MeowARL ~/Desktop/
   sudo bash ~/Desktop/MeowARL/"Install MeowXE3.command" --dry-run     (بيفحص بس، ومبيغيّرش حاجة)
   sudo bash ~/Desktop/MeowARL/"Install MeowXE3.command"               ثم اختار [1]
   - هيقولك "Arrow Lake H - MeowARL, first runs". ده تحذير عادي، كمّل.
   - قبل ما يعدّل config.plist هيسألك، وبيعمل نسخة احتياطية من EFI في ~/MeowXE3-EFI-backup-<date>.
     التعديلات اللي بيعملها:
       - بيضيف nmxintel=1 (ده اللي بيشغّل التعريف).
       - بيضيف nullmoth-fbflags=1833.
       - بيضيف MeowXE3Boot.kext.
       - بيضيف خيار طوارئ في قايمة البوت اسمه "MeowXE3: start once without driver".
   - لو طلب، اعمل Approve في System Settings > Privacy & Security، وبعدين ريستارت.

=== 4) أول بوت ===
   - لو الشاشة سودا أو الجهاز وقف:
       1. اعمل ريستارت.
       2. من قايمة OpenCore اختار "MeowXE3: start once without driver"، وبعدها macOS.
       3. بعد ما يفتح:  sudo bash ~/Desktop/MeowARL/k23-collect.sh prev
   - لو فتح: شغّل  sudo bash ~/Desktop/MeowARL/k23-collect.sh
     وجرّب تصغّر وتكبّر الشبابيك وتفتح Mission Control. هل الحركة سلسة؟
   - ابعتلي مجلد xegfx-e16/logs/meowarl-* من الفلاشة.

=== الرجوع ===
   - الـ installer > [4] uninstall، أو امسح nmxintel=1 من boot-args.
   - نسختك القديمة من EFI في ~/MeowXE3-EFI-backup-<date>/EFI
