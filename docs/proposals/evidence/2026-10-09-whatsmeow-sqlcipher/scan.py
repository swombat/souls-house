#!/usr/bin/env python3
"""Scan files for plaintext needles.

usage: scan.py NEEDLES_HEX_FILE PATH [PATH ...]
Needles: one hex string per line (decrypted store values >= 12 bytes plus
deterministic key material). Also searches for the ASCII token 'CANARY-WA'
and the 16-byte plain SQLite header. Prints every hit with file and offset.
"""
import os, sys

allneedles = [bytes.fromhex(l.strip()) for l in open(sys.argv[1]) if l.strip()]
# Any needle containing b"CANARY" can only be present if the bare token
# b"CANARY" is present, which is searched separately; keep the rest (raw
# binary keys, random prekeys, hashes, protobuf blobs without the token).
needles = [n for n in allneedles if b"CANARY" not in n]
print(f"{len(allneedles)} needles total, {len(needles)} without the CANARY token searched individually")
extra = {b"CANARY-WA": "ascii-token", b"CANARY": "ascii-token-short", b"SQLite format 3\x00": "plain-sqlite-header"}
files = []
for root in sys.argv[2:]:
    if os.path.isfile(root):
        files.append(root)
        continue
    for dp, dn, fn in os.walk(root):
        for f in fn:
            files.append(os.path.join(dp, f))

total_hits = 0
scanned = 0
for path in files:
    try:
        if not os.path.isfile(path) or os.path.islink(path):
            continue
        data = open(path, "rb").read()
    except Exception as e:
        print(f"SKIP {path}: {e}")
        continue
    scanned += 1
    hits = []
    for n in needles:
        i = data.find(n)
        if i >= 0:
            hits.append((f"needle len={len(n)} {n[:24].hex()}...", i))
    for n, label in extra.items():
        i = data.find(n)
        if i >= 0:
            hits.append((label, i))
    if hits:
        total_hits += len(hits)
        nh = sum(1 for l, _ in hits if l.startswith("needle"))
        toks = [f"{l}@{o}" for l, o in hits if not l.startswith("needle")]
        print(f"HIT {path} ({len(data)} bytes): {nh} binary-needle hits; tokens: {toks}")
        for label, off in hits[:20]:
            print(f"    {label} @ {off}")
        if len(hits) > 20:
            print(f"    ... {len(hits)-20} more")
print(f"scanned {scanned} files, {len(needles)} needles, {total_hits} hits")
