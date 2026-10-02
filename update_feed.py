#!/usr/bin/env python3
# refreshes sha1 + released date in DependencyControl.json for the files that changed,
# converting their line endings to LF first
# run from the repo root after editing a script, then commit everything together
import datetime
import hashlib
import json
import re
from pathlib import Path

FEED = Path("DependencyControl.json")

# feed entry -> (folder, file stem). file names in the feed are appended to the stem
ENTRIES = {
    ("macros", "baws.Encode"): ("macros", "baws.Encode"),
    ("modules", "baws.EncodeVS"): ("modules", "baws/EncodeVS"),
}

VERSION_RES = [
    re.compile(r"""script_version\s*=\s*['"]([^'"]+)['"]"""),
    re.compile(r"""__version__\s*=\s*['"]([^'"]+)['"]"""),
    re.compile(r"""version\s*=\s*['"]([^'"]+)['"]"""),
]


def file_version(text):
    for r in VERSION_RES:
        m = r.search(text)
        if m:
            return m.group(1)
    return None


def main():
    feed = json.loads(FEED.read_text(encoding="utf-8"))
    today = datetime.date.today().isoformat()
    for (kind, name), (folder, stem) in ENTRIES.items():
        entry = feed[kind][name]
        for ch_name, ch in entry["channels"].items():
            changed = False
            for f in ch["files"]:
                path = Path(folder, stem + f["name"])
                data = path.read_bytes()
                if b"\r\n" in data:
                    # depctrl hashes whatever github serves, which is LF, so match that on disk too
                    data = data.replace(b"\r\n", b"\n")
                    path.write_bytes(data)
                    print(f"{path}: converted CRLF line endings to LF")
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