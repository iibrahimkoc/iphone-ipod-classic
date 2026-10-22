#!/bin/sh
# Disables (persistently, even without the jailbreak) and stops the daemons in daemons.txt.
# Usage: Daemons/disable.sh   (needs the `ipod` SSH alias and passwordless sudo for launchctl)
cd "$(dirname "$0")"
grep -v '^#' daemons.txt | grep . | while read -r label; do
    echo "sudo -n /var/jb/usr/bin/launchctl disable system/$label; sudo -n /var/jb/usr/bin/launchctl bootout system/$label 2>/dev/null; echo \"$label\""
done | ssh ipod sh
