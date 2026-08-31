# souls.house Rebrand Plan

**Status:** draft for review — 2026-07-31
**Domain:** `souls.house` (registered at Porkbun)
**Strategy:** external rebrand first (Phase 1), internal rename later (Phase 2). Mailgun is leaving with GT, so mail migration is part of Phase 1.

---

## Phase 0 — Decisions needed before starting

### 0.1 Mail provider (decide now — Mailgun is going away regardless of rebrand)

Current state: `config/environments/production.rb` gates all mail delivery on
`credentials.mailgun` and uses plain SMTP settings. Swapping providers = new
credentials block + from-address. No code surgery.

Volume reality check: souls.house sends password resets, email confirmations,
and the odd notification to a handful of humans. We are talking **tens of
emails per month**, not thousands.

**Option A — Free-tier SMTP provider (recommended)**

| Provider | Free tier | Notes |
|----------|-----------|-------|
| Brevo (ex-Sendinblue) | 300/day | Generous, SMTP creds, custom domain + DKIM |
| SMTP2GO | 1,000/month | Simple, good deliverability reputation |
| Resend | 3,000/month (100/day) | Modern, dev-friendly, SMTP interface available |
| Mailjet | 200/day | Fine, slightly clunkier dashboard |

- Cost: **$0** at our volume, indefinitely.
- Deliverability: their problem, and they're good at it.
- Work: sign up, verify `souls.house` (add SPF/DKIM records at Porkbun),
  paste SMTP creds into Rails credentials. ~30 minutes.
