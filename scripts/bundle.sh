#!/bin/sh
# Builds build/HiResBuddy.app (release): the menu bar app, its transport helper and — when driver/build.sh has
# been run — the driver with its installer for the app's «Установить драйвер…».
set -eu
cd "$(dirname "$0")/.."

swift build -c release
bin=$(swift build -c release --show-bin-path)
app=build/HiResBuddy.app

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/HiResBuddy" "$app/Contents/MacOS/HiResBuddy"
cp "$bin/hiresbuddy-transport" "$app/Contents/MacOS/hiresbuddy-transport"   # the session looks for it next to the app
cp Sources/HiResBuddy/Resources/Info.plist "$app/Contents/Info.plist"
printf 'APPL????' > "$app/Contents/PkgInfo"

if [ -d driver/build/HiResBuddy.driver ]; then
    mkdir -p "$app/Contents/Resources/driver/build"
    cp driver/install.sh driver/uninstall.sh "$app/Contents/Resources/driver/"
    cp -R driver/build/HiResBuddy.driver "$app/Contents/Resources/driver/build/"
else
    echo "note: no driver/build/HiResBuddy.driver (run driver/build.sh): the bundle ships without the driver" >&2
fi

codesign --force --sign - --deep "$app"
echo "built $app"
