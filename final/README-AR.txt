E16 final 1.0  (ThinkPad E16, Core Ultra 7 255H, macOS 26.7.1)

على الماك (الفلاشة متوصلة):
  bash ~/Desktop/E16-final/copy-to-usb.sh

على اللابتوب (مرة واحدة):
  1) اقلع من الفلاشة
  2) sudo bash /Volumes/1401/xegfx-e16/final/install.sh
  3) ريستارت، واستنى دقيقتين على الديسكتوب

كل مرة بعد الدخول:
  sudo bash /Volumes/1401/xegfx-e16/final/xe-up.sh          (الوضع الآمن - الافتراضي)
  sudo bash /Volumes/1401/xegfx-e16/final/xe-up.sh --fast   (أسرع، للتجربة فقط)

الرجوع:
  التعريف:  sudo bash /Volumes/1401/xegfx-e16/final/install.sh --undo
  الـ EFI:   النسخة القديمة محفوظة على الماك في Desktop/EFI-backup-*

لو حصل فريز: استنى 3 دقايق قبل الريستارت. xe-up بيحفظ لوحده آخر لوج من الإقلاع اللي فات في
  /Volumes/1401/xegfx-e16/logs/prevboot-*.txt