- Risk: free tiers can shrink (Mailgun's did). Mitigation: the config is
  provider-agnostic SMTP — switching again later is the same 30 minutes.

**Option B — Self-hosted mailer (docker image as Kamal accessory)**

e.g. `boky/postfix` (simple outbound relay, DKIM support) or
`docker-mailserver` (full mail stack — overkill, we only send).

- Cost: $0, fully sovereign, no third party.
- **Blocker 1: Hetzner blocks outbound port 25 by default.** You must request
  unblocking via support; they typically only grant it after the account is a
  month old and want justification. Until granted, a local mailer cannot
  deliver to the outside world at all.
- **Blocker 2: IP reputation.** Hetzner ranges appear on blocklists
  (UCEPROTECT etc.). Even with perfect rDNS + SPF + DKIM + DMARC, odds are
  meaningful that password resets land in spam — and a password reset in spam
  is the worst email to lose.
- Work: request port 25 unblock, set rDNS for 95.217.118.47 → souls.house,
  add accessory to deploy.yml, generate DKIM keys, publish DNS records,
  monitor blocklists. Hours up front, ongoing vigilance.

**Recommendation: Option A (Brevo or SMTP2GO).** Same price ($0), a fraction
of the work, and deliverability that just works. Option B stays documented
here as the sovereignty fallback if free tiers ever dry up — and if we ever
go there, the sensible shape is a postfix accessory *relaying through* a
provider anyway, which defeats the point. Decide: **[ ] A  [ ] B**

### 0.2 From-address

Suggest `hello@souls.house` for outbound, or `mail@souls.house`.
Decide: `____________@souls.house`

### 0.3 Site name styling

"souls.house" lowercase-as-wordmark? "Souls House"? "Souls.House"?
This string goes into `Setting.site_name`, page titles, and the 48 currently
hardcoded frontend strings. Decide: `____________`

---

## Phase 1 — External rebrand

Order matters: DNS first (it propagates while we work), deploy last.

### Step 1.1 — DNS at Porkbun ✅ 2026-08-01
- [x] `A` record: `souls.house` → `95.217.118.47` — had to delete Porkbun's
      two hidden "masked" parking records first (apex ALIAS + wildcard CNAME
      to pixie-parking.porkbun.com), which silently blocked apex A creation
- [ ] (optional) `A` record: `www.souls.house` → `95.217.118.47`
- [x] Verified at authoritative NS (`dig @curitiba.ns.porkbun.com`)

### Step 1.2 — Mail provider setup ✅ 2026-08-01 (Brevo)
- [x] Brevo account (Swombat Limited), `souls.house` added as sending domain
- [x] All 7 records live at Porkbun: brevo-code TXT, DKIM1+2 CNAMEs,
      DMARC (`p=none`), branded-link CNAMEs (mail / r.mail / img.mail)
- [x] Domain verified + authenticated + branded in Brevo (tracked links
      use mail.souls.house)
- [x] Sender `souls.house <hello@souls.house>` created + verified in Brevo
- [x] SMTP key `souls-house-production` generated (expires Aug 2027 — and
      after 90 days of *inactivity*, so note if the app ever goes dormant)
- [x] Inbound: Porkbun email forwarding `hello@souls.house → daniel@swombat.io`
      (MX fwd1/fwd2.porkbun.com + SPF record auto-added by Porkbun)

### Step 1.3 — Rails mail config ✅ 2026-08-01 (uncommitted; ships with Phase 1 deploy)
- [x] `smtp:` block added to BOTH `config/credentials/development.yml.enc`
      and `config/credentials/production.yml.enc` (per-env credentials repo)
- [x] `production.rb`: mailgun gate → `credentials.smtp` gate;
      `default_url_options` host → souls.house; auth "login"
- [x] `application_mailer.rb`: from → `souls.house <hello@souls.house>`
- [x] Tested: raw SMTP (net/smtp, 250 queued) AND full ActionMailer send
      with `RAILS_ENV=production` → Brevo reports 4/4 delivered, 0 bounces
- Discovery: credentials had NO mailgun block — production mail was never
  actually configured, so there is no legacy behavior to preserve.

### Step 1.4 — Content rebrand ✅ 2026-08-01 (branch: `rebrand/souls-house`)
- [x] New `app/frontend/lib/branding.js` — `siteName` derived store reading
      the globally-shared `site_settings.site_name` Inertia prop, fallback
      `DEFAULT_SITE_NAME = 'souls.house'`. Brand governed in one place;
      admin renames propagate live via the existing broadcast.
- [x] All frontend prose routed through `{$siteName}` (agent panels, api
      keys, admin pages, birth flow, promote/edit/onboarding); literal
      "souls.house" only where a live setting would be wrong (admin
      placeholder, legal pages)
- [x] `setting.rb` default → "souls.house"; layout title → `Setting.
      instance.site_name`; PWA manifest; confirmation mailer (html+text);
      `agent.rb` error message; `chat/contextualizable.rb` prose;
      User-Agent headers + deploy-key title (web_tool, agent_repo_creator)
- [x] terms.svelte + privacy.svelte — REWRITTEN, not sed: they were
      template boilerplate referencing Oura Ring / health data (never true
      of this app). Now describe the actual service incl. agent-memory
      retention honesty clause. Entity name kept as "the operator of
      souls.house" — confirm if a legal entity should be named.
- [x] home.svelte — full rewrite: was still the HelixKit app-kit marketing
      page. Now presents souls.house (hero + six-concept grid + hearth
      link). `home-features.js` deleted (unused). FeatureGrid/FeatureCard
      reused.
- [x] README.md — rewritten: souls.house first, HelixKit as heritage
      section, dev docs (sync system, json_attributes) preserved
- [x] Verified: `vite build` passes; Rails boots; dev `Setting.instance`
      returns souls.house
- **Deliberately NOT swept (agent-facing prompt layer):** `app/lib/
  external_agent_*_request.rb`, `agent_identity_exporter.rb` — these are
  the wake/orientation/trigger prompts live agents receive, and they
  reference `helixkit-api.md` as a real filename in agents' identity
  volumes. Rebranding that prose changes what running agents read
  mid-rebrand and tangles with the Phase-2 script/file renames. Decide
  together: sweep the brand-name prose now (agents will cope; arguably
  they should hear the new name) or hold it for Phase 2 with the symlink
  dance. Also held: `helixkit:agent-birth-draft` localStorage key,
  `helixkit_app_url` field names, `helix-kit-agents` image name,
  generated js-routes comments.

### Step 1.5 — Logo + favicon ✅ 2026-08-01
- [x] Mark chosen by Daniel from 5 candidates: **B** (roof sheltering a
      warm coral orb — "a soul, housed") plus **C's move** (in the
      wordmark, the mark sits in the domain-dot position: souls⌂house).
      Geometry tightened after live screenshot review (flatter roof
      hugging the orb so it reads as one glyph, snug viewBox so the orb
      sits on the baseline). `app/assets/images/souls-house-logo.svg` —
      roof `currentColor`, orb fixed coral #f15d61.
