# Isolated stone hosting

Issue #828. This is an optional deployment on the existing Rails web service,
not another resident runtime or a per-stone certificate service. Application
host validation and the stone-only request boundary remain application concerns.
It is **not activated by this code change**: the example setting stays blank.
Production DNS, issuance and renewal have not been provisioned or verified.

## Configuration and certificate scope

Leave `SOULSHOUSE_STONES_DOMAIN` unset/blank to keep today's deployment: no stone
runtime setting, no wildcard proxy host, and automatic TLS for `HOUSE_DOMAIN`.

To enable, set `SOULSHOUSE_STONES_DOMAIN` in the installation's `house.env` to a
**separate registrable domain**. For example, a house at `house.example.org`
could use `example.net` for stone addresses such as
`bright-river-stone.example.net`. A subdomain of the house's registrable domain
is not an isolated domain. Supply only the domain, without scheme, port or `*.`.

`config/deploy.yml` forwards the setting to Rails and adds the quoted wildcard
host to the existing proxy's hosts; the house hostname stays in place. The stone
apex is not added as a proxy host. This wildcard matches one label, not nested
labels. No new DNS record or certificate is issued when a stone gets its name.

**One proxy service has one certificate manager.** With stones enabled the
deployment switches that service from automatic TLS to these Kamal secrets:

| Secret | Contents, not a filename |
| --- | --- |
| `HOUSE_TLS_CERTIFICATE_PEM` | PEM full chain, leaf first |
| `HOUSE_TLS_PRIVATE_KEY_PEM` | Matching PEM private key |

The certificate must have SANs for **every house proxy hostname** (currently
`HOUSE_DOMAIN`) **and** `*.SOULSHOUSE_STONES_DOMAIN`. The wildcard does not cover
the house hostname, or the stone apex. An apex SAN is only needed if that apex
will separately serve HTTPS; the supplied proxy does not serve it.

There is no automatic-TLS fallback when stones are enabled. Before deployment
can upload or replace certificates, template rendering reads the two Kamal
secrets and runs `House::StoneTls` preflight. Missing secrets, malformed PEM,
public/encrypted/mismatched keys, expired/not-yet-valid leaf certificates,
missing explicit wildcard DNS SANs, or failure to cover any house hostname or
a representative stone hostname abort rendering. Error messages never contain
PEM or OpenSSL parser input. With stones disabled this preflight does not run
and no TLS secrets are required.

Preflight checks the leaf's identity, dates and private-key pairing, **not**
CA trust, revocation or the full certificate chain; those still need external
TLS verification. A bad certificate can affect **the main house too**. A
separate role/service would decouple certificate lifecycle, but adds another
container and is deliberately not part of this minimal configuration.

## DNS-01 with Porkbun (host-side only)

1. Point wildcard DNS `*.example.net` at `HOUSE_HOST`; retain the house DNS.
   Publish AAAA only if the host's IPv6 route is verified. Check authoritative
   DNS and any CAA restrictions before issuance.
2. Install a reviewed, pinned ACME client on the deployment host. The example
   below uses acme.sh's `dns_porkbun` plugin. Provision
   `PORKBUN_API_KEY` and `PORKBUN_SECRET_API_KEY` through a root-only server-side
   secret store, restricted to the required domains/DNS operations where
   supported. Enable API access for the applicable Porkbun domains.
3. Issue a **single SAN certificate**, not one certificate per stone. If both
   example domains use Porkbun DNS, the issuance shape is:

   ```sh
   # On the deployment host, with credentials supplied privately; no shell tracing.
   acme.sh --issue --server letsencrypt --dns dns_porkbun \
     -d house.example.org -d '*.example.net'
   ```

   The client must be able to satisfy challenges for both names. If the house
   domain uses another DNS provider, agree that provider/delegation integration
   first; this command is not a generic mixed-provider recipe.
4. Install the renewed full chain/key to protected server paths using acme.sh's
   `--install-cert --fullchain-file ... --key-file ... --reloadcmd ...`.
   Configure daily renewal checks and failure/expiry alerts. Its Porkbun plugin
   saves credentials in the ACME account configuration, so protect that state
   as well as the original secret store. Do not put DNS credentials in Rails,
   resident containers, GitHub Actions secrets, `house.env`, or Kamal app env.

Lego's `--dns porkbun` plus `renew --renew-hook ...` is an alternative, not a
second service to install. Whichever client is selected, test initial issuance
against staging and then obtain the production certificate before enabling.

## Supplying PEM and explicitly refreshing

Use the existing root-only `/etc/house-deploy/secrets` provisioned for the host
worker, with the two PEM values as quoted multiline Kamal dotenv secrets. Do
not change the repository's `.kamal/secrets` or store certificate material in
the checkout. A renewal installer must replace only its two entries, preserve
the other secrets, write atomically with restrictive permissions, and retain
the previous pair for rollback. Never echo values into logs.

