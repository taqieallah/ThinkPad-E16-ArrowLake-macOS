#!/bin/bash
# sudo bash arm-pipetest.sh : installs the current bootcap and arms the one-shot pipe test for the NEXT boot with the
# driver (nullmoth-fbflags 1321, i.e. without 0x200). Results: /Users/Shared/meowarl-boot/<time>/pipetest*.txt
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
H=$(cd "$(dirname "$0")" && pwd)
bash "$H/install-bootcap.sh" || exit 1
mkdir -p /Users/Shared/meowarl-boot && touch /Users/Shared/meowarl-boot/PIPETEST
echo "armed: restart, choose macOS (with the driver), wait 2 minutes even if the screen is black, then restart again"