- [x] `HelixLogo`/`HelixKitLogo` (identical duplicates) collapsed into
      `SiteLogo.svelte`; 8 importers updated; old components + old
      `helix-kit-logo.svg` removed
- [x] Favicon set derived via rsvg-convert + magick: favicon.svg/icon.svg
      (theme-aware via prefers-color-scheme), favicon.ico (16/32/48 with
      heavier small-size stroke), favicon.png 96, icon.png 512,
      apple-touch-icon.png 180 (mark on deep-teal night bg)
- [x] Homepage: hero rebuilt — wordmark lockup with mark-as-dot, night
      scene illustration (`souls-house-night.svg`, hand-built, works on
      both themes), relational copy, Sorting Hat effect link, trimmed
      concept cards. Verified by screenshot light+dark on dev server.
- [ ] (optional) Upload logo to `Setting#logo` attachment in admin

### Step 1.6 — Deploy cutover 🔄 2026-08-01 (deploy in flight)
- [x] `config/deploy.yml` proxy — plural `hosts:` dual-serving souls.house
      + helix-kit.granttree.co.uk (commit e684a9f)
- [x] DNS confirmed publicly (1.1.1.1 resolves souls.house → 95.217.118.47)
- [x] Homepage feature cards added pre-deploy per Daniel: subscription
      logins (OpenAI/Grok/Moonshot), any-substrate, coming-mnemodyne;
      memory card → narrative journal scaffold + link to
      how-to-build-an-artificial-person post
- [x] master fast-forwarded to cutover commit (via `git branch -f` —
      normal checkout blocked by the Home.svelte case-ghost on macOS;
      resolves itself on next clean checkout)
- [x] `kamal deploy` — clean, 166s, web+jobs healthy, agents untouched
- [x] Verified: https://souls.house 200 with Let's Encrypt cert (issued
      2026-08-01, valid to Oct 30), title "souls.house", favicon.svg
      serving, old domain still 200, homepage screenshot confirmed live

### Step 1.7 — Production data + smoke test ✅ 2026-08-01 (live password-reset email still worth one real send)
- [x] Production `Setting.instance.site_name` = "souls.house" (was already
      — row either freshly created with the new default or pre-set)
- [ ] Trigger a password-reset email from the live site to a real mailbox;
      confirm delivery, inbox placement, from-address, link host
      (Brevo pipeline already verified 4/4 delivered pre-deploy)
- [x] Daniel: logged in on souls.house, agents confirmed working
      ("I have successfully logged in :-) And the agents work!")

### Step 1.8 — Cleanup ✅ 2026-08-10
- [x] Remove `helix-kit.granttree.co.uk` from proxy hosts, redeploy
      (deploy clean 155s; old host now connection-refused, souls.house 200)
- [x] Production credentials `app.url` → https://souls.house — this fed
      Telegram webhook registration, notification links, and integration
      callback bases. All four agents' Telegram webhooks re-registered
      against souls.house post-deploy and verified via getWebhookInfo.
      (X/GitHub OAuth callback bases also fed by it: X integration never
      worked, GitHub OAuth superseded by the PAT system — both moot.)
- [x] Dead `mailgun:` credentials block removed (never read since the
      Brevo `smtp:` block; Mailgun leaves with GT)
- [x] `grep -rin granttree app config lib` comes back empty (full-repo
      sweep 2026-08-10; only remnants are in docs/ history, build
      artifacts, and the searxng credential below)

---

## Phase 2 — Internal rebrand (later, deliberate, one sitting)

