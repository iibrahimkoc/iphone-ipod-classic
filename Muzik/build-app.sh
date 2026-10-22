#!/bin/sh
# Builds the iPod Müzik Mac app into ~/Applications. The app runs this folder's muzik.sh.
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR/App"
xcodegen generate --quiet
xcodebuild -project iPodMuzik.xcodeproj -scheme iPodMuzik -configuration Release \
    -destination "generic/platform=macOS" -derivedDataPath build CODE_SIGNING_ALLOWED=NO -quiet
APP="$HOME/Applications/iPod Müzik.app"
mkdir -p "$HOME/Applications"
rm -rf "$APP"
cp -R build/Build/Products/Release/iPodMuzik.app "$APP"
plutil -insert MuzikFolder -string "$DIR" "$APP/Contents/Info.plist"
# The executable has an ASCII name: codesign fails on the non-ASCII "ü".
codesign -f -s - "$APP"
echo "$APP"
