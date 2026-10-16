#!/bin/sh
# Installs the built driver into the HAL plug-ins folder and restarts coreaudiod. Run as root.
# Root cannot read ~/Downloads, ~/Desktop or ~/Documents (TCC): if the checkout lives there, copy this script and
# build/ elsewhere (e.g. /tmp) and run that copy.
set -eu
cd "$(dirname "$0")"
[ -d build/HiResBuddy.driver ] || { echo "run driver/build.sh first" >&2; exit 1; }
rm -rf /Library/Audio/Plug-Ins/HAL/HiResBuddy.driver
cp -R build/HiResBuddy.driver /Library/Audio/Plug-Ins/HAL/HiResBuddy.driver
chown -R root:wheel /Library/Audio/Plug-Ins/HAL/HiResBuddy.driver
killall -9 coreaudiod
echo "installed /Library/Audio/Plug-Ins/HAL/HiResBuddy.driver"
