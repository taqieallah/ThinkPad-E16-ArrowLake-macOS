#!/bin/bash
# Stop the live bridge daemon and show how to return to the normal system.
set -u
echo "== stopping apv-host =="
pkill -TERM -f 'apv-host' 2>/dev/null && echo "apv-host terminated" || echo "apv-host was not running"
sleep 1
pkill -KILL -f 'apv-host' 2>/dev/null || true
echo
echo "The kernel bridge is inert after the daemon exits: the kext answers no"
echo "MMIO and delivers no IRQ, and Apple's driver will stall (it is a test"
echo "build), so reboot before resuming normal work:"
echo
echo "  sudo reboot"
echo
echo "To boot without the bridge at all, either remove reimspci=12 from the"
echo "boot arguments or remove the ReimsPCIProbe kext from the test EFI and"
echo "boot the known-good EFI."
