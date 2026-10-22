#!/bin/sh
# Builds an unsigned iPhone build, fake-signs it with ldid and packages it as a
# rootless .deb that installs to /var/jb/Applications (no 7-day signing expiry).
set -e
cd "$(dirname "$0")"

# Genesis Plus GX for Oyunlar › Mega Drive: a static libretro core the app links (see project.yml).
GPGX=build/genesis
if [ ! -f build/lib/libgenesis.a ]; then
    [ -d "$GPGX" ] || git clone -q --depth 1 https://github.com/libretro/Genesis-Plus-GX.git "$GPGX"
    # The regular (dylib) build, since STATIC_LINKING leaves out the libretro-common file and
    # path helpers it expects a frontend to have; its objects are then archived for linking.
    make -C "$GPGX" -f Makefile.libretro -j"$(sysctl -n hw.ncpu)" platform=ios-arm64 \
        IOSSDK="$(xcrun -sdk iphoneos --show-sdk-path)" >/dev/null
    mkdir -p build/lib
    find "$GPGX" -name '*.o' -print0 | xargs -0 ar rcs build/lib/libgenesis.a
fi

xcodegen generate --quiet
xcodebuild -project ClickWheel.xcodeproj -scheme ClickWheel -sdk iphoneos \
    -destination generic/platform=iOS -configuration Release -derivedDataPath build \
    CODE_SIGNING_ALLOWED=NO -quiet

APP=build/Build/Products/Release-iphoneos/ClickWheel.app
ldid -S"$PWD/entitlements.plist" "$APP/ClickWheel"

# Stockfish for Oyunlar › Satranç: built once for iOS from the release tag (the network is
# embedded, ~100 MB) and bundled next to the app's executable. It needs its own entitlements,
# or iOS kills it at launch.
SF=build/stockfish
if [ ! -x "$SF/src/stockfish" ]; then
    [ -d "$SF" ] || git clone -q --depth 1 --branch sf_19 https://github.com/official-stockfish/Stockfish.git "$SF"
    make -C "$SF/src" -j"$(sysctl -n hw.ncpu)" build ARCH=armv8 COMP=clang CXX="xcrun -sdk iphoneos clang++" \
        mac_target_flags="-target arm64-apple-ios15.0" >/dev/null
fi
cp "$SF/src/stockfish" "$APP/stockfish"
strip "$APP/stockfish"
ldid -S"$PWD/stockfish.entitlements" "$APP/stockfish"

PKG=build/deb
rm -rf "$PKG"
mkdir -p "$PKG/DEBIAN" "$PKG/var/jb/Applications"
cp -R "$APP" "$PKG/var/jb/Applications/"
cat > "$PKG/DEBIAN/control" <<EOF
Package: com.ibrahimkoc.clickwheel
Name: iPod
Version: 2.10.1
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
