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
