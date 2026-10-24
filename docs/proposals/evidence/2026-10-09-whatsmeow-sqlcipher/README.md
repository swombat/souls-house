# whatsmeow on SQLCipher: reviewable probe (2026-10-09)

This is a compact copy of the slice 0 probe, written by Tim (an Opus helper) and
re-checked by Lume. It covers spec §6b of
`../../2026-10-09-whatsapp-connections.md`. Everything in it is synthetic: the
keys come from a fixed seed (`main.go`, `seedBytes`), the JIDs are non-numeric,
nothing was paired, and no WhatsApp server was contacted. The databases (about
1 GB) are not included. Re-run to regenerate them.

Pinned versions (also in `go.mod`/`go.sum`):

- Go 1.27.2 linux/amd64, with cgo (gcc 15.3.0)
- `go.mau.fi/whatsmeow v0.0.0-20261007111105-c386243a72ba`
- Driver A: `github.com/mutecomm/go-sqlcipher/v4 v4.4.2` (SQLCipher 4.4.2, SQLite 3.33.0)
- Driver B: `github.com/mattn/go-sqlite3` replaced by
  `github.com/jgiannuzzi/go-sqlite3 v1.14.35-0.20260227142656-2c447b9a2806`
  (branch `sqlite3mc-2.2.7`, SQLite3 Multiple Ciphers 2.2.7, SQLite 3.51.2),
  run with `_cipher=sqlcipher&_legacy=4`

To reproduce, adjust `goenv.sh` to your toolchain paths first:

```sh
source goenv.sh
go build -tags mutecomm -o bin/probe-mutecomm .   # driver A
go build -tags mc       -o bin/probe-mc .         # driver B
./bin/probe-<v> -mode write -data runs/<v>/data   # exercise every store interface
./run_kill.sh <v> 3                               # loop writer, SIGKILL after 3 s, snapshot
python3 mkpats.py ...                             # build needles from a separate decrypted copy
./fastscan.sh pats.bin runs/<v>/snapshot /tmp "$TMPDIR"  # Aho-Corasick prefilter
python3 scan.py ...                               # exact per-needle verification of hits
```

Before use, check the exact flags and arguments in each script's header. The raw
outputs are in `evidence/` (`*/kill.txt`, `scan*.txt`, `write.txt`,
`cross-compat.txt`). The 64-hex strings in `kill.txt` are file SHA-256 sums,
not keys.

Not covered here, and required before pairing: the production image's writable
layer (`docker diff`), `docker logs` from a live client, and a forced crash
showing that no core is left anywhere.
