#!/usr/bin/env bash
# usage: run_kill.sh VARIANT SECONDS
# Starts the write loop against runs/VARIANT/data, SIGKILLs it mid-write,
# then snapshots and scans. Default GOTRACEBACK (unset) as in production.
set -u
cd "$(dirname "$0")"
V=$1; SECS=${2:-3}
D=runs/$V/data
E=evidence/$V
mkdir -p "$E"
unset GOTRACEBACK
./bin/probe-$V -mode loop -data "$D" > "$E/loop.out" 2>&1 &
PID=$!
sleep "$SECS"
echo "--- files just before kill" | tee "$E/kill.txt"
ls -la "$D" | tee -a "$E/kill.txt"
kill -9 $PID
wait $PID; echo "loop exit status: $? (137 = SIGKILL)" | tee -a "$E/kill.txt"
tail -2 "$E/loop.out" | tee -a "$E/kill.txt"
echo "--- files after kill (untouched)" | tee -a "$E/kill.txt"
ls -la "$D" | tee -a "$E/kill.txt"
sha256sum "$D"/* | tee -a "$E/kill.txt"
rm -rf "runs/$V/snapshot"; cp -a "$D" "runs/$V/snapshot"
echo "--- core files anywhere under work dir / cwd?" | tee -a "$E/kill.txt"
find . /tmp "${TMPDIR:-/tmp}" -maxdepth 3 -name 'core*' 2>/dev/null | tee -a "$E/kill.txt"
