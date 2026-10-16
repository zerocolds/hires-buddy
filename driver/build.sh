#!/bin/sh
# Builds the "HiRes Buddy" virtual audio device (BlackHole fork) into driver/build/HiResBuddy.driver.
set -eu
cd "$(dirname "$0")"

driverName="HiResBuddy"
bundleID="dev.hiresbuddy.driver"

[ -f BlackHole/BlackHole.xcodeproj/project.pbxproj ] || git submodule update --init BlackHole

# xcodebuild splits GCC_PREPROCESSOR_DEFINITIONS on unescaped spaces, hence "HiRes\ Buddy".
# All four rates stay (stage 2 streams 44.1–96 kHz): the app pins the rate it streams at and AudioCapture's
# nominal-rate listener forces it back if anything changes it mid-stream.
xcodebuild -project BlackHole/BlackHole.xcodeproj -scheme BlackHole -configuration Release -derivedDataPath DerivedData \
    CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO \
    PRODUCT_BUNDLE_IDENTIFIER="$bundleID" \
    GCC_PREPROCESSOR_DEFINITIONS='$GCC_PREPROCESSOR_DEFINITIONS kDriver_Name=\"'"$driverName"'\" kPlugIn_BundleID=\"'"$bundleID"'\" kHas_Driver_Name_Format=false kDevice_Name=\"HiRes\ Buddy\" kDevice2_IsHidden=true kNumber_Of_Channels=2 kSampleRates=44100,48000,88200,96000' \
    build

built=$(find DerivedData/Build/Products/Release -maxdepth 1 -name '*.driver' | head -n 1)
[ -n "$built" ] || { echo "no .driver in DerivedData/Build/Products/Release" >&2; exit 1; }
rm -rf build/HiResBuddy.driver
mkdir -p build
cp -R "$built" build/HiResBuddy.driver
echo "built driver/build/HiResBuddy.driver"
