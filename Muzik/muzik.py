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
  muzik.sh --ipod-oku HOST FOLDER
                            prints the tags of the MP3s already on the iPod (covers go to a cache folder)
  muzik.sh --ipod-yaz       reads {"host", "folder", "songs": [...], "delete": [names]} on stdin,
                            rewrites those songs' tags on the iPod, prints [{"path", "ok", "error"}]
"""
import hashlib
import io
import json
import re
import shlex
import shutil
import subprocess
import sys
import unicodedata
import urllib.parse
import urllib.request
from pathlib import Path

from mutagen.id3 import APIC, ID3, TALB, TCON, TDRC, TIT2, TPE1, TPE2, TRCK, ID3NoHeaderError

DONE_DIR = Path.home() / "Downloads" / "iPod-eklendi"
COVER_DIR = Path.home() / "Library" / "Caches" / "com.ibrahimkoc.ipodmuzik" / "covers"
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
    # A leading track number ("01 - ", "1. ") is not part of the artist or title.
    name = re.sub(r"^\d{1,3}\s*(\.|\s[-–—]\s)\s*", "", NOISE.sub("", path.stem))
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


def read_tags(path):
    """The file's own title and artist (e.g. set when it was downloaded), or None."""
    try:
        tags = ID3(path)
    except Exception:
        return None
    text = lambda key: str(tags[key].text[0]).strip() if key in tags and tags[key].text else ""
    if not (text("TIT2") and text("TPE1")):
        return None
    info = {"trackName": text("TIT2"), "artistName": text("TPE1"),
            "collectionName": text("TALB") or f"{text('TIT2')} - Single", "noAlbum": not text("TALB")}
    if text("TPE2"):
        info["albumArtist"] = text("TPE2")
    number, _, count = text("TRCK").partition("/")
    if number.isdigit():
        info["trackNumber"] = int(number)
    if count.isdigit():
        info["trackCount"] = int(count)
    return info


