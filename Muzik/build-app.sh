#!/bin/sh
# Builds the "iPod Müzik" droplet into ~/Applications. It runs this folder's muzik.sh.
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Applications/iPod Müzik.app"
mkdir -p "$HOME/Applications"
rm -rf "$APP"
osacompile -o "$APP" "$DIR/iPod Müzik.applescript"
# The droplet calls back into this folder (venv and script), via a small launcher.
printf '#!/bin/sh\nexec "%s/muzik.sh" "$@"\n' "$DIR" > "$APP/Contents/Resources/muzik.sh"
chmod +x "$APP/Contents/Resources/muzik.sh"
# Adding the launcher invalidates osacompile's signature; re-sign ad hoc.
codesign -f -s - "$APP" 2>/dev/null
echo "$APP"
