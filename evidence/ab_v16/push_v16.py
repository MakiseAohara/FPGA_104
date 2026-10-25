#!/usr/bin/env python3
"""push_v16.py - upload evidence/ab_v16 to origin/main via the Contents API."""
from __future__ import annotations

import base64
import json
import os
import sys
import urllib.parse
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = "MakiseAohara/FPGA_104"
BRANCH = "main"
PREFIX = "evidence/ab_v16"

TOKEN = os.environ.get("GH_TOKEN", "")
if not TOKEN:
    sys.exit("GH_TOKEN not set")

SKIP = {"_append.md", "manifest_dump1.json"}


def api(method, url, payload=None):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(
        url, method=method, data=data,
        headers={"Authorization": f"Bearer {TOKEN}",
                 "Accept": "application/vnd.github+json",
                 "User-Agent": "dsh", "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=180) as r:
        return json.loads(r.read())


def upload(name: str, data: bytes, message: str):
    path = f"{PREFIX}/{urllib.parse.quote(name)}"
    url = f"https://api.github.com/repos/{REPO}/contents/{path}"
    sha = None
    try:
        cur = api("GET", url)
        sha = cur.get("sha")
        if cur.get("content"):
            try:
                existing = base64.b64decode(cur["content"])
                if existing == data:
                    return "unchanged"
            except Exception:
                pass
    except Exception:
        pass
    payload = {"message": message, "content": base64.b64encode(data).decode(),
               "branch": BRANCH}
    if sha:
        payload["sha"] = sha
    api("PUT", url, payload)
    return "added" if not sha else "updated"


def main():
    files = []
    for p in sorted(HERE.iterdir()):
        if not p.is_file():
            continue
        if p.name in SKIP or p.name.endswith(".pyc"):
            continue
        if p.suffix.lower() in (".log", ".bin", ".md", ".png", ".py", ".json", ".csv"):
            files.append(p)

    total = sum(p.stat().st_size for p in files)
    print(f"{len(files)} files, {total/1e6:.1f} MB")

    msg = ("evidence/ab_v16: v16 预处理变体采集与离线评估 "
           "(MERGE11 + 7 个固件变体, IMG_DUMP_EVERY=10)")
    for p in files:
        try:
            st = upload(p.name, p.read_bytes(), msg)
            print(f"  {st:9s} {p.name} ({p.stat().st_size} B)")
        except Exception as e:
            print(f"  FAILED    {p.name}: {e}")
    print("done")


if __name__ == "__main__":
    main()
