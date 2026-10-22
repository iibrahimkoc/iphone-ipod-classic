#!/bin/sh
# Undo for disable.sh: re-enables every daemon in daemons.txt. They start again after a reboot
# (or a userspace reboot: ssh ipod sudo -n /var/jb/usr/bin/launchctl reboot userspace).
cd "$(dirname "$0")"
grep -v '^#' daemons.txt | grep . | while read -r label; do
    echo "sudo -n /var/jb/usr/bin/launchctl enable system/$label; echo \"$label\""
done | ssh ipod sh