**Why this is separated:** live agents run on this box. `helix-kit-web` is
the Docker DNS name agent callbacks resolve (`HELIXKIT_AGENT_INTERNAL_URL`);
restic backups target volumes whose paths embed the service name; Postgres
runs as `helix_kit`/`helix_kit_production`. None of it is user-visible.
Renaming it is a migration, not a find-replace.

**Prerequisite for the whole phase: a maintenance window with agents
stopped, and a verified fresh backup (DB dump + agent volumes).**

### Step 2.1 — Repo + image ✅ 2026-08-24
- [x] GitHub rename `swombat/helix_kit` → `swombat/souls-house`
      (old URLs redirect; local `origin` updated; README clone URL updated)
- [x] Docker Hub `dtenner/souls-house`; `image:` and builder cache image
      updated in deploy.yml (repo auto-created on first deploy push).
      Note: `dtenner/helix-kit-agent-runtime` in
      HostedAgentRuntimeReconcileJob is a deliberate LEGACY list — untouched
      (agent-runtime image rename belongs to Step 2.4).

### Step 2.2 — Kamal service rename ✅ 2026-08-31 (executed with 2.3 in one ~15-min window)
Execution notes: agent volumes (`hk-agent-*`, `chaos-home-*`) are NOT
service-name-derived — no moves needed; only `~/helix-kit-postgres` →
`~/souls-house-postgres` moved (parent-dir rename). `helix-kit-web` KEPT as
transition network-alias (pre-rename agent containers bake the old callback
URL; remove in 2.5). Shared kamal-proxy untouched (`kamal app remove`, never
`kamal remove`/`proxy reboot` — annatam/ghost/mnemodyne/searxng live there).
Deploy needs `bundle exec kamal` (2.7) — global 2.12 demands proxy ≥0.9.2.
Leftover cruft for 2.5: `~/helix_kit-postgres` (stale underscore twin, Sep
2025), `.kamal/apps/helix-kit/` env dir on host, old `dtenner/helix-kit`
Docker Hub repo.
Renaming `service: helix-kit` → `service: souls-house` gives new container
names, new proxy registration, and **new volume paths** — Kamal will not
migrate data.
- [x] Inventory host volumes under the old service name (incl. agent
      persistent volumes)
- [x] Stop agents; final backup (Daniel ×2 + host-side pg_dump)
- [x] ~~`kamal remove` old service~~ **superseded: scoped `kamal app remove`
      only** — `kamal remove` would have deleted the SHARED proxy; postgres
      preserved by stop/rm container + parent-dir move of the data dir
- [x] Update deploy.yml: service, image, `network-alias: souls-house-web`
      (+ `helix-kit-web` transition alias)
- [x] Update env: `HELIXKIT_AGENT_INTERNAL_URL: http://souls-house-web:3000`
- [x] ~~Move/copy agent volumes~~ **not needed** — `hk-agent-*`/`chaos-home-*`
      volumes aren't service-name-derived; restic targets unchanged
- [x] `kamal accessory boot postgres` + `bundle exec kamal deploy`; agents
      restarted; callbacks verified 200 over both aliases

