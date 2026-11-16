E16 k22 - سرعة كارت الشاشة وقت الأنيميشن + قياس البروسيسور
==========================================================

الفكرة: الـ GPU بيفضل على أقل سرعة (SLPC) وهو بيرسم الديسكتوب، فالفريمات بتتأخر والأنيميشن بيقطّع.
k22 بيرفع أقل سرعة للكارت للحد الأقصى أول ما فريم يتأخر 3 ms، ويرجّعها بعد 150 ms من آخر فريم متأخر.
(الفكرة من ArrowWhatever 0035/0036 - Mountainatic - مكتوبة من جديد لتعريفنا)

1) اختبار سريع من غير أي بناء (على التعريف اللي عندك دلوقتي):
   sudo bash /Volumes/1401/xegfx-e16/k22/k22-measure.sh
   - جولتين 20 ثانية: A عادي، و B الكارت على أقصى سرعة طول الوقت.
   - في الجولتين: صغّر وكبّر شباك (Genie) أو افتح Mission Control بنفس الطريقة.
   - لو B أنعم بوضوح = ده سبب التقطيع، و k22 هو الحل.

2) البناء على الماك:   bash k22/build-k22.sh
   (بياخد الكود من الريبو، ويبني XeGfx + XeGfxAccel، ويحط الحزمة في ~/Desktop/k22 وعلى الفلاشة xegfx-e16/k22)

3) على اللابتوب:
   sudo bash /Volumes/1401/xegfx-e16/k22/install.sh        (الرجوع: ... install.sh --undo)
   ريستارت، وبعدين:
   sudo bash /Volumes/1401/xegfx-e16/k22/xe-up.sh --fast   (الـ boost بيشتغل في وضع --fast بس)
   sudo bash /Volumes/1401/xegfx-e16/k22/k22-measure.sh    (A = k22 مقفول، B = شغال)

   مفاتيح:  sysctl debug.nvaccel_xe_boost_us=0     يقفله فورًا (3000 = شغال)
            sysctl debug.nvaccel_xe_late debug.nvaccel_xe_boosts debug.nvaccel_xe_boost_on debug.xegfx_gt_freq

4) قياس البروسيسور (لـ HybridPM، مبيغيّرش أي حاجة، 40 ثانية):
   sudo bash /Volumes/1401/xegfx-e16/k22/cpu-measure.sh
   اقفل البرامج الأول. النتيجة في xegfx-e16/logs/cpu-measure-*.txt

ابعت ملفات logs/k22-measure-*.txt و logs/cpu-measure-*.txt
