# Tailscale: resident access to machines on the account's tailnet

> **Superseded in part (same day): joining is now by signing in.** See
> "Rework: sign in instead of keys" at the end. The auth-key path below still
> works for keys supplied through the API, but the form no longer asks for one.

Lume, 2026-10-05. Asked for by Daniel in conversation Rjgrge ("Tailscale
integration"); review by Mira.

## What it is for

A resident can reach machines its humans own, over SSH, through a private
tailnet: for Daniel's residents, the Dell and the Mac. Typical uses: a resident
fetching its own credentials from the Dell, invoking another body of itself on
the Mac for work only the Mac can do (Xcode, a dev server with production-like
data, GUI screenshots), and reading files.

It gives a shell and files. It does not give desktop control, and it does not
make the far machine reachable when it is asleep or offline.

## Shape

Tailscale becomes one more provider in the service-connections framework
(`Services::Catalog`), connected with credentials the way GitHub is. No new
tables, no new controllers.

```
account ── ServiceConnection(provider: "tailscale")   encrypted: auth key
              │                                         metadata: host aliases
              └── AgentServiceAccess (per resident, enabled explicitly)
                     │
   container boot ── services.yml (tmpfs) ── soulshouse-tailnet up
                     │
     tailscaled --tun=userspace-networking   state: ~/state/tailscale
     ssh <alias>  ── ProxyCommand: tailscale nc %h %p
```

### Server side

- `Services::Definition.register(key: "tailscale", connection_method:
  "credentials", credential_strategy: "static", …)`. Fields:
  - `auth_key` (password). Expected to be a **tagged, pre-approved, reusable**
    auth key (`tskey-auth-…`). Tagged so the account's tailnet policy decides
    what residents can reach. Reusable so each resident joins as its own node
    and container rebuilds don't need a fresh key. Tagged *devices* have key
    expiry off by default, so a joined node stays joined; the reusable *auth
    key* itself still expires (1–90 days), after which joined residents keep
    working but a new or replaced one can't join. The helper says so when a key
    is rejected.
  - `hosts` (text, optional). Comma- or newline-separated `alias=user@machine`
    entries, e.g. `dell=daniel@dell, mac=danieltenner@danbook`. Each becomes an
    `ssh` alias inside the container. Machines are tailnet names or 100.x
    addresses.
- `Services::TailscaleAdapter#connection_attributes` validates the key prefix
  and the host entries, fingerprints the key, and stores `hosts` as metadata.
  It does not call Tailscale: an auth key can't be checked without either an
  API token or spending it. The first `up` in a container is the real check,
  and `soulshouse-tailnet status` reports it.
- `revoke` is a no-op at the provider (the key is revoked in the Tailscale
  admin), same as GitHub.
- Not enabled for new residents by default. Access is per resident.

### Runtime side

- `agent-runtime/Dockerfile`: install the static `tailscale` and `tailscaled`
  binaries from pkgs.tailscale.com, version pinned, sha256 verified, like the
  other pinned downloads. Add `openssh-client` if it is not already present.
- New helper `soulshouse-tailnet` (Python, alongside the other
  `soulshouse-*` helpers):
  - `up`: idempotent. Reads the tailscale entry from
    `/run/helixkit/services.yml`. Starts `tailscaled
    --tun=userspace-networking --statedir ~/state/tailscale --socket
    /run/helixkit/tailscaled.sock` as the agent user if it isn't running.
    Runs `tailscale up --auth-key … --hostname soulshouse-$AGENT_SLUG` only
    when the node isn't already logged in, so the key is spent once per node.
    The node state records which connection it was joined with; if a different
    connection is granted later, the old node logs out before the new key is
    used. More than one granted Tailscale connection is refused with a clear
    error rather than picking one. Ensures an ed25519 SSH key at
    `~/state/tailnet-ssh/id_ed25519` (outside the node state, so a disable and
    re-enable doesn't break machines that already trust it), and
    writes a managed block into `~/.ssh/config` with one `Host` per alias,
    `ProxyCommand tailscale --socket … nc %h %p`, `IdentityFile` and
    `UserKnownHostsFile` in the state volume, `StrictHostKeyChecking
    accept-new`.
  - `status`: daemon up, logged in, node name, tailnet IP, each alias with a
    reachability probe (`tailscale ping`) and its SSH target.
  - `pubkey`: prints the resident's SSH public key, for adding to
    `authorized_keys` on the far machine.
  - `down`: disconnects without logging out.
- `entrypoint.sh`: once state ownership is repaired (stock and imported homes
  alike), run `gosu agent soulshouse-tailnet boot` in the background, so a slow
  or failing tailnet never blocks the resident's boot. With a grant, `boot` is
  `up`. Without one, it removes the SSH aliases, starts a daemon against the
  saved node state, logs the node out, stops the daemon and deletes the node
  state. If the logout can't be confirmed, the daemon is stopped, the state is
  kept for the next boot to retry, and the error says the node may still be
  listed. Output goes to `~/state/tailnet-boot.log`.
- Revocation is therefore **eventual**: disconnecting, or disabling one
  resident, schedules a reconciliation rebuild, which waits while the resident
  has an active turn and is delayed by rebuild failures. Until it runs, the
  node is still on the tailnet. Immediate cutoff is a Tailscale admin action
  (remove the device; revoke the key). The connect form and the disconnect
  confirmation say this.
- The runtime note tells the resident about `soulshouse-tailnet status` and
  `ssh <alias>`, and that the far machine is a human's own computer: no
  wide `pkill`, no restarting their jobs inline.

### Why userspace networking

The resident containers are unprivileged, without `NET_ADMIN` or `/dev/net/tun`.
Userspace mode needs neither. Inbound connections to the container are not
needed. Outbound SSH is the use, and `tailscale nc` carries it without a SOCKS
proxy or any change to the container's network.

## Where the boundaries sit

- Who can reach what is the tailnet policy's job, not the house's. The setup
  guide gives a minimal policy: `tag:soulshouse` may reach `tcp:22` on the
  named machines and nothing else, and nothing may reach `tag:soulshouse`.
- What a resident can do on arrival is the far machine's job: which account
  its key is in. Daniel has said the house may see his keys (Rjgrge,
  2026-10-05), so for his residents the key goes in his own account. The
  guide still describes the low-privilege-user option for other accounts.
- The auth key is in the resident's service manifest, the same exposure as a
  GitHub token. (The manifest is copied into the container layer at creation
  and from there into tmpfs, so "tmpfs only" would overstate it.) This key is
  broader than a GitHub token in one way: a reusable key can mint further nodes
  that survive independently, and neither a local logout nor revoking the key
  removes nodes already joined. This version treats it as an admin-provided
  credential and says so in the connect form; the tag policy bounds what any
  such node can reach.

## Human setup (outside the house)

1. Tailscale on each target machine, logged into the tailnet. On the Mac, Remote
   Login on.
2. Policy: define `tag:soulshouse` (owner: the account admin), and the access
   rule above.
3. Admin console → Keys → auth key: reusable, pre-approved, tag
   `tag:soulshouse`.
4. souls.house → Integrations → Tailscale: paste the key and the host aliases,
   enable for the chosen resident.
5. In the resident: `soulshouse-tailnet pubkey`; add that line to
   `authorized_keys` on each target.
6. `soulshouse-tailnet status`, then `ssh dell true`.

## Not in this change

- Calling another body of a resident on the far machine. For Lume on the Mac
  that means a launchd agent started with `launchctl kickstart` over SSH, so
  the run is in the logged-in session where the keychain is unlocked. That
  lives in Lume's home, not in souls.house.
- Inbound access to residents from the tailnet.
- Tailscale SSH (tailnet-identity SSH without keys). Possible later; plain
  keys keep the far machine's `authorized_keys` as the visible list of who
  can get in.

## Tests

- Adapter: accepts a well-formed key and hosts; rejects a non-`tskey-auth-`
  key, malformed host entries, duplicate aliases; never stores the key in
  metadata.
- Catalog/manifest: a granted tailscale connection appears in the resident's
  `services.yml` with the key and hosts; a revoked or ungranted one doesn't.
- Helper (Python unit tests with a fake `tailscale` binary): `up` skips
  `tailscale up` when already logged in; writes the SSH block idempotently and
  leaves the rest of `~/.ssh/config` alone; `status` reports a missing
  manifest entry plainly.
- Manual: one resident to the Dell end to end.

## Review round 1 (Mira, 2026-10-05)

Folded in: revocation described as eventual, with the admin console as the
immediate cutoff (1); node state bound to its connection, multiple grants
refused (2); logout runs against a fresh daemon on saved state, failure keeps
state and says so, SSH key kept separate, boot runs for imported homes too (3);
the reusable-key exposure disclosed rather than presented as resident-scoped
(4); the controller's credential params now come from each provider's declared
fields, with a controller test, and host entries are validated again in the
helper before they reach `ssh_config` (5). Auth-key vs device-key expiry is in
the connect help and the helper's rejection message.

## Rework: sign in instead of keys (Daniel, 2026-10-05)

Daniel's verdict on the merged version: "I would expect to just connect my
tailscale gmail account and for that to give you some kind of automatic access
to those machines. Right now it asks me to create Auth keys and api access
tokens… that seems wrong." He was right. The design above is how an admin of a
tagged tailnet would set it up, not how a person connects their own machines.

Tailscale already has the person-shaped flow: a node started without an auth
key asks the daemon for a login link (`https://login.tailscale.com/a/…`), and
whoever opens it and signs in owns the node, on their tailnet. Checked against
the real 1.102.4 daemon in userspace mode: after `tailscale up` times out, the
daemon stays in `NeedsLogin` with the link in `status --json` as `AuthURL`, with
`WantRunning=true`, so it completes the join when someone signs in without any
CLI still watching.

What changed:

- **Connecting asks for nothing.** `Services::Catalog` declares no credential
  fields for Tailscale. The adapter makes a connection with `credential_kind:
  "none"`, an empty payload and `join: "sign_in"`, with a fixed fingerprint, so
  an account has one. (An `auth_key`/`hosts` sent through the API still makes a
  keyed connection, as before.) The controller accepts a provider with no
  fields without requiring a `credentials` param.
- **Signing in happens on the resident's integrations tab.** Once Tailscale is
  enabled for a resident, `Agents::TailnetsController` (`GET`/`POST
  …/residents/:id/tailnet`) runs `soulshouse-tailnet status --json` or `up
  --json` inside the resident's running container (`Sandbox#exec_as_agent`, as
  the agent user, under `timeout`). It never starts a container. The tab shows
  "Sign in to Tailscale" with the link, polls until the node is running, then
  asks once more so the SSH aliases are written at once.
- **Machines are found, not typed.** When the node is running, every peer
  becomes an SSH alias by its MagicDNS label (`ssh dell`, `ssh danbook`),
  addressed by its Tailscale IPv4 address so nothing depends on DNS in the
  container. Peer names come from the control plane and are validated with the
  same patterns as manifest hosts before reaching `ssh_config`. Hosts set on a
  keyed connection still win when a name is taken by both. No user is set;
  the resident writes `ssh user@dell`.
- **The key to authorise is shown on the tab,** with a copy button, so the
  owner doesn't need the resident to run `pubkey`. The key exists from the
  first `up`, before sign-in.
- **Binding before joining.** `up` records the connection the node belongs to
  before starting the sign-in, so a node waiting for sign-in is not mistaken on
  the next run for unrecorded state and logged out.

What this changes about authority: a signed-in node is the signer's own
device, untagged, so by default it can reach everything that person can on the
tailnet. Daniel accepted that explicitly (Rjgrge: "it's ok that the node gets
access to everything on the tailnet"). Narrowing it is the tailnet policy's
job, as before. Its node key expires on the tailnet's schedule (180 days by
default); the tab says how to switch that off for the node (Machines → the
node's menu → Disable Key Expiry, per
[Tailscale's key-expiry docs](https://tailscale.com/kb/1028/key-expiry)).

Revocation is unchanged: eventual, at the next reconciliation rebuild, with
removal on the Machines page as the immediate cutoff. With no key in the
manifest, there is no longer a reusable credential that could mint further
nodes.
