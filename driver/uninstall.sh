#!/bin/sh
# Removes the driver and restarts coreaudiod. Run as root.
set -eu
rm -rf /Library/Audio/Plug-Ins/HAL/HiResBuddy.driver
killall -9 coreaudiod
echo "removed /Library/Audio/Plug-Ins/HAL/HiResBuddy.driver"
