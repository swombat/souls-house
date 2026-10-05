# Tailscale: resident access to machines on the account's tailnet

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
    and container rebuilds don't need a fresh key. Tagged nodes have key expiry
    off by default, so a joined node stays joined.
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
    Ensures an ed25519 SSH key at `~/state/tailscale/ssh/id_ed25519`, and
    writes a managed block into `~/.ssh/config` with one `Host` per alias,
    `ProxyCommand tailscale --socket … nc %h %p`, `IdentityFile` and
    `UserKnownHostsFile` in the state volume, `StrictHostKeyChecking
    accept-new`.
  - `status`: daemon up, logged in, node name, tailnet IP, each alias with a
    reachability probe (`tailscale ping`) and its SSH target.
  - `pubkey`: prints the resident's SSH public key, for adding to
    `authorized_keys` on the far machine.
  - `down`: disconnects without logging out.
- `entrypoint.sh`: after `services.yml` is copied, if it contains a tailscale
  entry, run `gosu agent soulshouse-tailnet up` in the background, so a slow
  or failing tailnet never blocks the resident's boot. If it contains no
  tailscale entry but `~/state/tailscale` holds a node, log the node out and
  remove its state. That makes disconnecting the integration, or disabling it
  for one resident, take the node off the tailnet at the next reconciliation
  rebuild rather than leaving it joined.
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
- The auth key sits in the resident's tmpfs manifest, the same exposure as a
  GitHub token. A resident holding it could join more nodes under the same
  tag. The tag policy bounds what those nodes could reach.

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
