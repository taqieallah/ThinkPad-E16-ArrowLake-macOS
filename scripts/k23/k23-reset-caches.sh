#!/bin/bash
# In a "MeowXE3: start once without driver" boot:   sudo bash /Volumes/1401/xegfx-e16/MeowARL/k23-reset-caches.sh
# The freezes began with the first hard power-off (the aerial wallpaper). A power-off while NVMTL writes its shader
# caches (aircache / spvcache / library index, per process under /var/folders/.../C/<app>/nvmtl and ~/Library/Caches)
# can leave a half-written entry that every later boot loads again. This moves every nvmtl cache folder to the Desktop
# (nothing is deleted; they rebuild on their own, the first boot is slow again) and takes out the bootcap job too.
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
U=${SUDO_USER:-$(stat -f %Su /dev/console)}; H=$(dscl . -read /Users/"$U" NFSHomeDirectory | awk '{print $2}')
T="$H/Desktop/nvmtl-caches-$(date +%m%d-%H%M%S)"; mkdir -p "$T"
n=0
while IFS= read -r d; do
  n=$((n+1)); du -sh "$d" 2>/dev/null | awk -v i=$n '{print i": "$1"  "$2}'
  mv "$d" "$T/$n-$(echo "$d" | tr '/' '_' | tail -c 120)" || echo "  could not move $d"
done < <(find /private/var/folders "$H/Library/Caches" /Library/Caches -type d -name nvmtl -prune 2>/dev/null)
echo "moved $n nvmtl cache folder(s) to $T"
chown -R "$U" "$T"
if [ -f /Library/LaunchDaemons/com.e16.meowarl.bootcap.plist ]; then
  launchctl bootout system/com.e16.meowarl.bootcap 2>/dev/null
  rm -f /Library/LaunchDaemons/com.e16.meowarl.bootcap.plist; rm -rf "/Library/Application Support/MeowARL"; echo "bootcap removed"
else echo "bootcap was not installed"; fi
echo "now boot WITH the driver; the first login is slow again (shaders rebuild) - wait, do not power off for 5 minutes"
