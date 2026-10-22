#!/bin/sh
# Tags MP3s and adds them to the Music app. See muzik.py for options.
DIR="$(cd "$(dirname "$0")" && pwd)"
[ -x "$DIR/.venv/bin/python" ] || { python3 -m venv "$DIR/.venv" && "$DIR/.venv/bin/pip" install -q mutagen; }
exec "$DIR/.venv/bin/python" -I "$DIR/muzik.py" "$@"