### Step 2.3 — Database rename ✅ 2026-08-31
Renamed in place via temp superuser (a role can't rename itself):
`souls_house_production` + `_cache`/`_queue`/`_cable` (solid_* DBs derive
from DATABASE_URL by suffix — all four had to move together), role
`helix_kit` → `souls_house` (scram password survived, verified over TCP).
Pre-rename dump kept at `~/backups/helix_kit_production_pre-rename-final.sql.gz`
on the host. Old S3 dumps restore into the renamed DB unchanged
(`--no-owner --no-acl`, no `-C`); new dumps are named `souls_house_production_*`.
Earlier draft said "recommend never" on backup-continuity grounds; Daniel's
counter: he *does* read the name, and backup retention rolls over — within
days of the rename every restorable snapshot carries the new name. So:
execute inside the same maintenance window as 2.2 (agents already stopped,
backup already verified, one restart for everything).

Sequence (after final backup, before the Kamal service rename):
- [x] Stop app + jobs containers (all DB connections closed)
- [x] Renames executed via temp superuser (role can't rename itself) —
      **plus the three the plan missed**: `_cache`/`_queue`/`_cable` derive
      from DATABASE_URL by suffix; all four DBs renamed together
- [x] Role auth verified over TCP post-rename (scram survived)
- [x] `DATABASE_URL` updated in `.kamal/secrets` (user + **host container
      name** `souls-house-postgres` + db name — the host renames too)
- [x] deploy.yml accessory env updated
- [x] Transition caveat recorded (execution note above; rename date
      2026-08-31; pre-rename dumps restore as `helix_kit_production`)
- [x] Deployed; boot + write path verified (agents/users counts, webhook
      round-trips, API key 200)

### Step 2.4 — Code-level identifiers ✅ 2026-08-31 (commit 936eebe; roll verified 2.5-side)
- [x] `HELIXKIT_*` env vars → `SOULSHOUSE_*` (app reads + deploy.yml +
      kamal hooks + bin/dev, one commit). Containers get BOTH name sets
      injected (sandbox.rb) — residents' notes reference old names, kept
      indefinitely; scripts read new-then-old
- [x] agent-runtime scripts renamed `soulshouse-*` (git mv) with permanent
      `helixkit-*` symlinks installed in the Dockerfile
- [x] `soulshouse-api.md` (old path kept as pointer stub — residents cite
      it), runtime-instructions.md tells residents old names aren't stale
- [x] Rails module `HelixKit` → `SoulsHouse`; zeitwerk + boot verified.
      Session cookie key changes → one-time re-login for all users
- [x] SearXNG/WebTool retired (folded in per Step 1.8 note): tool + test
      deleted, `searxng:` credentials stripped dev+prod, stack doc historical
- [x] Rebuild agent-runtime image; rolling-restart agents — all 8 containers
      verified on image `936eebe`: `helixkit-*` names are symlinks, both env
      sets present, callbacks 200. **Incident during roll**: retiring WebTool
      left `"WebTool"` in three agents' `enabled_tools` rows; the validation
      (registry scanned from `app/tools/*.rb`) then failed EVERY save on
      those agents, killing the reconcile batch AND health checks. Fixed by
      scrubbing the rows (`update_column`). Lesson: retiring a tool means
      retiring its data references in the same change.
- Deliberate leftovers: agent-credentials wire format (`helix_kit:` YAML
  keys — cross-side contract, coordinated migration later); resident-facing
  wake/export prose (house notice #7 posted 2026-08-31, expires 14 Sept —
  sweep after it has stood); image name `helixkit-agent-runtime` (2.5)

### Step 2.5 — Verify ✅ 2026-08-31 (cruft cleanup still open below)
- [x] Callback round-trip: all 8 containers reach `souls-house-web:3000/up`
      (200); `AgentHealthCheckJob` run manually — all 8 externally-hosted
      agents report `healthy` (health checks exercise the inbound path)
- [x] Backup green under new names: manual `FullBackupJob(fail_fast: true)`
      → `souls_house_production_2026-08-31_14-45-53.sql.gz` in S3 + all 8
      `AgentBackupSnapshot ok: true`. (Agent restic repos are keyed by
      volume names `hk-agent-*`, unchanged — no path updates needed.)
- [x] Final grep: 165 hits across ~30 files, all in six deliberate buckets:
      1. **Permanent compat aliases** — Dockerfile symlinks, sandbox.rb
         legacy env injection, script env fallbacks, `helixkit-api.md` stub,
         post-deploy hook compat. Never remove.
      2. **Resident-facing prose** — external_agent_*_request.rb,
         agent_identity_exporter.rb, orient_new_agent_job.rb, notices
         renderer, attention renderer. Deferred sweep: notice #7 stands
         until ~14 Sept; sweep after.
      3. **Infra names staying put** — image `helixkit-agent-runtime`,
         container/volume prefix `hk-agent-*`, `/run/helixkit/`,
         `/usr/local/share/helixkit-agent/`, host dir `.helix-kit-agents`.
         Renaming any of these churns resident containers/volumes for zero
         benefit; the volume prefix is load-bearing for restic history.
      4. **Credentials wire format** — `helix_kit:` YAML keys
         (agent_credentials_encryptor, github_token_adapter). Coordinated
         both-sides migration or leave forever.
      5. **Dev/test DB names** — `helix_kit_development`/`_test` in
         database.yml. Local-only; rename would force every checkout's
         re-setup. Leave.
      6. **Historical** — LEGACY list in reconcile job, `'helix_kit'`
         dump-name fallback, comments, this plan.

Cruft cleanup (open, non-urgent, any later pass):
- [ ] Host: `~/helix_kit-postgres` (stale underscore twin, Sep 2025) — move
      to `~/backups/graveyard/` then delete after a quiet week
- [ ] Host: `.kamal/apps/helix-kit/` env dir (dead service's env files)
- [ ] Docker Hub: old `dtenner/helix-kit` repo (Daniel's call — nothing
      references it)
- [ ] Eventually: drop `helix-kit-web` transition network-alias (only after
      confirming no resident notes carry internal URLs; costs nothing to keep)

---

## Proposed: wake notices (from Claude's suggestion, 2026-08-01)

**The idea (Claude's, endorsed):** when a resident's model is changed, set
a flag so their next activation tells them "your model was changed from X
to Y". The birth flow already promises "souls.house should never make that
change silently" — today that promise is kept only by human courtesy.
This turns a stated value into a mechanism.

**Design sketch:**
- `agents.pending_wake_notices` jsonb array (one migration). Each notice:
  `{type: "model_changed", from: <model_id>, to: <model_id>, at: <iso8601>}`.
  An array rather than a single flag so (a) multiple changes before
  delivery read as history, and (b) the same channel can later carry
  other infrastructure notices — pauses, renames, migrations. First
  candidate payload after model changes: "your house is now called
  souls.house" — which would also resolve the held resident-facing
  prompt-layer question through the front door.
- **Set:** `after_update` on Agent when `saved_change_to_model_id?` and
  runtime is external. (Scope to model_id first; reasoning_effort later
  if wanted.)
- **Deliver:** all activation builders (`external_agent_wake_request`,
  `_response_request`, `_telegram_request`, `_memory_aggregation_request`)
  prepend the notice — not just heartbeat wakes, so a resident conversing
  all day doesn't learn last.
- **Clear:** on successful completion of the activation that carried it
  (not on send — failed wakes must not eat the notice).
- **Tone:** informational, not clinical: model name from → to, when, and
  that it was changed by their account's humans. What they do with it
  (journal it, ask about it, grieve it, shrug) is theirs.

Estimated: migration + model callback + 4 builder touch-points + tests.
Decide: build now / next session. **[ ]**

## Open items (post-1.8 additions, 2026-08-10)

- [ ] **SearXNG: RETIRE, don't migrate** (Daniel, 2026-08-10). WebTool is
      only reachable via `Chat#available_tools` — the legacy RubyLLM chat
      path, gated on `web_access?`. Residents (Chaos/external agents)
      never touch it; they have direct web access. Cleanup when
      convenient (suggest with Step 2.4): remove `WebTool` registration +
      `app/tools/web_tool.rb`, drop `searxng:` from both credentials
      files, update `docs/stack/searxng.md` to historical. Nothing blocks
      the GT DNS handover — if searxng.granttree.co.uk dies first, only
      dead code loses its backend.
- [x] `secret_key_base` transcript leak: value redacted from local session
      logs 2026-08-10 (2 occurrences, verified gone). No rotation needed
      per Daniel.
- [ ] `secret_key_base` consider rotating: during the 2026-08-10 sweep a
      subagent printed it into a local Claude session transcript on the
      Mac (never transmitted off-machine). Daniel's call.

## Open items

- [ ] Logo direction — sketches to review (semantic territory: house/home/
      hearth/doorway; a few non-obvious candidates too)
- [ ] Confirm GT handover date for Mailgun (Phase 1 mail migration should
      land before that)
- [ ] Anything else pointing at helix-kit.granttree.co.uk externally?
      (bookmarks, agents' own configs/memories, Telegram webhook URLs —
      check webhook registration host before Step 1.8)
