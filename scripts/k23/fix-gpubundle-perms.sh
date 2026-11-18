#!/bin/bash
# sudo bash /Volumes/1401/xegfx-e16/MeowARL/fix-gpubundle-perms.sh
# The installer ran from a copy of the FAT stick, where every file is rwx------ ; so /Library/GPUBundles was installed
# readable by root only, and WindowServer (user _windowserver) logged "Cannot find executable for CFBundle
# NVMTLDriver.bundle" and CoreDisplay asserted. This gives the bundles normal modes: folders 755, Mach-O 755, rest 644.
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
for G in /Library/GPUBundles /Library/NullMoth; do
  [ -d "$G" ] || continue
  chown -R root:wheel "$G"
  find "$G" -type d -exec chmod 755 {} +
  find "$G" -type f -exec chmod 644 {} +
  find "$G" -type f -exec sh -c 'file -b "$1" | grep -q Mach-O && chmod 755 "$1"' _ {} \;
done
ls -l /Library/GPUBundles/NVMTLDriver.bundle/Contents/MacOS/NVMTLDriver
sudo -u _windowserver test -r /Library/GPUBundles/NVMTLDriver.bundle/Contents/MacOS/NVMTLDriver && echo "OK: WindowServer can read the Metal plug-in" || echo "STILL NOT READABLE"
codesign -v /Library/GPUBundles/NVMTLDriver.bundle 2>&1 && echo "signature OK"
echo "now restart and boot with the driver"
