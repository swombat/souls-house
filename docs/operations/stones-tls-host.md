# Host-only stone TLS renewal

This is the bounded **install + notify + manual Deploy Rails** route, not a
certificate-only proxy refresher. No script deploys a revision or restarts proxy.
It complements [stone-hosting.md](stone-hosting.md).

## Why not a proxy-only refresh?

Reviewed sources: Kamal 2.12.0 and kamal-proxy 0.9.2.
In proxy `internal/cmd/list.go:44-56` and
`internal/server/router.go:44-50`, list exposes only host, path, target, state and
TLS boolean, not service/target options or even distinct writer/reader targets.
`internal/server/commands.go:19-25,115-116` Deploy takes the complete config;
`internal/cmd/deploy.go:30-70` supplies defaults for omitted options.
There is no supported inspect/export/reapply interface. Rollout deploy preserves
options but only changes targets (`router.go:133-155`), not the certificate
manager. Static PEM is loaded into memory (`cert.go:22-31`,
`service.go:379-384`). Do not reconstruct options from list output, parse private
persisted state as a new API, or restart the shared proxy.

## Provision explicitly (no credentials in this repository)

1. Review and copy `ops/deploy/stones-tls.rb` (0644) and
   `ops/deploy/stones-tls-renew` (0755) into `/opt/house-deploy`. The existing
   trusted `tools_image` from `/etc/house-deploy/settings.json` must provide Ruby,
   stdlib OpenSSL and a current system CA store. The wrapper overrides its Kamal
   entrypoint with `ruby`; it does not need host Ruby.
2. Existing `/etc/house-deploy` and `/var/lib/house-deploy` must be root-only 0700,
   and `/etc/house-deploy/secrets` root-owned 0600. The installer never evaluates
   dotenv; unsupported syntax fails closed. The two owned entries must contain
   quoted literal multiline PEM. Other entries are preserved byte-for-byte.
3. Root-only `/etc/house-deploy/stones-tls` (0700) contains `porkbun.env` (0600),
   the already-issued production ACME state directory `production` (0700),
   and `notify-command` (0600, one absolute path to an operator-provisioned
   executable, no arguments). The executable receives **subject and fixed body**
   as two arguments and must return nonzero if delivery fails. Provision it
   root-owned, not group/world-writable, in a root-owned protected directory.
   The wrapper never reads tokens or creates notification credentials. The
    installation-specific `stones-notify.py` posts fixed maintenance notices to
    `erBWle` through Mira's separately provisioned scoped API token in root-only
    `notify.json` (0600). Copy it as 0755 to `/opt/house-deploy`, set that path in
    `notify-command`, and provision only the exact message endpoint as `url` and
    the token as `token`. Never commit this file's values. Rotation/revocation of
    Mira's token requires updating this host-only copy. Test delivery before scheduling; do not
   rely on this host's unreliable queued mail. No default email is assumed.
4. Production state mounts at `/acme.sh` for the reviewed pinned ACME 3.1.6
   image. The wrapper sources the root-only environment *inside* the container
   and uses `/acmebin/acme.sh --config-home /acme.sh`, preserving the script
   home and DNS plugin directory. Do not pass `--home /acme.sh`.
   Disable client upgrades (`AUTO_UPGRADE=0` and account state `AUTO_UPGRADE='0'`).
   No extra install/renew/reload hooks may execute deployment commands.
   Inputs are `production/*.soulstones.fyi_ecc/fullchain.cer` and
   `production/*.soulstones.fyi_ecc/*.soulstones.fyi.key` (literal `*` filenames,
    not shell globs). After renewal, trusted tools Ruby secures these two
    root-owned regular files to 0600 through open descriptors, rejecting final
    symlinks; the ACME client recreates the public chain with mode 0644.
    Installer independently requires both inputs 0600, including fullchain.
5. The wrapper's fixed probe is `tls-check.soulstones.fyi`; its wildcard DNS must
   point to the intended proxy. TLS handshake only: no stone publication needed.
6. Run the wrapper once explicitly. Confirm the "renewal READY" notice reaches
   the operator through the configured notifier; installed PEM is **not** a live refresh. Approve **Deploy Rails**
   separately (current master is released), then run again and externally verify
   the live certificate. Only then install root's daily cron:

   ```cron
   17 6 * * * root /opt/house-deploy/stones-tls-renew
   ```

   This line is for `/etc/cron.d/house-stones-tls`; root crontab omits `root`.
    The independent `Public stones TLS expiry` GitHub workflow verifies the live
    certificate without host credentials or the notifier. After activation set
    repository variable `STONES_MONITOR_DOMAIN=soulstones.fyi`, dispatch it once,
    and ensure the operator receives GitHub Actions failure notifications.
    A failed host/notifier can otherwise fail silently. This external check
    catches public expiry/connection failure, not every internal renewal error.
    Do not redirect cron's own errors or treat queued host mail as delivery.

## Behavior and recovery

The pinned ACME job runs without the deployment lock. A separate renewal lock
prevents overlapping jobs. Ruby takes the existing host `deployment.lock`
nonblockingly around preflight and the atomic secret replacement; contention
alerts and retries next run. Do not remove or replace a held lock inode.
Preflight checks unencrypted private key, key match, explicit wildcard SAN,
validity (at least one day), PEM chain syntax and system-store chain trust.
The complete replacement file is fsynced then renamed in the same directory.
The previous **pair only** is fsynced to `secrets.stones-previous` (0600) before
replacement. A no-op does not overwrite that rollback pair.

Each run checks installed and served TLS even if ACME fails. It verifies public
TLS trust/hostname, exact leaf match and more than 21 days remaining. Pending
refresh, expiry, network failure or renewal failure notices repeat daily. The
changed install additionally sends the explicit manual-release notification.
No logs/notices include PEM, keys, environment or captured child-process output.
Notification failures cause a nonzero cron exit; independently monitor the
cron's exit/heartbeat, since a broken notifier cannot alert through itself.
Stdout retains `installed` / `unchanged` status without secrets, including when
the success notification fails. A missing or malformed notifier fails before
any ACME operation.

For rollback, merge only the two retained entries back into the current secrets
under `deployment.lock` using a reviewed atomic replacement; do **not** overwrite
unrelated current secrets with an old whole-file backup. Then explicitly approve
Deploy Rails and verify live TLS. Retained expired certificates are not safe
rollback candidates. No automatic rollback or release approval is implemented.

Local tests (no Rails, production, credentials, or external network):

```sh
ruby test/stones_tls_host_test.rb
python3 test/stones_tls_renew_test.py
```
