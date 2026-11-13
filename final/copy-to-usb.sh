#!/bin/bash
# E16 final 1.0 - on the Mac, with the USB stick "1401" in:   bash ~/Desktop/E16-final/copy-to-usb.sh
# Puts the final EFI on the stick (the stick's current EFI is saved on the Mac first) and the driver package in
# /Volumes/1401/xegfx-e16/final. Every copied file is compared after the copy.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); V=/Volumes/1401
[ -d "$V/EFI/OC" ] || { echo "STOP: the stick is not mounted at $V"; exit 1; }
BK=$HOME/Desktop/EFI-backup-$(date +%Y%m%d-%H%M%S); ditto "$V/EFI" "$BK"; echo "old EFI saved to $BK"
rsync -rt --delete --exclude '._*' --exclude .DS_Store "$HERE/EFI/" "$V/EFI/"
mkdir -p "$V/xegfx-e16/final"; rsync -rt --delete --exclude '._*' --exclude .DS_Store "$HERE/xegfx-e16/final/" "$V/xegfx-e16/final/"
dot_clean "$V" 2>/dev/null || true; sync
bad=0
while IFS= read -r f; do cmp -s "$HERE/$f" "$V/$f" || { echo "MISMATCH $f"; bad=1; }; done < <(cd "$HERE" && find EFI xegfx-e16 -type f ! -name '._*' ! -name .DS_Store)
[ $bad = 0 ] || { echo "STOP: copy differs - run this again"; exit 1; }
plutil -lint "$V/EFI/OC/config.plist"
echo "DONE. On the laptop: boot from the stick, then  sudo bash /Volumes/1401/xegfx-e16/final/install.sh"
