#!/usr/bin/env bash
# usage: fastscan.sh PATTERNS_FILE PATH...
# Aho-Corasick prefilter over all files; prints files containing any pattern.
# Files that hit are then verified needle-by-needle with scan.py.
PATS=$1; shift
export LC_ALL=C
echo "patterns: $(wc -l < "$PATS") lines; paths: $*"
echo "regular files scanned: $(find "$@" -type f 2>/dev/null | wc -l), bytes: $(find "$@" -type f -printf '%s\n' 2>/dev/null | awk '{s+=$1} END {print s}')"
HITS=$(grep -r -a -F -l -f "$PATS" "$@" 2>/tmp/fastscan.err)
RC=$?
echo "grep exit: $RC (0=match, 1=no match, 2=error)"; cat /tmp/fastscan.err; rm -f /tmp/fastscan.err
if [ -n "$HITS" ]; then echo "FILES WITH HITS:"; echo "$HITS"; else echo "NO HITS"; fi
