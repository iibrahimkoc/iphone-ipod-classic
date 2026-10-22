"""Tags downloaded MP3s (title, artist, album, year, genre, cover) from the iTunes Search API
and adds them to the Music app, ready for a Finder sync to the iPod.

YouTube-converted file names come in either order ("Artist - Title" or "Title - Artist") and
carry noise like "(320k)", so the whole cleaned name is searched and the best match is picked.

Usage: muzik.sh [--deneme] [--evet] [files or folders...]   (default: ~/Downloads)
  --deneme  only show what would happen
  --evet    accept every match without asking

For the iPod Müzik app:
  muzik.sh --json FILE...   prints [{"path", "source", "info"}] without changing anything
  muzik.sh --uygula         reads [{"path", "info"}] on stdin, tags and adds each to Music,
                            prints [{"path", "ok", "error"}]
  muzik.sh --etiketle       same, but only writes the tags (the app then sends the file to the iPod)
"""
import json
import re
import shutil
import subprocess
import sys
import unicodedata
import urllib.parse
import urllib.request
from pathlib import Path

from mutagen.id3 import APIC, ID3, TALB, TCON, TDRC, TIT2, TPE1, TPE2, TRCK, ID3NoHeaderError

DONE_DIR = Path.home() / "Downloads" / "iPod-eklendi"
NOISE = re.compile(
    r"[\(\[][^\)\]]*(320k|128k|kbps|official|video|audio|lyric|klip|hd|hq|4k|remaster)[^\)\]]*[\)\]]"
    r"|\b(official (music )?video|lyrics?|klip|full hd)\b",
    re.IGNORECASE,
)

# Turkish letters that NFKD doesn't reduce to ASCII.
TURKISH = str.maketrans("ıİşŞğĞçÇöÖüÜ", "iIsSgGcCoOuU")


def normalize(text):
    text = unicodedata.normalize("NFKD", text.translate(TURKISH))
    text = "".join(c for c in text if not unicodedata.combining(c))
    return re.sub(r"[^a-z0-9 ]", " ", text.lower()).split()


def clean_name(path):
    """'Onur ATMACA - Oy Dedim - Onur ATMACA (320k)' -> ['Onur ATMACA', 'Oy Dedim']"""
    name = NOISE.sub("", path.stem)
    parts = []
    for part in re.split(r"\s+[-–—|]\s+", name):
        part = part.strip(" -_")
        if part and normalize(part) not in [normalize(p) for p in parts]:
            parts.append(part)
    return parts


def search(parts):
    query = urllib.parse.urlencode({"term": " ".join(parts), "entity": "song", "country": "TR", "limit": 10})
    with urllib.request.urlopen(f"https://itunes.apple.com/search?{query}", timeout=15) as response:
        results = json.load(response)["results"]

    wanted = set(normalize(" ".join(parts)))
    best, best_score = None, 0.0
    for result in results:
        found = set(normalize(f"{result['artistName']} {result['trackName']}"))
        # Share of the file name's words found in the result, penalizing extra words in the result.
        score = len(wanted & found) / len(wanted) - 0.05 * len(found - wanted)
        if score > best_score:
            best, best_score = result, score
    return best if best_score >= 0.6 else None


def guess(parts):
    """Without a match, assume 'Artist - Title' and make it its own single."""
    artist, title = (parts[0], parts[1]) if len(parts) >= 2 else ("", parts[0] if parts else "")
    return {"trackName": title, "artistName": artist, "collectionName": f"{title} - Single"}


def write_tags(path, info):
    try:
        tags = ID3(path)
    except ID3NoHeaderError:
        tags = ID3()
    tags.delall("APIC")
    tags.add(TIT2(encoding=3, text=info["trackName"]))
    tags.add(TPE1(encoding=3, text=info["artistName"]))
    # "albumArtist" groups songs by different artists into one album (e.g. "Çeşitli Sanatçılar").
    tags.add(TPE2(encoding=3, text=info.get("albumArtist") or info["artistName"]))
    tags.add(TALB(encoding=3, text=info["collectionName"]))
    if info.get("releaseDate"):
        tags.add(TDRC(encoding=3, text=info["releaseDate"][:4]))
    if info.get("primaryGenreName"):
        tags.add(TCON(encoding=3, text=info["primaryGenreName"]))
    if info.get("trackNumber"):
        tags.add(TRCK(encoding=3, text=f"{info['trackNumber']}/{info.get('trackCount', '')}".rstrip("/")))
    if info.get("artworkUrl100"):
        url = info["artworkUrl100"].replace("100x100bb", "600x600bb")
        with urllib.request.urlopen(url, timeout=15) as response:
            tags.add(APIC(encoding=3, mime="image/jpeg", type=3, desc="Cover", data=response.read()))
    tags.save(path, v2_version=3)


