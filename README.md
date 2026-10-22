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
