#!/usr/bin/env python3
import argparse
import json
from pathlib import Path

def load(path):
    p = Path(path)
    if not p.exists():
        return []
    return [
        json.loads(line)
        for line in p.read_text().splitlines()
        if line.strip()
    ]

def require(records, predicate, message):
    if not any(predicate(r) for r in records):
        raise SystemExit(message)

def verify(records, label):
    require(
        records,
        lambda r: r["method"] == "PROPFIND"
        and r["path"] == "/"
        and r["authorization"],
        f"{label}: missing authenticated root PROPFIND"
    )
    require(
        records,
        lambda r: r["method"] == "GET"
        and r["path"] == "/photo.jpg"
        and bool(r["range"]),
        f"{label}: image thumbnail did not use HTTP Range"
    )
    require(
        records,
        lambda r: r["method"] == "GET"
        and r["path"] == "/clip.mp4"
        and bool(r["range"]),
        f"{label}: video thumbnail/stream did not use HTTP Range"
    )

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--local-log", required=True)
    parser.add_argument("--remote-log", required=True)
    args = parser.parse_args()

    local = load(args.local_log)
    remote = load(args.remote_log)

    verify(local, "local WebDAV")
    verify(remote, "remote WebDAV")

    print(
        f"WebDAV request assertions passed: "
        f"local={len(local)} remote={len(remote)}"
    )

if __name__ == "__main__":
    main()
