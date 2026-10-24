# whatsmeow `sqlstore` on SQLCipher: probe findings (2026-10-09)

Scope: the two unverified claims in
`sh-whatsapp/docs/proposals/2026-10-09-whatsapp-connections.md` §2 ("the
encrypted persistence seam"). **Synthetic data only.** Nothing was paired, no
WhatsApp server was contacted, and no phone numbers were used. The JIDs are
non-numeric (`canaryown`, `canarypeer`, `canarygroup`…). No `whatsmeow.Client`
was constructed. The souls-house repo was not touched.

Everything is in `/home/agent/work/wa-sqlcipher-probe`: `main.go` and the
driver files, the scripts, `evidence/` (raw outputs) and `runs/` (the
databases, the untouched post-kill snapshots, and copies).

## Summary

| Question | Answer |
|---|---|
| 1. Does `sqlstore` run unmodified on SQLCipher? | **Yes, on both drivers tested.** `sqlstore.New(ctx, "sqlite3-sqlcipher", dsn, nil)` ran all upgrades (schema v1→latest), then `Device.Save` and every store interface wrote and read back. No whatsmeow change was needed. **One trap:** the key must be in the DSN. Putting it in a `ConnectHook` breaks every reopen (details below). |
| 2. Plaintext on disk after SIGKILL mid-write (WAL, `temp_store=MEMORY`)? | **None found.** `CANARY` appeared in 0 of 3 data files (db, -wal, -shm). Raw key bytes and stored values: 0 of 1,032 binary needles found in the data files, `/tmp` or `$TMPDIR`. The scanner found them all in a plaintext positive control. The db is not readable as plain SQLite, and a wrong key fails. |
| 3. Does whatsmeow write to disk outside the store? | **Not by default.** There is one library-internal file write: an `os.CreateTemp` in `UploadReader`, holding **ciphertext**, and only when the caller passes no temp file. `DownloadToFile*` writes decrypted media to a file the caller supplies. Two **stdout** paths matter in Docker: libsignal's default logger, and whatsmeow's debug XML logs if we give it a logger. |
| 4. Fallback needed? | No. A sketch is included anyway, in case driver policy rules out cgo. |

## Versions

- Go **1.27.2** linux/amd64 (official tarball, sha256 checked against go.dev's JSON) in `/home/agent/state/tools/go`; GOPATH/GOMODCACHE/GOCACHE/GOTMPDIR under `/home/agent/state/tools/gopath`. gcc 15.3.0 (conda-forge).
- **whatsmeow `v0.0.0-20261007111105-c386243a72ba`**: master as of 2026-10-07. whatsmeow has no tagged releases, so `@latest` is this pseudo-version. It brings `go.mau.fi/util v0.10.1` (dbutil), `go.mau.fi/libsignal v0.2.2` and `zerolog v1.35.1`. Schema upgrades 00–16 ran.
- Driver A: **`github.com/mutecomm/go-sqlcipher/v4 v4.4.2`**, bundling SQLCipher **4.4.2** community and SQLite **3.33.0** (amalgamation plus libtomcrypt, no OpenSSL). It is the one the brief suggested. **It is unmaintained:** last commit 2020-12-07, and its SQLite is from 2020 (several CVEs since).
- Driver B: **`github.com/jgiannuzzi/go-sqlite3` at branch `sqlite3mc-2.2.7`** (commit `2c447b9a2806`, 2026-02-27), pinned as a `replace` for `github.com/mattn/go-sqlite3`. It bundles SQLite3 Multiple Ciphers **2.2.7** on SQLite **3.51.2** and is used in SQLCipher v4 mode (`_cipher=sqlcipher&_legacy=4`). I chose it as the "maintained" candidate: it is a current mattn fork bundling the amalgamation, its SQLite is current, and it produces SQLCipher v4 files. It is a personal fork, though, not an org-maintained package (see risks).
- **Cross-compatibility, verified both ways:** a DB created by B opens under A (genuine SQLCipher 4.4.2), and A's DB (with its 19,122 rows recovered after the kill) opens under B. `integrity_check: ok` in both directions (`evidence/cross-compat.txt`). So B's files really are SQLCipher v4 format, and moving from A to B later needs no migration.

## 1. `sqlstore` unmodified on a SQLCipher driver

**Dialect.** `sqlstore.New(ctx, dialect, address, log)` does `sql.Open(dialect, address)`, then `dbutil.NewWithDB(db, dialect)`. `dbutil.ParseDialect` lower-cases the name and maps any name **starting with `sqlite`** (or `litestream`) to the SQLite dialect, and `postgres*`/`pgx` to Postgres (`go.mau.fi/util@v0.10.1/dbutil/database.go:39`). So the driver does not have to be registered as `"sqlite3"`. The probe registers its own `sql.Register("sqlite3-sqlcipher", &SQLiteDriver{ConnectHook: …})` and passes that name as the dialect. That avoids the clash between the `init()`s of mattn and mutecomm, which both register `"sqlite3"`. whatsmeow imports no SQLite driver itself.

**The trap: key in the DSN, not the ConnectHook.** My first version ran `PRAGMA key` as the first statement of `ConnectHook`. The fresh DB was created fine, but every later connection failed:

```
A: FAIL journal_mode: file is not a database                       (2nd pool on same file)
B: FAIL sqlstore.New: failed to upgrade database: failed to check if foreign keys are enabled: file is not a database   (reopen)
```

Cause: both drivers run their own pragmas inside `Open()` before `ConnectHook`. `PRAGMA synchronous` runs unconditionally and needs the schema, so SQLCipher reads page 1 before it has a key. The fix is to give the key through the driver's DSN parameters, which `Open()` applies first:

- A: `file:/data/x/comms.db?_pragma_key=x'<64 hex>'&_pragma_cipher_page_size=4096`
- B: `file:/data/x/comms.db?_cipher=sqlcipher&_legacy=4&_key=x'<64 hex>'`

(`x'…'` is a raw 256-bit key, so the PBKDF2 step is skipped. That is right for an HKDF-derived subkey.) Consequence for the design: **the derived key sits in the DSN string in process memory.** Don't log the DSN (dbutil's own logging is off by default, `NoopLogger`). The other pragmas (`foreign_keys=ON`, `journal_mode=WAL`, `temp_store=MEMORY`, `busy_timeout`) stay in `ConnectHook`, which runs on **every** pooled connection. That matters because `temp_store` is per-connection, and both builds compile with `SQLITE_TEMP_STORE=1`, meaning temp files by default unless the pragma is set.

**What was exercised** (`main.go` `doWrite`; output in `evidence/mutecomm-write.txt` and `evidence/mc/write.txt`):

```
journal_mode=wal temp_store=2 cipher_version="4.4.2 community" sqlite_version=3.33.0          (A)
journal_mode=wal temp_store=2 cipher_version="SQLite3 Multiple Ciphers 2.2.7" sqlite_version=3.51.2   (B)
device saved: canaryown:7@s.whatsapp.net
prekeys: one=1 batch=5 uploaded=6 (random keys, generated inside whatsmeow)
write: all store interfaces exercised OK
```

These calls went through the real interfaces, with canaries (`CANARY-WA-<field>`) or seed-derived binary keys in every value I control:

- `container.NewDevice()` + `Device.Save` (PutDevice), twice. Noise/identity/signed-prekey private keys, ADV secret, account signature key, platform, push and business names, companion meta nonce.
- `PutIdentity`, `PutSession`, `PutManySessions`.
- `GenOnePreKey`, `GetOrGenPreKeys(5)`, `MarkPreKeysAsUploaded`, `UploadedPreKeyCount`. These prekeys are random, generated inside whatsmeow, and were harvested afterwards as needles.
- `PutSenderKey`, `PutAppStateSyncKey`, `PutAppStateVersion`, `PutAppStateMutationMACs`.
- `PutPushName`, `PutBusinessName`, `PutContactName`, `PutAllContactNames` (the app-state contact path), `PutManyRedactedPhones`.
- `PutMutedUntil`, `PutPinned`, `PutWASARootSecretID`.
- `PutMessageSecret`, `PutMessageSecrets` (the history-sync path), `PutPrivacyTokens` (history sync), `PutNCTSalt`.
- `DoDecryptionTxn` + `PutBufferedEvent`, which stores **decrypted message plaintext** in `whatsmeow_event_buffer`. `AddOutgoingEvent` stores outgoing plaintext in `whatsmeow_retry_buffer`.
- `LIDs.PutLIDMapping`, `PutManyLIDMappings` (the history-sync path).
- Our own `comms_message` table (plus an index on `body`) in the same file. One row's `raw` is a marshalled `waHistorySync.HistorySync` proto with a canary conversation name and message body, simulating a decoded history-sync blob stored through the same DB.

Not exercised: the network paths that *call* these (the real history-sync download and decode, `cli.storeHistorical*`), because that needs a connected client. What those paths persist is exactly the store calls above (`message.go:988–1160`), and the decoded `HistorySync` itself is handed to the app as an event, not stored by whatsmeow.

After the kill test, `doDump` reopened each DB: `integrity_check: ok`, all 18 tables readable. Committed loop rows were recovered from the WAL (A: `comms_message` 19,122 rows, sessions 502, identities 501; B: 26,402 / 502 / 501).

## 2. SIGKILL mid-write: canary and key-byte search

Procedure (`run_kill.sh`): the loop mode reopens the DB through `sqlstore.New` and repeatedly writes `PutSession` (≈4.4 KB canary payloads), `PutIdentity` (seed-derived 32-byte keys), and transactions of 20 `comms_message` rows. GOTRACEBACK was left unset. After 3 s it got `kill -9`. Before scanning, the files were hashed and copied to `runs/<v>/snapshot`. Needles were then extracted from a *separate* copy, so opening the DB (which replays the WAL) never touched the scanned bytes.

```
A: comms.db 91,512,832 B | comms.db-wal 4,231,272 B | comms.db-shm 32,768 B   loop exit status 137 (SIGKILL), last "loop iteration 950"
B: comms.db 122,896,384 B | comms.db-wal 4,231,272 B | comms.db-shm 32,768 B  exit 137, last "loop iteration 1300" (db grew between pre-kill ls and kill: write in flight)
```

No `-journal` file exists in WAL mode, and none appeared.

**Needles.** Every distinct stored value of at least 12 bytes, from every table of the decrypted DB, plus all seed-derived key material, the derived public keys and the SQLCipher key itself (A: 20,685 needles; B: 27,965). Any needle that contains `CANARY` can only be present if the bare token `CANARY` is, so those are covered by searching for `CANARY` directly. That leaves **1,032 binary needles** searched individually: raw private keys, random prekeys, hashes, MACs, secrets, protos. All have a newline-free segment of at least 10 bytes, so 0 were unsearchable. I also searched for the plain-SQLite magic `SQLite format 3\0`.

**Positive control.** A plaintext export of the same DB, made with `ATTACH … KEY ''`, kept in `control/` and not in any scanned path. The prefilter flagged it. Exact scan of A's export: 1,029 of 1,032 binary needles found, plus `CANARY-WA` at offset 11979 and the SQLite header at 0. One of the 3 misses is checked to be the SQLCipher DB key. The other two are 32-byte values that aren't seed keys; by construction they are the two derived public keys, which `whatsmeow_device` doesn't store, since every other needle was read out of this DB. So the scanner sees plaintext when it is there. (The plaintext control files were deleted after use. `runs/` holds about 1 GB of synthetic, encrypted DBs and can be deleted.)

**Results** (`evidence/mutecomm/{scan-grep,fastscan}.txt`, `evidence/mc/scan.txt`):

| Location | A (SQLCipher 4.4.2) | B (sqlite3mc 2.2.7) |
|---|---|---|
| `comms.db` (post-kill) | `grep -a -c CANARY` = 0; 0 needles; first 16 bytes `5f87a91e…` (random salt, not `53514c69…`) | 0; 0 needles; `2d115db9…` |
| `comms.db-wal` (live at kill) | 0; 0 needles. Header `377f0682…` = standard WAL magic (see note) | 0; 0 |
| `comms.db-shm` | 0; 0 | 0; 0 |
| `/tmp` (608 KB) | `grep -r -a -l CANARY /tmp` → exit 1 (no match); 0 needles | same |
| `$TMPDIR` = `/home/agent/work/.tmp` (≈1.7 GB, 41k files total incl. above) | 0 `CANARY`; 0 needles | same |
| **Only prefilter hit** | `$TMPDIR/playwright_chromiumdev_profile-l3T82k/Default/Shared Dictionary/db` (45 KB, mtime Oct 7). Verified exactly: **0 needle hits**; only token `plain-sqlite-header@0`. It is a pre-existing Chromium SQLite file, unrelated. | same file, same verdict |

An exact per-needle Python scan of the snapshot data files, with no prefilter, agrees (`evidence/*/scan-exact-datadir.txt`): A `scanned 3 files, 1032 needles, 0 hits`; B `scanned 3 files, 1032 needles, 0 hits`. (The tokens `CANARY` and the SQLite header are included in that scan, so this is 0 token hits too.)

**Not plain SQLite:** Python's `sqlite3` (SQLite 3.46.1) opening the post-kill `comms.db` gives `DatabaseError: file is not a database` for both A and B. Opening through the cipher driver with a wrong key gives `file is not a database` for both.

**WAL/SHM metadata is not encrypted** (expected SQLCipher behaviour, not a canary leak). The WAL file header and the 24-byte frame headers (page numbers, salts, checksums, db size) and the whole `-shm` wal-index are plaintext. They reveal page counts and write timing, not content. The page images in the WAL are encrypted, as the scan shows.

**Volatile vs durable.**
- *Expected volatile plaintext (process memory only):* every decrypted value while in use. That includes SQLite's page cache of decrypted pages, the Go heap (keys, sessions, `DecryptedMessage` plaintext, decoded history-sync protos), the DSN string carrying the raw SQLCipher key, and whatsmeow's in-memory caches (`CachedLIDMap`, etc.). The design's swap-off, tmpfs `/tmp` and read-only rootfs are what stop this becoming durable.
- *Forbidden durable plaintext:* none observed in the data dir, `/tmp` or `$TMPDIR`. I did not observe the container's writable layer, because this ran in an existing dev container, not the production image. The remaining durable channels are **stdout/stderr** (Docker log driver on the host) and **core dumps** (see §3).

## 3. Does whatsmeow write anything outside the store?

`grep -rnE 'os\.(Create|CreateTemp|WriteFile|MkdirTemp|MkdirAll|Mkdir|OpenFile|Open|Rename|Remove|TempDir)\b|ioutil\.(TempFile|TempDir|WriteFile)|syscall\.|mmap|pprof|WriteHeapDump|os\.Std(out|err)'` over the whatsmeow tree, excluding tests:

| Site | What | Default? |
|---|---|---|
| `upload.go:108` `os.CreateTemp("", "whatsmeow-upload-*")` in `UploadReader` | Temp file for streaming AES-CBC encryption of outgoing media. It holds **ciphertext** (plus HMAC), is removed with `defer os.Remove`, and lives in `$TMPDIR` (our tmpfs). Not reached if we use `Upload([]byte)` or pass our own `tempFile`. | Only when calling `UploadReader(…, nil, …)`. |
| `download-to-file.go` `DownloadToFile` / `DownloadMediaWithPathToFile` / `DownloadFBToFile` | Writes media into a **caller-supplied** `File`, uses `fallocate`, and decrypts **in place**. The file ends up holding **decrypted media**. | Only if we call it. Use `Download()` (in-memory) or give it a file on the encrypted path. |
| `internals_generate.go:114` `os.OpenFile("internals.go")` | Code generator. `//go:build ignore`, not compiled in. | Never. |

There are no other file creations, mmaps, pprof endpoints or heap dumps in whatsmeow. The linked `go.mau.fi/util` packages (exhttp, fallocate, random, retryafter, exsync, dbutil, …) write no files. The util packages that do (ffmpeg, lottie, configupgrade, the generators) are not imported by whatsmeow. No media cache exists. History sync is downloaded into memory (`cli.Download`), zlib-inflated and `proto.Unmarshal`ed in memory (`message.go:783–796`), and handed to the app as an event.

**Stdout/stderr paths that become durable via Docker logs:**
1. **libsignal default logger** (`go.mau.fi/libsignal@v0.2.2/logger`). If nobody calls `logger.Setup`, `Info/Warning/Error` print to **stdout** with `fmt.Println`. The namespace filter's `return` is commented out, so it always prints. `Debug` is a no-op. The messages carry error values and IDs (e.g. "Unable to verify ciphertext mac: …"), not key bytes; the dangerous `Debug("Using cipherKey: …")` calls are no-ops. Recommendation: install a no-op or redacting `Loggable` at startup.
2. **whatsmeow's own logs.** `waLog.Noop` is used if we pass nil. With a real logger at **Debug**, `client.go:867/971` logs every received and sent binary-XML node (`Recv`/`Send`). Those show JIDs, phone numbers, push names, receipts and ciphertext payloads. Never enable Debug for `Recv`/`Send` in production. `zerolog.Ctx(ctx)` calls go to a disabled logger unless we attach one to the context.
3. **Go tracebacks** to stderr on panic. Under the default `GOTRACEBACK=single` these show goroutine stacks with argument words (pointers and small ints), not buffers. The panic *message* can contain data. Use `GOTRACEBACK=none` in the environment. `debug.SetTraceback` cannot lower it below the env setting.

**Core dumps.** The Go runtime only produces a core when `GOTRACEBACK=crash` (or `GOTRACEBACK=core`, whose behaviour I didn't check), and only with a nonzero core rlimit. Under the default (`single`) a fatal signal, including SIGSEGV/SIGABRT inside cgo/SQLite, prints a traceback and exits with status 2, with no core. But **in this container `ulimit -c` is `unlimited` and `/proc/sys/kernel/core_pattern` is `|/usr/share/apport/apport …`**. `core_pattern` is host-global, so any core from the container would be piped to apport **on the host** (`/var/crash`), outside the container and outside the encrypted volume. I did not deliberately crash the probe to test this, because it would have left a file on the host. To prevent it: keep `GOTRACEBACK` unset or `none` (never `crash`), set `--ulimit core=0` on the accessory, and call `prctl(PR_SET_DUMPABLE, 0)` at startup. That also blocks same-uid ptrace and `/proc/<pid>/mem` reads.

## 4. Fallback (not needed, sketched for the cgo-forbidden case)

If cgo or SQLCipher were ruled out, the smallest fallback is to implement `store.AllSessionSpecificStores` (Identity, Session, PreKey, SenderKey, AppStateSyncKey, AppState, Contact, ChatSettings, MsgSecret, PrivacyToken, NCTSalt, EventBuffer), plus `store.LIDStore`, plus `store.DeviceContainer` (PutDevice/DeleteDevice). Then build the `store.Device` yourself and call `SetAllStores` + set `LIDs` and `Container`. That is roughly 70 methods (`store/store.go:23–192`). The simplest correct version keeps whatsmeow's own SQL (copy `sqlstore`) over an encrypted VFS, e.g. `ncruces/go-sqlite3` (pure Go/wasm) with its Adiantum/XTS VFS. That file format is not SQLCipher, so it would need its own review. Since `sqlstore` works unmodified, I'd recommend not doing this.

## Open risks / follow-ups

1. **Driver choice.** A works but is 2020-era SQLite 3.33.0 with known CVEs; unacceptable long-term. B is current, but it is a personal fork branch (`jgiannuzzi/go-sqlite3@sqlite3mc-2.2.7`) pinned by `replace`. Alternatives worth weighing: vendoring SQLite3MultipleCiphers or SQLCipher ourselves behind `mattn/go-sqlite3` with `-tags libsqlite3` (needs the lib in the image), or Zetetic's commercial SQLCipher. Pin by commit and checksum whichever is chosen.
2. **The key must be in the DSN** (see §1). A ConnectHook-keyed build passes a fresh-DB test and fails on first reopen, so test with reopen. The raw key lives in a Go string we can't zero.
3. **`temp_store` is per-connection, and both builds default to file temp storage** (`SQLITE_TEMP_STORE=1`). Set the pragma in the hook, as done here, and also compile with `CGO_CFLAGS=-DSQLITE_TEMP_STORE=3` so memory is the only option (not tested here). The probe's workload never needed a temp spill, so the `temp_store` claim is configured and confirmed by `PRAGMA temp_store=2`, but not stress-tested with a large sort.
4. **whatsmeow stores decrypted plaintext in the store** (`whatsmeow_event_buffer.plaintext`, `whatsmeow_retry_buffer.plaintext`). It's covered by SQLCipher, but the review should know message bodies live there as well as in our tables. Retention is governed by `DeleteOldBufferedHashes`/`DeleteOldOutgoingEvents`, so call them. Freed pages keep old ciphertext until overwritten; consider `PRAGMA secure_delete=ON` (also not tested here).
5. **Not covered by this probe:** the container writable layer and image (needs the real accessory image), Docker log driver contents (needs a live client), and a real crash/core test (deliberately not run). The production smoke test in slice 4 should repeat this scan over `/data`, the tmpfs, `docker diff` of the container, and `docker logs`.
6. WAL/SHM headers leak page counts and timing (inherent to SQLCipher).