def add_to_music(path):
    script = f'tell application "Music" to add POSIX file "{path}"'
    subprocess.run(["osascript", "-e", script], check=True, capture_output=True)


def collect(args):
    paths = [Path(a).expanduser() for a in args] or [Path.home() / "Downloads"]
    files = []
    for path in paths:
        files += sorted(path.glob("*.mp3")) if path.is_dir() else [path]
    return files


INFO_KEYS = ("trackName", "artistName", "collectionName", "artworkUrl100", "releaseDate",
             "primaryGenreName", "trackNumber", "trackCount", "albumArtist")


def json_lookup(paths):
    out = []
    for path in paths:
        parts = clean_name(path)
        try:
            found = search(parts)
        except OSError:
            found = None
        info = found or guess(parts)
        out.append({"path": str(path), "source": "itunes" if found else "guess",
                    "info": {k: info[k] for k in INFO_KEYS if k in info}})
    print(json.dumps(out, ensure_ascii=False))


def json_apply(add):
    out = []
    for entry in json.load(sys.stdin):
        try:
            write_tags(entry["path"], entry["info"])
            if add:
                add_to_music(entry["path"])
            out.append({"path": entry["path"], "ok": True})
        except Exception as error:  # reported per file to the app
            out.append({"path": entry["path"], "ok": False, "error": str(error)})
    print(json.dumps(out, ensure_ascii=False))


def main():
    if "--uygula" in sys.argv or "--etiketle" in sys.argv:
        json_apply(add="--uygula" in sys.argv)
        return
    if "--json" in sys.argv:
        json_lookup([Path(a).expanduser() for a in sys.argv[1:] if not a.startswith("--")])
        return
    flags = {a for a in sys.argv[1:] if a.startswith("--")}
    dry_run, accept_all = "--deneme" in flags, "--evet" in flags
    given = [a for a in sys.argv[1:] if not a.startswith("--")]
    files = collect(given)
    if not files:
        print("Mp3 bulunamadı.")
        return

    seen = set()
    added = 0
    for path in files:
        parts = clean_name(path)
        info = search(parts)
        source = "iTunes" if info else "tahmin"
        info = info or guess(parts)

        key = (" ".join(normalize(info["artistName"])), " ".join(normalize(info["trackName"])))
        print(f"\n{path.name}")
        if key in seen:
            print("  ↷ aynı şarkı zaten eklendi, atlanıyor")
            continue
        seen.add(key)
        print(f"  {info['artistName']} – {info['trackName']}")
        print(f"  Albüm: {info['collectionName']}  ({source}{', kapaklı' if info.get('artworkUrl100') else ''})")

        if dry_run:
            continue
        if not accept_all:
            answer = input("  Ekleyeyim mi? [E/h] ").strip().lower()
            if answer in ("h", "hayir", "hayır", "n", "no"):
                continue
        write_tags(path, info)
        add_to_music(path)
        # Only the default Downloads scan moves files away, so the next scan skips them;
        # dropped files stay where they are (Music keeps its own copy).
        if not given:
            DONE_DIR.mkdir(exist_ok=True)
            shutil.move(str(path), DONE_DIR / path.name)
        print("  ✓ Müzik uygulamasına eklendi")
        added += 1

    if dry_run:
        print("\n(Deneme: hiçbir dosya değiştirilmedi.)")
    elif added:
        print(f"\n{added} şarkı eklendi. Şimdi Finder'da iPhone'u seçip Müzik → Eşzamanla'ya bas.")


if __name__ == "__main__":
    main()
