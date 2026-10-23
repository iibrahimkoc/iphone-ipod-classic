#!/bin/sh
# Builds an unsigned iPhone build, fake-signs it with ldid and packages it as a
# rootless .deb that installs to /var/jb/Applications (no 7-day signing expiry).
set -e
cd "$(dirname "$0")"

# libretro cores for Oyunlar, built once for iOS: Genesis Plus GX (Mega Drive), PrBoom (Doom) and
# FCEUmm (NES), plus J2ME (Java phone games) below.
# They are bundled in the app's cores folder and opened with dlopen; both export the same retro_*
# functions, so they can't be linked in. The Genesis checkout also provides libretro.h.
IOSSDK="$(xcrun -sdk iphoneos --show-sdk-path)"
GPGX=build/genesis/genesis_plus_gx_libretro_ios.dylib
if [ ! -f "$GPGX" ]; then
    [ -d build/genesis ] || git clone -q --depth 1 https://github.com/libretro/Genesis-Plus-GX.git build/genesis
    make -C build/genesis -f Makefile.libretro -j"$(sysctl -n hw.ncpu)" platform=ios-arm64 IOSSDK="$IOSSDK" >/dev/null
fi
PRBOOM=build/prboom/prboom_libretro_ios.dylib
if [ ! -f "$PRBOOM" ]; then
    [ -d build/prboom ] || git clone -q --depth 1 https://github.com/libretro/libretro-prboom.git build/prboom
    make -C build/prboom -j"$(sysctl -n hw.ncpu)" platform=ios-arm64 IOSSDK="$IOSSDK" >/dev/null
fi
FCEUMM=build/fceumm/fceumm_libretro_ios.dylib
if [ ! -f "$FCEUMM" ]; then
    [ -d build/fceumm ] || git clone -q --depth 1 https://github.com/libretro/libretro-fceumm.git build/fceumm
    make -C build/fceumm -f Makefile.libretro -j"$(sysctl -n hw.ncpu)" platform=ios-arm64 IOSSDK="$IOSSDK" >/dev/null
fi
# The J2ME core for Java phone games is this repository's own (J2ME/), rebuilt every time.
J2ME=build/j2me/j2me_libretro_ios.dylib
mkdir -p build/j2me
xcrun -sdk iphoneos clang -target arm64-apple-ios15.0 -O2 -dynamiclib -I build/genesis/libretro/libretro-common/include \
    J2ME/vm.c J2ME/lib.c J2ME/midp.c J2ME/midi.c J2ME/jar.c J2ME/libretro.c \
    -lz -framework CoreFoundation -framework CoreGraphics -framework CoreText -framework ImageIO -o "$J2ME"

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

mkdir -p "$APP/cores"
for CORE in "$GPGX" "$PRBOOM" "$FCEUMM" "$J2ME"; do
    cp "$CORE" "$APP/cores/"
    ldid -S "$APP/cores/$(basename "$CORE")"
done

# Ruffle's web build for Oyunlar › Flash (FlashGame serves it to its web view): a nightly from
# before the build, fetched once, without the source maps.
RUFFLE=build/ruffle
if [ ! -f "$RUFFLE/ruffle.js" ]; then
    mkdir -p "$RUFFLE"
    gh release download nightly-2026-09-30 -R ruffle-rs/ruffle -p '*web-selfhosted.zip' -D "$RUFFLE" --clobber
    unzip -oq "$RUFFLE"/*.zip -d "$RUFFLE"
fi
mkdir -p "$APP/ruffle"
cp "$RUFFLE"/*.js "$RUFFLE"/*.wasm "$APP/ruffle/"

PKG=build/deb
rm -rf "$PKG"
mkdir -p "$PKG/DEBIAN" "$PKG/var/jb/Applications"
cp -R "$APP" "$PKG/var/jb/Applications/"
cat > "$PKG/DEBIAN/control" <<EOF
Package: com.ibrahimkoc.clickwheel
Name: iPod
Version: 2.22
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
