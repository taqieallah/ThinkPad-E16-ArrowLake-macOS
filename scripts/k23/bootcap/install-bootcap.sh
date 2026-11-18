#!/bin/bash
# sudo bash install-bootcap.sh : installs the boot-time capture (read-only diagnostics, runs only when nmxintel=1)
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
H=$(cd "$(dirname "$0")" && pwd); A="/Library/Application Support/MeowARL"
mkdir -p "$A" && cp "$H/meowarl-bootcap.sh" "$A/" && chmod 755 "$A/meowarl-bootcap.sh"
cp "$H/com.e16.meowarl.bootcap.plist" /Library/LaunchDaemons/ && chown root:wheel /Library/LaunchDaemons/com.e16.meowarl.bootcap.plist \
  && chmod 644 /Library/LaunchDaemons/com.e16.meowarl.bootcap.plist
xattr -c "$A/meowarl-bootcap.sh" /Library/LaunchDaemons/com.e16.meowarl.bootcap.plist 2>/dev/null
plutil -lint /Library/LaunchDaemons/com.e16.meowarl.bootcap.plist && echo "installed: it runs at the next boots with the driver; results in /Users/Shared/meowarl-boot"
