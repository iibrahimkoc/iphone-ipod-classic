#!/bin/bash
# Brings the iPod back after the phone restarted and lost the jailbreak:
# guides DFU entry, runs palera1n (retrying the PongoOS hang), then checks that
# the app, the kiosk tweak and SSH are working again.
#
# Usage: ./kurtar.sh   (phone connected over USB, normally booted)
set -u

PALERA1N_LOG=/tmp/kurtar-palera1n.log
PONGO_TIMEOUT=40

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
fail() { printf '\n\033[31m✗ %s\033[0m\n' "$*"; exit 1; }

# USB state of the phone: normal, recovery, dfu, pongo or none.
usb_state() {
    local usb
    usb=$(ioreg -p IOUSB -l -w0)
    if grep -q "PongoOS" <<<"$usb"; then echo pongo
    elif grep -q '"idProduct" = 4647' <<<"$usb"; then echo dfu        # 0x1227
    elif grep -q '"idProduct" = 4737' <<<"$usb"; then echo recovery   # 0x1281
    elif grep -q '"idProduct" = 4776' <<<"$usb"; then echo normal     # 0x12a8
    else echo none
    fi
}

ensure_iproxy() {
    pgrep -f "iproxy 2222:22" >/dev/null || (iproxy 2222:22 >/dev/null 2>&1 &)
    sleep 1
}

# SSH only answers when the jailbreak is active (OpenSSH runs from /var/jb).
jailbroken() {
    ensure_iproxy
    ssh -o BatchMode=yes -o ConnectTimeout=4 ipod 'test -d /var/jb' 2>/dev/null
}

wait_for_state() { # state timeout_seconds
    local i
    for ((i = 0; i < $2 * 2; i++)); do
        [ "$(usb_state)" = "$1" ] && return 0
        sleep 0.5
    done
    return 1
}

verify() {
    say "Kontrol ediliyor…"
    local result
    result=$(ssh -o BatchMode=yes ipod '
        dpkg -l ellekit com.ibrahimkoc.clickwheel com.ibrahimkoc.ipodkiosk 2>/dev/null | grep -c "^ii"
        ps -A -o command= | grep -c "[S]pringBoard.app/SpringBoard"
        ps -A -o command= | grep -c "[C]lickWheel.app/ClickWheel"
    ' 2>/dev/null) || fail "Telefona SSH ile bağlanılamadı."
    local packages springboard app
    { read -r packages; read -r springboard; read -r app; } <<<"$result"
    [ "$packages" = 3 ] && ok "ElleKit, iPod uygulaması ve tweak kurulu" || warn "Paketlerden biri eksik ($packages/3)"
    [ "$springboard" -ge 1 ] && ok "SpringBoard çalışıyor" || warn "SpringBoard çalışmıyor"
    [ "$app" -ge 1 ] && ok "iPod uygulaması açık" || warn "iPod uygulaması açık değil (kilidi açınca gelmeli)"
}

# MARK: Start

command -v palera1n >/dev/null || fail "palera1n bulunamadı."
command -v iproxy >/dev/null || fail "iproxy bulunamadı: brew install libimobiledevice"

state=$(usb_state)
if [ "$state" = normal ] && jailbroken; then
    ok "Jailbreak zaten açık, yapılacak bir şey yok."
    verify
    exit 0
fi

say "Mac parolan gerekiyor (palera1n için). Bir kez soracak:"
sudo -v || fail "sudo parolası alınamadı."
# Keep sudo alive so the password never expires halfway (it once cost us a DFU session).
( while true; do sudo -n true; sleep 30; done ) 2>/dev/null &
SUDO_KEEPALIVE=$!
trap 'kill $SUDO_KEEPALIVE 2>/dev/null' EXIT

# A palera1n left over from an earlier run grabs the USB device.
if pgrep -x palera1n >/dev/null; then
    warn "Eski bir palera1n işlemi kapatılıyor"
    sudo pkill -x palera1n
fi

# MARK: Get to DFU

state=$(usb_state)
case $state in
    none) say "Telefon USB'de görünmüyor. Kabloyu tak, açık olduğundan emin ol."
          until [ "$(usb_state)" != none ]; do sleep 1; done
          state=$(usb_state) ;;
    recovery) warn "Telefon Recovery modunda, normal açılışa alınıyor"
          palera1n -n >/dev/null 2>&1
          wait_for_state normal 90 || fail "Telefon Recovery'den çıkmadı."
          state=normal ;;
