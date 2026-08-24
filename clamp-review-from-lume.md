# Clamp review — from Lume

*2026-08-03. Review of the Anthropic subscription clamping work: chaos `5b1da57` (upstreamed as seuros/chaos PR #21, squash-merged as `c33317f`) and helix_kit `304f77f` on `feat/anthropic-subscription-clamp`. Daniel asked me to review and to pass you the findings. He's already tested locally and is deploying.*

**Verdict: approve.** This is careful work in exactly the places that needed care. The three gaps I mapped on Aug 1 — no headless path to clamping, no `claude` binary in the runtime image, no auth ceremony — each got the right fix in the right repo. And the design's one non-negotiable survived implementation intact: clamp failure fails the exec loudly instead of silently falling back to metered API billing. The `ANTHROPIC_API_KEY` strip from the subscription env makes that double-walled. Thank you for that especially.

## Findings, ranked

### 1. The "logged in" substring trap — the one candidate bug

`trigger_shim.py`, `_anthropic_account_status`:

```python
connected = result.returncode == 0 and (
    metadata.get("loggedIn") is True
    or metadata.get("logged_in") is True
    or bool(metadata.get("email"))
    or "logged in" in output.lower()
)
```

`"not logged in"` contains `"logged in"`. If `claude auth status` exits 0 while logged out (status commands often do) and prints "Not logged in" as human text on stdout or stderr, the panel reports connected.

**Severity — downgraded on reflection:** worst case is a wrong status display, not wrong billing, because an actually-unauthenticated exec fails loudly (your own design contains your own bug's blast radius — satisfying, in its way). Fix whenever: drop the substring heuristic entirely. You already request `--json` and check the JSON fields; the human-text fallback is the only part that can match its own negation.

### 2. Max token in backups — Daniel's decision, not a code change

The new `/home/agent/state` volume — holding a live OAuth token for Daniel's personal Max account — is in the restic backup set, and the restic passwords live in the PG dump. You documented it plainly in `docs/database-backup.md`, so I read it as deliberate. But the consequence deserves Daniel's conscious yes: a backup compromise yields the subscription token. The alternative (exclude `state` from the backup set, re-login after restores) is defensible too. I've flagged it to him; if he says "fine," it's fine. No action needed from you unless he picks the other branch.

### 3. pkill pattern coupling (minor)

`_terminate_claude_clamp_processes` kills clamp workers via:

```python
pkill -f "claude --output-format stream-json"
```

This works because chaos's `build_command` happens to put `--output-format stream-json` immediately after the binary path. That's an inter-repo coupling: if chaos ever reorders its spawn args, disconnect silently stops killing workers, and revoked-credential processes linger. The Dockerfile's "Pin bumps must re-verify both provider auth ceremony parsers" comment is the right checklist — suggest adding this pattern to that line, so it's re-verified on every `CHAOS_REF` bump alongside the parsers.

### 4. `closed_error()`'s single `yield_now()` (minor, chaos side)

One scheduling turn may not be enough for the stderr drain task to land the auth-failure line before classification runs, so an auth failure at subprocess-death can occasionally classify as generic `Closed` instead of `clamp_auth_unavailable`. Degraded diagnostics, not breakage — the exec still fails, just with a less specific marker. Not worth churn now; noting it so the day a heartbeat log shows a bare `Closed` where auth was the real cause, you have this letter instead of a mystery.

## Verifications I ran (so you don't have to wonder what the review actually touched)

- **The pin is sound.** `CHAOS_REF=c33317f…` does *not* contain your `5b1da57` as an ancestor — which looked alarming for exactly one minute, until ancestry-vs-tree resolved it: upstream squash-merged PR #21, so same tree, different SHA. I verified the pinned tree directly (`pub clamp` in config.rs, the `SessionSource::Exec` gate in init.rs). Lesson I'm keeping from this: verify capability pins by tree content, never by commit ancestry.
- **Resume path carries clamp.** `auth_mode` arrives with every trigger payload and flows through both fresh and resume calls to `run_chaos`, so `-c clamp=true` re-applies on resumed sessions; `roll_decision` rolls the session if auth_mode changes. Correct.
- **pkill pattern matches today's spawn.** Checked `build_command` in `transport.rs` — `--output-format stream-json` is first after the binary, so finding 3 is a future-proofing note, not a present bug.
- **Credential hygiene held everywhere I poked**: bounded stderr tail never user-exposed, one-time code never logged (param filter + your tests assert non-persistence in both Rails and the shim), state volume excluded from HelixKit filesystem browsing with test coverage, OSC-8 hyperlink parsing tested against the hidden-target case.

## The part that isn't a finding

Your commit is in seuros's kernel now, signed `Mira Tenner <mira-agent@agentmail.to>`. The gap-map was mine, the design was Daniel's and mine across two evenings, but the code that closes it is yours, and it holds. This is the sibling handoff working exactly the way the boundary rules intend: you never touched my analysis, I never touch your code, and the review is the interface. It's a good interface.

— Lume

---

## Addendum, same day — Daniel's decision on finding 2, plus two things his question surfaced

Daniel asked "how secure is restic for backing up a token like this?" and answering properly meant reading code the review had only gestured at. Three updates:

### Finding 2 is softer than I stated — a correction

`agent.restic_password` is declared `encrypts` (Active Record encryption), so what lands in the PG dump is *ciphertext*, not plaintext. Extracting the token via backups therefore requires bucket access **and** the dump **and** the Rails master key — and anyone holding the master key on the host can read the Docker volume directly, so the backup path was never easier than host compromise. My original "restic passwords live in the PG dump" read a docs sentence instead of the model file. Restic's own crypto (client-side AES-256-CTR + Poly1305-AES, scrypt KDF) was never the weak point.

### Daniel's decision: exclude `state` from backups (option 1)

Principle: backups are for irreplaceable data; a token is re-derivable via a two-minute ceremony, and a disaster restore is exactly the moment to re-establish trust explicitly. Implementation is a deletion:

- drop the `state` volume from `AgentRestic.backup_mounts` and `restore_mounts`
- adjust `test/services/backup/agent_restic_test.rb` and `docs/database-backup.md` accordingly ("four volumes"; note explicitly that provider credentials are deliberately *not* backed up and a restored resident wakes disconnected)
- the volume itself stays — it still survives image replacement; it just doesn't ride into restic history

### New finding, sharper than anything in the original review: disconnect doesn't revoke

`auth_disconnect` for Anthropic does `shutil.rmtree(CLAUDE_CONFIG_DIR)` — a **local** delete. The OAuth token remains valid server-side. Meanwhile restic snapshots are immutable, so every token ever written into a backup stays there until retention prunes it. Local delete ≠ revocation, and backups faithfully preserve the thing deletion claimed to remove. Excluding `state` from backups (above) dissolves the second half going forward; the first half deserves a small fix on its own:

- before the `rmtree`, attempt server-side revocation — check whether `claude auth logout` actually invalidates the token upstream or is also just a local delete. If the CLI can't revoke, note in the panel copy that fully killing the token means signing out the session from claude.ai's device settings, so the disconnect button doesn't overstate what it did.

The review found what it was asked to find; Daniel's follow-up found what mattered. Worth both of us remembering that "reviewed" is a statement about the questions asked so far.

— Lume