def json_lookup(paths):
    out = []
    for path in paths:
        tagged = read_tags(path)
        parts = [tagged["artistName"], tagged["trackName"]] if tagged else clean_name(path)
        try:
            found = search(parts)
        except OSError:
            found = None
        if tagged:
            # Keep the file's names; iTunes only adds the cover, year and genre,
            # and the album when the file has none.
            keys = ["artworkUrl100", "releaseDate", "primaryGenreName"]
            if tagged.get("noAlbum"):
                keys += ["collectionName", "trackNumber", "trackCount"]
            extra = {k: found[k] for k in keys if found and k in found}
            info, source = {**tagged, **extra}, "tags"
        else:
            info, source = found or guess(parts), "itunes" if found else "guess"
        out.append({"path": str(path), "source": source,
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


def ssh(host, command, data=None):
    """Runs `command` on the iPod. Shares the app's kept-open connection (see Phone.swift)."""
    args = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ControlMaster=auto", "-o", "ControlPersist=120",
            "-o", f"ControlPath={Path.home()}/.ssh/ipod-%C", f"mobile@{host}", command]
    return subprocess.run(args, input=data, capture_output=True, check=True).stdout


def phone_tags(host, folder, names=None):
    """{name: the file's ID3 tag bytes} for the iPod's MP3s, fetching only the tags, not the audio."""
    # First each file's 10-byte ID3 header, which holds the tag's size...
    pattern = " ".join(shlex.quote(n) for n in names) if names else "*.mp3"
    listing = ssh(host, f"cd {shlex.quote(folder)} && for f in {pattern}; do [ -f \"$f\" ] || continue; "
                        "printf '%s\\t' \"$f\"; head -c 10 \"$f\" | od -An -tu1 -v | tr -d '\\n'; echo; done")
    sizes = {}
    for line in listing.decode().splitlines():
        name, _, numbers = line.partition("\t")
        header = [int(n) for n in numbers.split()]
        if len(header) == 10 and bytes(header[:3]) == b"ID3":
            size = 10 + (header[6] << 21 | header[7] << 14 | header[8] << 7 | header[9])
            sizes[name] = size + 10 if header[5] & 0x10 else size  # a footer
        else:
            sizes[name] = 0
    # ...then all the tags in one go, cut apart by those sizes.
    tagged = [n for n in sizes if sizes[n]]
    command = " && ".join(f"head -c {sizes[n]} {shlex.quote(n)}" for n in tagged)
    data = ssh(host, f"cd {shlex.quote(folder)} && {command}") if tagged else b""
    tags, offset = {name: b"" for name in sizes}, 0
    for name in tagged:
        tags[name] = data[offset:offset + sizes[name]]
        offset += sizes[name]
    return tags


def phone_read(host, folder):
    COVER_DIR.mkdir(parents=True, exist_ok=True)
    out = []
    for name, data in sorted(phone_tags(host, folder).items()):
        try:
            tags = ID3(io.BytesIO(data))
        except Exception:
            tags = {}
        text = lambda key: str(tags[key].text[0]).strip() if key in tags and tags[key].text else ""
        cover = None
        pictures = tags.getall("APIC") if tags else []
        if pictures:
            picture = pictures[0].data
            cover = COVER_DIR / f"{hashlib.sha1(picture).hexdigest()}.jpg"
            if not cover.exists():
                cover.write_bytes(picture)
        number = text("TRCK").partition("/")[0]
        out.append({"name": name, "title": text("TIT2") or Path(name).stem, "artist": text("TPE1"),
                    "album": text("TALB"), "albumArtist": text("TPE2"),
                    "track": int(number) if number.isdigit() else 0, "cover": cover and str(cover)})
    print(json.dumps(out, ensure_ascii=False))


def phone_write():
    """Rewrites only the tag at the start of each file; the audio after it stays on the phone."""
    job = json.load(sys.stdin)
    host, folder = job["host"], job["folder"]
    out = []
    for name in job.get("delete", []):
        try:
            ssh(host, f"rm -f {shlex.quote(folder + '/' + name)}")
            out.append({"path": name, "ok": True})
        except subprocess.CalledProcessError as error:
            out.append({"path": name, "ok": False, "error": error.stderr.decode(errors="replace")})
    songs = job.get("songs", [])
    old = phone_tags(host, folder, [song["name"] for song in songs]) if songs else {}
    for song in songs:
        name = song["name"]
        try:
            tags = ID3(io.BytesIO(old[name])) if old.get(name) else ID3()
            for key, frame in (("title", TIT2), ("artist", TPE1), ("album", TALB), ("albumArtist", TPE2)):
                tags.delall(frame.__name__)
                if song.get(key):
                    tags.add(frame(encoding=3, text=song[key]))
            tags.delall("TRCK")
            if song.get("track"):
                tags.add(TRCK(encoding=3, text=f"{song['track']}/{song.get('trackCount', '')}".rstrip("/")))
            if song.get("cover"):
                tags.delall("APIC")
                tags.add(APIC(encoding=3, mime="image/jpeg", type=3, desc="Cover",
                              data=Path(song["cover"]).read_bytes()))
            buffer = io.BytesIO()
            tags.save(buffer, v2_version=3, padding=lambda info: 1024)
            path, part, tag = (shlex.quote(f"{folder}/{n}") for n in (name, f".{name}.part", f".{name}.tag"))
            # Written next to the file and moved over it, so the iPod never sees half a song.
            ssh(host, f"cat > {tag} && {{ cat {tag}; tail -c +{len(old.get(name, b'')) + 1} {path}; }} > {part} "
                      f"&& mv {part} {path}; rm -f {tag}", buffer.getvalue())
            out.append({"path": name, "ok": True})
        except Exception as error:  # reported per song to the app
            message = error.stderr.decode(errors="replace") if isinstance(error, subprocess.CalledProcessError) else str(error)
            out.append({"path": name, "ok": False, "error": message.strip()})
    print(json.dumps(out, ensure_ascii=False))


def main():
    if "--ipod-oku" in sys.argv:
        phone_read(*[a for a in sys.argv[1:] if not a.startswith("--")])
        return
    if "--ipod-yaz" in sys.argv:
        phone_write()
        return
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