esac

attempt=0
while [ "$state" = normal ]; do
    attempt=$((attempt + 1))
    [ $attempt -gt 6 ] && fail "6 denemede DFU'ya girilemedi. Biraz ara verip tekrar çalıştır."
    say "DFU'ya geçiş (deneme $attempt)"
    echo "  Telefon açık ve kilidi açılmış olsun."
    echo "  Hazır olunca Enter'a bas, sonra ekrandaki sayaca göre tuşlara bas."
    read -r
    printf '  \033[1mHome + Yan tuş\033[0m: ikisine birlikte basılı tut… '
    for i in 8 7 6 5 4 3 2 1; do printf '%s ' $i; sleep 1; done
    printf '\n  \033[1mYan tuşu BIRAK\033[0m, Home basılı kalsın… '
    for i in 8 7 6 5 4 3 2 1; do
        printf '%s ' $i
        [ "$(usb_state)" = dfu ] && break
        sleep 1
    done
    echo
    if wait_for_state dfu 3; then
        ok "DFU modu! Home'u bırakabilirsin."
        state=dfu
    else
        state=$(usb_state)
        if [ "$state" = recovery ]; then
            warn "Recovery'ye düştü (Apple logosu görünce Home çok uzun basılmış olabilir). Normal açılışa alınıyor…"
            palera1n -n >/dev/null 2>&1
            wait_for_state normal 90
        else
            warn "DFU olmadı. Telefon normal açılana kadar bekleniyor…"
            wait_for_state normal 90
        fi
        state=normal
    fi
done

# MARK: palera1n

# palera1n sometimes hangs at "Booting PongoOS..." although PongoOS is up; a fresh
# run then finds the PongoOS device and continues, so it is retried a few times.
for run in 1 2 3 4; do
    say "palera1n çalışıyor (deneme $run)…"
    : > "$PALERA1N_LOG"
    sudo palera1n -l > "$PALERA1N_LOG" 2>&1 &
    pid=$!
    pongo_since=""
    while kill -0 $pid 2>/dev/null; do
        sleep 1
        if [ "$(usb_state)" = pongo ] && ! grep -q "Booting Kernel" "$PALERA1N_LOG"; then
            pongo_since=${pongo_since:-$SECONDS}
            if [ $((SECONDS - pongo_since)) -ge $PONGO_TIMEOUT ]; then
                warn "PongoOS'ta takıldı, palera1n yeniden başlatılıyor"
                sudo pkill -x palera1n
                break
            fi
        fi
    done
    wait $pid 2>/dev/null
    grep -q "Booting Kernel" "$PALERA1N_LOG" && break
    if [ "$(usb_state)" != pongo ] && [ "$(usb_state)" != dfu ]; then
        tail -5 "$PALERA1N_LOG"
        fail "palera1n başarısız oldu ve telefon PongoOS/DFU'da değil. Betiği tekrar çalıştır."
    fi
done
grep -q "Booting Kernel" "$PALERA1N_LOG" || fail "palera1n 4 denemede bitmedi. Log: $PALERA1N_LOG"
ok "Kernel başlatıldı"

# MARK: Wait for iOS

say "iOS açılıyor (beyaz palera1n ekranından sonra)…"
wait_for_state normal 180 || fail "Telefon 3 dakikada açılmadı."
for i in $(seq 1 60); do
    jailbroken && break
    sleep 3
done
jailbroken || fail "Telefon açıldı ama SSH cevap vermiyor; jailbreak açılmamış olabilir."
ok "Jailbreak açık"

verify
say "Tamam! Telefon tekrar iPod 🎵"
