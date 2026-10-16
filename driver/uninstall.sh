#!/bin/sh
# Removes the driver and restarts coreaudiod. Run as root.
set -eu
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
rm -rf /Library/Audio/Plug-Ins/HAL/HiResBuddy.driver
killall -9 coreaudiod || true   # launchd restarts it; absent is fine
echo "removed /Library/Audio/Plug-Ins/HAL/HiResBuddy.driver"
