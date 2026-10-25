#!/usr/bin/env python3
# refreshes sha1 + released date in DependencyControl.json for the files that changed,
# converting their line endings to LF and making them end on one newline first
# run from the repo root after editing a script, then commit everything together
import datetime
import hashlib
import json
import re
from pathlib import Path

FEED = Path("DependencyControl.json")

VERSION_RES = [
    re.compile(r"""script_version\s*=\s*['"]([^'"]+)['"]"""),
    re.compile(r"""__version__\s*=\s*['"]([^'"]+)['"]"""),
    re.compile(r"""version\s*=\s*['"]([^'"]+)['"]"""),
]

TEMPLATE_RE = re.compile(r"@\{([^}]+)\}")


def file_version(text):
    for r in VERSION_RES:
        m = r.search(text)
        if m:
            return m.group(1)
    return None


def expand(template, values):
    # fills in @{...} variables, returns None if one of them isn't known here
    missing = []

    def sub(m):
        if m.group(1) in values:
            return values[m.group(1)]
        missing.append(m.group(1))
        return m.group(0)

    out = TEMPLATE_RE.sub(sub, template)
    return None if missing else out


# any run of blank or whitespace-only lines at the very end, plus the last newline
TRAILING_RE = re.compile(rb"(?:\n[ \t\f\v]*)+\Z")


def fix_file(path):
    # cleans up line endings and the end of the file, writes it back if anything changed
    orig = path.read_bytes()
    data = orig
    if b"\r\n" in data:
        # depctrl hashes whatever github serves, which is LF, so match that on disk too
        data = data.replace(b"\r\n", b"\n")
        print(f"{path}: converted CRLF line endings to LF")
    if data:
        # always end on exactly one newline
        ended = TRAILING_RE.sub(b"", data) + b"\n"
        if ended != data:
            print(f"{path}: fixed ending newline")
            data = ended
    if data != orig:
        path.write_bytes(data)
    return data


def local_files(name, entry, ch_name, ch):
    # works out where each file lives in the repo from the feed's own url templates.
    # the feed's fileBaseUrl and the channel (branch) are what github adds on top of the repo,
    # so leaving those empty gives the path inside the repo
    values = {"namespace": name, "namespacePath": name.replace(".", "/"), "channel": "", "fileBaseUrl": ""}
    base = expand(entry.get("fileBaseUrl", ""), values)
    if base is None:
        print(f"warning: {name} ({ch_name}): can't work out the folder from {entry.get('fileBaseUrl')}, skipping")
        return
    base = base.strip("/")

    for f in ch.get("files", []):
        url = f.get("url", "@{fileBaseUrl}@{fileName}")
        if not url.startswith("@{fileBaseUrl}"):
            print(f"warning: {name}: {f['name']} isn't hosted in this repo ({url}), skipping")
            continue
        rel = expand(url, {**values, "fileBaseUrl": base, "fileName": f["name"]})
        if rel is None:
            print(f"warning: {name}: can't work out the path from {url}, skipping")
            continue
        yield f, Path(rel.lstrip("/"))


def main():
    feed = json.loads(FEED.read_text(encoding="utf-8"))
    today = datetime.date.today().isoformat()
    for kind in ("macros", "modules"):
        for name, entry in feed.get(kind, {}).items():
            for ch_name, ch in entry["channels"].items():
                changed = False
                for f, path in local_files(name, entry, ch_name, ch):
                    if not path.is_file():
                        print(f"warning: {path} doesn't exist, skipping")
                        continue
                    data = fix_file(path)
                    sha = hashlib.sha1(data).hexdigest()
                    if f.get("sha1") != sha:
                        f["sha1"] = sha
                        changed = True
                    ver = file_version(data.decode("utf-8", "replace"))
                    if ver and ver != ch["version"]:
                        print(f"warning: {path} says version {ver} but the feed says {ch['version']}")
                if changed:
                    ch["released"] = today
                    print(f"{name} ({ch_name}): updated sha1, released {today}")
                if ch["version"] not in entry.get("changelog", {}):
                    print(f"warning: {name} has no changelog entry for {ch['version']}")
    FEED.write_text(json.dumps(feed, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
