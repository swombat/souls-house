#!/usr/bin/env python3
"""Turn hex needles into newline-free byte patterns for LC_ALL=C grep -F -f.
For each needle not containing b'CANARY' (those are covered by the bare
token), emit its longest newline-free segment if >= 10 bytes; count the rest."""
import sys
out = open(sys.argv[2], "wb")
n = skipped = 0
for l in open(sys.argv[1]):
    l = l.strip()
    if not l:
        continue
    b = bytes.fromhex(l)
    if b"CANARY" in b:
        continue
    seg = max(b.split(b"\n"), key=len)
    if len(seg) < 10:
        skipped += 1
        continue
    out.write(seg + b"\n")
    n += 1
out.write(b"CANARY\n")
out.write(b"SQLite format 3\n")
print(f"{n} binary patterns + 2 tokens (CANARY, 'SQLite format 3'); {skipped} needles had no >=10-byte newline-free segment", file=sys.stderr)