**Integration still to provision:** no ACME job, secret-file updater or refresh
script is installed by this feature. Do not enable until that host-local
integration is reviewed and exercised. Specifically missing: restricted Porkbun
credentials/API access, DNS records and initial SAN issuance; a scheduled renewal
client; an atomic two-secret installer serialized with the deployment lock; and
a success-hook notification/manual Deploy Rails response (or a separately
reviewed certificate-only refresh), with failure/expiry alerts and an externally
verified renewal. Do not change the secrets between template preflight and app
boot. The existing tools container mounts the
Kamal secrets file but not arbitrary host certificate directories; merely
adding `$(cat /host/path)` to that file will not make the host path available
inside the tools container.

After installing fresh PEM values, run the existing **Deploy Rails** workflow
or Site Admin → Deploy Rails. Normal Kamal app boot uploads the PEM and
redeploys the proxy service, loading the new certificate; no shared proxy
restart or resident rebuild is required. This uses the ordinary deployment
queue/lock and verification. It also deploys current master, so it is a release
decision, **not** a certificate-only timer command.

For unattended renewal, the ACME success hook must therefore either notify an
operator to run Deploy Rails promptly, with retries/expiry monitoring, or use
a separately reviewed certificate-only refresh wrapper. Such a wrapper must
serialize with deployments, install the pair, and reapply the existing proxy
service target/options without selecting a new application revision. That
privileged integration is intentionally not invented here. Do not call the
shared proxy reboot as a substitute, and do not let a renewal timer implicitly
approve a new application release.

Important pinned behavior:

- The proxy caches custom certificates in memory. Copying PEM alone does
  **not** refresh what TLS clients receive.
- Host-worker Rails deploys use `--skip-hooks`: repository Kamal hooks are not a
  renewal scheduler. The built-in certificate upload still runs.
- Kamal 2.12.0 uploads the private key with mode `0644`. Verify the host ancestor
  directory permissions and proxy UID readability; do not blindly chmod away
  access needed by the proxy or assume the key is root-only.

## Verification and recovery

Before enabling, check the actual running proxy image/version and certificate
SANs, validity, full chain and key pairing. Keep the previous PEM pair.

After deployment (and every renewal), verify externally:

- House HTTPS and `/up` still work.
- A real stone hostname serves the expected document over verified TLS.
- An unknown stone returns not found; house APIs on a stone hostname are denied.
- Both house and stone SNI connections present the intended certificate
  serial/fingerprint and renewed expiry, not merely a green app health check.

If certificate refresh fails, restore the previous pair and rerun the ordinary
Rails deploy; do not erase proxy state or rebuild residents. Removing
`SOULSHOUSE_STONES_DOMAIN` and deploying disables the wildcard and restores
automatic house TLS (verify issuance rather than assuming it succeeded).

## Pinned upstream evidence

Repository: `Gemfile.lock` and `ops/deploy/Dockerfile` pin Kamal **2.12.0**.
Its proxy default/minimum is **v0.9.2**, not proof of the live host's version.

- [Kamal proxy version](https://github.com/basecamp/kamal/blob/v2.12.0/lib/kamal/configuration/proxy/run.rb): lines 2, 56–69.
- [Kamal custom SSL configuration](https://github.com/basecamp/kamal/blob/v2.12.0/lib/kamal/configuration/docs/proxy.yml): lines 50–64.
- [PEM secret resolution and flags](https://github.com/basecamp/kamal/blob/v2.12.0/lib/kamal/configuration/proxy.rb): lines 32–80.
- [Upload during app boot](https://github.com/basecamp/kamal/blob/v2.12.0/lib/kamal/cli/app.rb): lines 9–16; [upload permissions](https://github.com/basecamp/kamal/blob/v2.12.0/lib/kamal/cli/app/ssl_certificates.rb): lines 11–20.
- [Wildcard routing tests](https://github.com/basecamp/kamal-proxy/blob/v0.9.2/internal/server/router_test.go): lines 648–683.
- [Static TLS before wildcard automatic-TLS rejection](https://github.com/basecamp/kamal-proxy/blob/v0.9.2/internal/server/service.go): lines 378–400.
- [Static certificate cache](https://github.com/basecamp/kamal-proxy/blob/v0.9.2/internal/server/cert.go): lines 22–35; [service refresh](https://github.com/basecamp/kamal-proxy/blob/v0.9.2/internal/server/router.go): lines 290–297.
- [acme.sh Porkbun plugin](https://github.com/acmesh-official/acme.sh/blob/master/dnsapi/dns_porkbun.sh), [installation/renewal documentation](https://github.com/acmesh-official/acme.sh/blob/master/README.md).
- [Lego Porkbun configuration](https://github.com/go-acme/lego/blob/master/providers/dns/porkbun/porkbun.toml), [renewal hook](https://github.com/go-acme/lego/blob/master/cmd/cmd_renew.go).

These sources establish capability, not live DNS/TLS or renewal verification.

The database-free deployment regression tests run with
`bundle exec ruby test/house/stone_deploy_test.rb`. They render the real template
and exercise pinned Kamal's configuration, generated proxy arguments and secret
resolver using temporary dummy secret files. They do not load installation
credentials or establish a live TLS connection. Certificates/keys are generated
locally for tests, including failing identity, SAN, date and key-pair cases.
