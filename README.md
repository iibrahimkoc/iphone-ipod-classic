# iPhone 6s → iPod Classic

Turns a jailbroken iPhone 6s (iOS 15.8.8, palera1n rootless) into an iPod Classic–style music player.

- `ClickWheel/` — SwiftUI app: iPod menus, touch click wheel, Now Playing, in-app Wi-Fi and Bluetooth settings,
  screen swipes for brightness/volume. Uses private MobileWiFi / BluetoothManager APIs via the jailbreak's entitlements.
- `Daemons/` — list of iOS services not needed on an iPod (Siri, Spotlight, Mail, Health, analytics, …) with
  `disable.sh` and the undo script `enable.sh`. The disable is persistent, even without the jailbreak.
- `Tweak/iPodKiosk/` — SpringBoard tweak (ElleKit) that keeps the app in front, redirects the home button to it and
  disables Control Center / Notification Center. Five quick home presses temporarily escape to the normal home screen.

## Build & install

Requires Xcode, and `brew install xcodegen ldid dpkg libimobiledevice`.

```sh
ClickWheel/build.sh            # → ClickWheel/build/clickwheel.deb
Tweak/iPodKiosk/build.sh       # → Tweak/iPodKiosk/build/ipodkiosk.deb

iproxy 2222:22 &               # SSH over USB; ~/.ssh/config: Host ipod → localhost:2222, user mobile
scp ClickWheel/build/clickwheel.deb ipod:/var/mobile/
ssh ipod sudo dpkg -i /var/mobile/clickwheel.deb
```

Both packages install under `/var/jb`, so they only run while the phone is jailbroken.

## Adding music

**Over Wi-Fi (preferred):** the phone app plays its own folder `/var/mobile/Media/iPodMuzik` alongside the
Finder-synced library, and announces itself over Bonjour (`_ipodmuzik._tcp`). The iPod Müzik Mac app finds
it on the same network, tags the dropped MP3s and copies them in over SSH ("iPod'a Gönder"); new songs show
up on the iPod within seconds.

**Via Finder sync:**

`Muzik/muzik.sh` tags MP3s converted from YouTube (title, artist, album, year, genre, cover from the
iTunes Search API, whichever order the file name uses) and adds them to the Music app; then sync the
iPhone from Finder. `--deneme` previews, `--evet` skips the questions. With no arguments it scans ~/Downloads and moves
processed files to `~/Downloads/iPod-eklendi/`.

`Muzik/build-app.sh` builds the **iPod Müzik** Mac app (`Muzik/App`, SwiftUI) into ~/Applications: drag MP3s
into its window, check the found title/artist/album/cover, drop more, then press **Yükle**. It drives
`muzik.sh --json` / `--uygula`.

## After a reboot

The jailbreak is semi-tethered: after a restart the phone boots stock iOS. Plug it in and run `./kurtar.sh`.
It guides DFU entry with a countdown, runs `palera1n -l` (killing stale runs and retrying the known
"Booting PongoOS…" hang), waits for iOS, and checks that the app, the tweak and SSH are back.

## Games

**Oyunlar › Satranç** plays against Stockfish 19 (GPL-3.0, github.com/official-stockfish/Stockfish). `build.sh`
builds it for iOS on the first run and bundles it as a separate executable that the app drives over UCI.

**Oyunlar › Mega Drive** and **Oyunlar › Doom** run games through libretro cores that `build.sh` builds for iOS
and bundles in the app's `cores` folder, opened with dlopen: Genesis Plus GX (non-commercial license,
github.com/libretro/Genesis-Plus-GX) for Mega Drive / Master System / Game Gear ROMs in
`/var/mobile/Media/iPodOyun/MegaDrive`, and PrBoom (GPL, github.com/libretro/libretro-prboom) for the WADs in
`/var/mobile/Media/iPodOyun/Doom` (the Doom shareware episode, Freedoom Phase 1 and 2, plus PrBoom's own
`prboom.wad`). While a game runs the wheel is the D-pad and the center the main button; a tap on the screen's left
or right half presses that side's button, and a long press leaves, saving the game's place.

**Oyunlar › Java** runs MIDP phone games (`.jar`, in `/var/mobile/Media/iPodOyun/Java`) on the repository's own
libretro core in `ClickWheel/J2ME`: a small Java bytecode interpreter with green threads and a mark-and-sweep
collector, plus the CLDC/MIDP classes these games call (lcdui on CoreGraphics/CoreText, RecordStore saves in a
hidden folder next to the game, Samsung's AudioClip and MMAPI MIDI through a tiny synthesizer). It is written for
and tested with Forgotten Warrior (240×320). The wheel is the phone's D-pad (up-left/up-right are the 1 and 3 keys),
the center is fire, the screen's halves are the soft keys, and that game's potions and MP bar can be tapped.
`J2ME/test.c` runs a game on the Mac with scripted buttons and writes screenshots, for working on the core.
There are no save states: a game's own saves (its Continue) are what carry over.

**Oyunlar › Flash** plays Flash games (`.swf`, in `/var/mobile/Media/iPodOyun/Flash`) with
[Ruffle](https://github.com/ruffle-rs/ruffle)'s web build, which `build.sh` bundles into the app, in a web view
(`Sources/Flash.swift`). The page, Ruffle and the game come from an `ipod-flash:` URL scheme the app serves. It uses
Ruffle's own WebGL renderer (wgpu over WebGL draws nothing in iOS 15's web view) at high quality. The wheel sends
arrow keys and the center the space bar; Ruffle only takes keys after a focusin, so one is sent before each. The
screen is the mouse, and a long press leaves. Ruffle's messages go to `iPodOyun/Flash/.flash.log`.
Tested with Domuzcuk (Mr. Don).
