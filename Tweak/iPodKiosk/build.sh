#!/bin/sh
# Builds the kiosk tweak as a rootless .deb that ElleKit injects into SpringBoard.
set -e
cd "$(dirname "$0")"

xcrun -sdk iphoneos clang -arch arm64 -miphoneos-version-min=15.0 -fobjc-arc -dynamiclib \
    -framework Foundation -framework UIKit -framework AudioToolbox -o iPodKiosk.dylib Tweak.m
ldid -S iPodKiosk.dylib

PKG=build/deb
DIR="$PKG/var/jb/usr/lib/TweakInject"
rm -rf "$PKG"
mkdir -p "$PKG/DEBIAN" "$DIR"
cp iPodKiosk.dylib "$DIR/"
echo '{ Filter = { Bundles = ( "com.apple.springboard" ); }; }' > "$DIR/iPodKiosk.plist"
cat > "$PKG/DEBIAN/control" <<CONTROL
Package: com.ibrahimkoc.ipodkiosk
Name: iPodKiosk
Version: 1.9
Architecture: iphoneos-arm64
Description: Keeps the iPod click-wheel app in front
Maintainer: ibrahimkoc
Author: ibrahimkoc
Section: Tweaks
Depends: ellekit, com.ibrahimkoc.clickwheel
CONTROL

dpkg-deb -Zgzip --root-owner-group -b "$PKG" build/ipodkiosk.deb >/dev/null
echo "build/ipodkiosk.deb"
