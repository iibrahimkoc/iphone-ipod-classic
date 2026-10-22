#!/bin/sh
# Builds an unsigned iPhone build, fake-signs it with ldid and packages it as a
# rootless .deb that installs to /var/jb/Applications (no 7-day signing expiry).
set -e
cd "$(dirname "$0")"

xcodegen generate --quiet
xcodebuild -project ClickWheel.xcodeproj -scheme ClickWheel -sdk iphoneos \
    -destination generic/platform=iOS -configuration Release -derivedDataPath build \
    CODE_SIGNING_ALLOWED=NO -quiet

APP=build/Build/Products/Release-iphoneos/ClickWheel.app
ldid -S"$PWD/entitlements.plist" "$APP/ClickWheel"

PKG=build/deb
rm -rf "$PKG"
mkdir -p "$PKG/DEBIAN" "$PKG/var/jb/Applications"
cp -R "$APP" "$PKG/var/jb/Applications/"
cat > "$PKG/DEBIAN/control" <<EOF
Package: com.ibrahimkoc.clickwheel
Name: iPod
Version: 1.16
Architecture: iphoneos-arm64
Description: iPod Classic style click-wheel music player
Maintainer: ibrahimkoc
Author: ibrahimkoc
Section: Multimedia
EOF
cat > "$PKG/DEBIAN/postinst" <<'EOF'
#!/bin/sh
uicache -p /var/jb/Applications/ClickWheel.app
EOF
chmod 755 "$PKG/DEBIAN/postinst"

dpkg-deb -Zgzip --root-owner-group -b "$PKG" build/clickwheel.deb >/dev/null
echo "build/clickwheel.deb"
