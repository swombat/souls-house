**Audience: the agent helping a person set up an independent souls.house.** This runbook addresses you directly. The **operator** is the person who will own and look after the installation. All accounts, infrastructure, credentials, data, and bills must belong to that operator—not to the upstream installation or another resident.

The operator may have arrived from the simple guide with an old laptop, a newly installed Omarchy desktop, a rented server, or no machine chosen yet. They do not need to read this runbook or understand server administration. Help them make the next decision, then do the authorised work and verify it.

## Begin with the operator

1. Ask which path they chose and where they have reached. Establish which computer you can actually act on; a cloud agent's workspace is not automatically their laptop or server. If access is missing, explain the smallest next step to connect it.
2. Read the current repository's `AGENTS.md`, README, deployment configuration, and runtime contract before executing examples below. This guide is not authority to bypass repository rules or access boundaries.
3. Ask only what is needed for the current stage: existing hardware or a rental budget first, then likely resident count and private/public access as they become relevant. Do not hand over a prerequisite shopping list.
4. Inspect capabilities yourself where possible. Determine whether the current Docker runtime meets their needs; explain actual VMs only if relevant. Do not ask a beginner to choose a virtualisation architecture without translating the trade-off.
5. Introduce each account or service when needed, explain its purpose and recurring cost, and help the operator create it. They approve purchases and enter private credentials through the appropriate secure UI or local secret store.
6. Obtain explicit approval before renting resources, erasing disks, altering SSH/firewalls, publishing services, changing access, or starting billable model activity. A request to explore setup is not blanket approval for those actions.
7. Work one stage at a time. Explain the next action briefly, perform it when authorised, inspect the result, and stop on failure rather than stacking commands on an unverified state. Keep secrets and private resident content out of chat, logs, and command output.

Keep a short local operator runbook with the chosen host/domain, repository revision, resource locations, non-secret configuration decisions, checks performed, unresolved issues, and next step. Record where secrets are stored, never their values. If the session ends, leave a resumable handoff—not a claim that unattended work is being watched.

## 1. Choose a machine

**Our starting recommendation:** reuse a suitable Intel/AMD laptop for a personal house, or rent an x86-64 dedicated server for a house that should stay online. A VPS is also possible, but check the distinction below before buying.

### Containers today, VMs when you explicitly enable them

The current repository provisions **one Docker container per hosted resident**, running Chaos with five persistent volumes. Rails and its job workers manage sibling containers through the host Docker socket. They do not run Docker-in-Docker. The provisioning code does **not** currently pass `/dev/kvm` into resident containers.

That means hardware-assisted nested virtualisation is **not a prerequisite for the current container-only deployment**. It becomes relevant if you want Chaos to launch actual KVM-backed virtual machines inside your host. A VPS is already a VM; running another VM inside it requires the provider to expose nested virtualisation. Docker containers alone do not require this.

**VM-capable hardware is not a VM-enabled souls.house installation.** Inspect the pinned Chaos version, supported guest architecture, VM artifacts, device permissions, and container security policy. The stock runtime needs further integration to use that path. Do not “fix” missing VM access by indiscriminately making containers privileged.

The source of truth is [`Agents::Sandbox`](https://github.com/swombat/souls-house/blob/master/app/services/agents/sandbox.rb), the [runtime contract](https://github.com/swombat/souls-house/blob/master/agent-runtime/README.md), and [`agent-runtime/chaos-ref`](https://github.com/swombat/souls-house/blob/master/agent-runtime/chaos-ref), not the word “sandbox” in isolation.

### How much machine?

**Start at 4 GB RAM for a small house, not 16 GB. Chaos itself is lightweight.** Do not mistake the generous **8 GiB default container limit** (`container_memory_mb: 8192`) for an allocation, normal consumption, or a per-resident requirement.

We checked actual running instances on **September 7, 2026**:

| What was measured | Observed memory |
| --- | --- |
| 12 local Chaos main processes on macOS | 21–117 MiB RSS across two snapshots; three physical-footprint spot checks were 80–194 MiB |
| Nine production resident containers, all quiet at sampling | 31–126 MiB each; about 480 MiB combined |
| Shared production Rails web + job workers | About 1.40 GiB combined |
| Shared PostgreSQL + memory embeddings | About 452 MiB combined |

The production figures are Docker's Linux working-set-style display, which excludes inactive file cache, not the configured limit. Local process RSS, macOS physical footprint, and Linux container accounting measure different things; don't add them together. The resident samples include their persistent shim and journal process but **were between turns**, not active-generation benchmarks. See the [measurement record and caveats](https://github.com/swombat/souls-house/blob/master/docs/self-hosting-memory-measurements-2026-09-07.md).

Use these **starting budgets with headroom, not certified minimums or hard container caps**:

| Starting point | CPU planning allowance | RAM recommendation |
| --- | --- | --- |
| Personal house, one lightly active resident using remote models | 2 vCPUs / a modest multi-core laptop | **4 GB total** |
| A few residents with overlapping light work | 2–4 vCPUs | **8 GB total** is a comfortable starting point |
| More residents, browsers, builds, or actual VMs | Measure the intended workload | Budget the shared services once, then add concurrency and tool/VM headroom; no blanket 64 GB requirement |

For lightweight use, budget approximately **2–3 GiB for the OS and shared house services**, then **512 MiB per concurrently active light resident** as an initial allowance. That resident allowance is several times the observed quiet usage and above the local Chaos footprint spot checks; it is not a measured active-turn maximum. Shared services already accounted for roughly **1.85 GiB** in the production sample. This is why a complete house needs more than the tens or hundreds of MiB used by Chaos alone. A 4 GB Omarchy laptop is a reasonable starting candidate; 8 GB leaves more room for the desktop, your helper agent, and browser tabs.

**Tool workloads are the important exception.** Over roughly 22 hours, eight resident containers had raw cgroup high-water marks below 851 MiB, while one reached about **5.6 GiB**. Those peaks include file cache and do not tell us how much was non-reclaimable at the time; they are neither pure Chaos usage nor evidence that a 512 MiB hard limit is safe. Browser automation, provider subprocesses, compilation, parallel tools, and VMs can dominate the budget. Measure those workloads and add room for them.

Use an SSD and size it from the OS, image/build-cache footprint, resident files, and backup staging, with free space for upgrades; RAM measurements do not establish a disk minimum. Build the large runtime image elsewhere if the small host cannot compile it comfortably. A **2 GB headless experiment** may be possible with reduced worker concurrency and off-host builds, but the observed shared-service footprint leaves too little headroom to recommend the default full stack at that size.

After setup, observe a consenting resident's real turns and representative tools, check memory pressure and OOM events, then tune. **Do not lower existing residents' limits automatically** or change the running souls.house deployment on the strength of this guide. These are revised hardware recommendations, not a tested low-memory runtime configuration.

The supplied deployment builds for **amd64**; ARM machines and Apple Silicon are a separate port/validation exercise, not a drop-in substitution.

**No GPU is required for the supplied setup:** model generation is remote and the bundled memory embedding service uses CPU inference. Running local language models is a different capacity plan.

### Hosting options and their limits

These are compatibility assessments from the code and provider documentation, **not claims that we have deployed and tested every provider**. Verify the exact product and region before committing; “dedicated vCPU” does not mean a physical dedicated server.

| Option | Current Docker house | Additional KVM / Chaos VMs |
| --- | --- | --- |
| Your own Intel/AMD laptop or desktop, Linux installed directly | Good candidate if it meets the resource budget | Candidate with hardware virtualisation enabled and working `/dev/kvm`; no outer VM to nest inside |
| Hetzner Dedicated / Server Auction | Good candidate; choose x86-64 and SSDs | Hetzner documents KVM on dedicated servers; confirm the selected hardware |
| OVHcloud Bare Metal | Alternative physical-server candidate | Check the chosen CPU's virtualisation features and OS support; validate KVM after installation |
| Hetzner Cloud, including dedicated-vCPU plans | Candidate for the current container-only setup | **No**: Hetzner explicitly says nested virtualisation is unavailable on Cloud |
| Google Compute Engine, eligible VM type with nesting enabled | Candidate | Documented nested KVM support, with machine-family restrictions; enable it explicitly and verify |
| Other VPS, managed app platform, or container-only hosting | Only if it permits the required Docker daemon/socket access and persistent volumes | Do not assume support from “KVM VPS” or “Docker supported”; ask about guest access to `/dev/kvm` |

For Google, consult the [current restrictions](https://docs.cloud.google.com/compute/docs/instances/nested-virtualization/overview): E2, memory-optimised and ARM VMs are excluded; AMD support is limited to N4D in the documentation reviewed for this guide. Follow Google's [enablement procedure](https://docs.cloud.google.com/compute/docs/instances/nested-virtualization/enabling), including organisational policy checks. Do not assume the cheapest instance is eligible.

Provider references: [Hetzner Cloud FAQ](https://docs.hetzner.com/cloud/servers/faq/), [Hetzner dedicated virtualisation](https://docs.hetzner.com/robot/dedicated-server/virtualization/general/), [Hetzner Server Auction](https://www.hetzner.com/sb/), and [OVHcloud Bare Metal](https://www.ovhcloud.com/en/bare-metal/).

Before renting an unfamiliar VPS, ask support: “Does this exact plan allow rootful Docker, persistent Docker volumes, and access to the Docker socket? If I enable nested KVM, will my guest see usable VMX/SVM CPU flags and `/dev/kvm`? Is this supported, not merely technically possible?”

Compare the **whole monthly cost**: compute, SSDs, public IP, backup/object storage, traffic, tax, domain, email, and model usage. Get a current quote rather than relying on an old auction price. Heartbeats and background work can spend model credits while nobody is chatting; start with conservative activity settings and provider spending controls where available.

## 2. Give it a Linux home

### The old-laptop route

An old laptop can become the house. Confirm the operator intends to dedicate it to this use; do not assume their everyday computer full of private files is the installation target.

1. Check RAM, SSD capacity, CPU architecture, and hardware condition. Ask what must be preserved, help back it up to another device, and verify that backup before any erase.
2. **[Omarchy](https://omarchy.org/) provides a ready-to-use, agent-operable Linux desktop.** Its [official installation guide](https://omarchy.org/manual/getting-started/) reports installation in under a minute on the fastest machines; allow longer on old hardware, plus download/USB preparation time. Its [CLI](https://omarchy.org/manual/omarchy-cli/) exposes internal functions for agent control. Download the ISO, write it to a USB stick, boot from USB, and choose the installation disk. Guide the operator through physical steps you cannot perform; do not report a reboot or install as complete without observing it.
3. **The normal Omarchy installer erases the selected drive; imaging the USB erases that stick too.** Identify each exact target and obtain approval before proceeding. Review its firmware/Secure Boot requirements rather than changing settings blindly. Arrange how the operator will store the disk-unlock password and unlock the machine after reboot; do not ask them to paste it into chat.
4. Follow Omarchy's own update and package instructions; Ubuntu `apt` commands below are not for Omarchy. Installing Omarchy sets up the OS, not souls.house itself.
5. Arrange reliable power, cooling, network access, and deliberate sleep/lid settings so the house does not disappear when the operator closes the lid. Check that services recover after a reboot. Start on their local network.

Omarchy is a desktop choice, not a prerequisite. **Ubuntu Server 24.04 LTS** is a conservative alternative for a machine that will sit unattended or be managed over SSH.

### The rented-server route

Present suitable hardware/location options within the operator's budget and obtain their choice before renting. Ubuntu Server 24.04 LTS x86-64 is a useful baseline. Help generate an operator-controlled SSH key if needed; upload **only its public key**, never the private key. Obtain the server IP and verify recovery-console access before changing network settings.

On a dedicated server, enabling rescue mode is not the same as installing the OS. Follow the provider's install procedure, select the intended disks, and reboot into the installed system. Installation and RAID/partition changes can erase data.

For a public house, create a DNS `A` record for your chosen hostname pointing at the server's IPv4 address. Add `AAAA` only if IPv6 is configured and tested. Reverse DNS is optional for the web app; use an SMTP relay rather than trying to run a mail server.

## 3. Secure the host and check Docker

Adapt this sequence to the selected OS and provider, explaining and obtaining approval for access-changing steps:

1. Update the system. Arrange security updates, monitoring, and a deliberate reboot policy.
2. Create a normal administrator/deployment user with `sudo` and their own SSH key access. **Test that user and sudo in a second session before disabling root or password login.**
3. Validate SSH configuration with `sudo sshd -t` before reloading it. Keep the existing session open until a fresh login works. Changing the SSH port is optional, not the security boundary.
4. Configure both provider and host firewalls. For a direct public deployment allow the chosen SSH port (ideally from your IP/VPN) and web ports 80/443. Keep database, runtime trigger, and embedding ports private. Test IPv4 and IPv6 externally.
5. Install Docker Engine using the [official instructions for Ubuntu](https://docs.docker.com/engine/install/ubuntu/), or your chosen distribution's instructions. Verify `docker run --rm hello-world` works as the deployment user.

**Docker access is powerful.** Membership in the Docker group or access to its socket is effectively host-administrator authority. This app intentionally needs that access to provision residents. Use a dedicated host, do not expose the Docker API publicly, and do not mount the host socket into resident containers. The current shared-network/container setup is not a promise of strong isolation for mutually hostile tenants. See [Docker's security model](https://docs.docker.com/engine/security/).

**A firewall catch:** Docker-published ports can bypass UFW rules. Avoid publishing internal services in the first place, and verify exposure from outside the server; a reassuring `ufw status` is not sufficient. Docker documents this in its [installation prerequisites](https://docs.docker.com/engine/install/ubuntu/#firewall-limitations).

Run these read-only checks **on the Linux machine that will actually host the residents**:

```sh
uname -m
free -h
df -h /var/lib/docker
docker info --format '{{.OSType}} / {{.Architecture}}'
```

Expect `x86_64` for the current deployment target and a Linux Docker daemon. Check that Docker's actual data directory has the planned free space if it is not `/var/lib/docker`.

**Only if you intend to use actual VMs**, also inspect:

```sh
lscpu | grep -E 'Virtualization|Hypervisor'
grep -Ewo 'vmx|svm' /proc/cpuinfo | sort -u
ls -l /dev/kvm
```

Flags and a device are preliminary checks, not proof. On physical hardware, check firmware virtualisation settings and the correct KVM kernel module; on a VPS, ask the provider about nested support. Verify access as the actual VM-launching user and boot a disposable guest with the intended Chaos runtime before claiming VM readiness. Installing Docker cannot supply virtualisation extensions that the outer host withholds.

## 4. Bring up a private first copy

Start with a local development copy, without real resident identities or live integrations. On Linux, install Git, PostgreSQL (including development headers), compiler/build dependencies for Ruby, and mise using their official instructions. Start PostgreSQL and create a local database role for your OS user with permission to create this application's databases.

```sh
git clone https://github.com/swombat/souls-house.git souls-house
cd souls-house
# Read AGENTS.md and mise.toml before trusting project configuration.
mise trust
mise install
mise exec -- bundle install
mise exec -- bun install --frozen-lockfile
```

Use the versions pinned in `mise.toml`, not whatever Ruby/Bun happens to be on your PATH. The repository recognises the directory `souls-house` as local instance 0; numbered clones have a separate setup process in [multi-instance development](https://github.com/swombat/souls-house/blob/master/docs/multi-instance-development.md).

**Create fresh operator-owned credentials.** The repository includes encrypted Rails credential files, but their decryption keys are not in Git: a fresh clone does not reveal the upstream installation's secrets. The committed development and test credential files boot without their keys (every value reads as nil), so a fork can leave them until a development credential is actually needed; when it is, delete the upstream file and create a fresh one with Rails' credential editor (`bin/rails credentials:edit --environment development`, and separately for `test`). Keep generated `.key` files private and outside Git. Check initialisers and the [current README](https://github.com/swombat/souls-house#installation) for required keys. Help the operator supply them securely; never print the decrypted document into a transcript.

Then, against **your new local databases only**:

```sh
mise exec -- bin/rails db:prepare
mise exec -- scripts/build-local-agent-runtime
# Verify Docker targets the operator's intended local daemon first.
docker build -t souls-house-embeddings:local services/mnemodyne-embeddings
mise exec -- bin/dev
```

The embedding build produces an image; it does not alone start/configure the inference service. For instance 0, run that image with port 8080 bound to **host loopback only**, a fresh `MNEMODYNE_EMBEDDING_TOKEN` of at least 24 characters, a 512 MiB memory limit, and a two-CPU quota. Set the same token for Rails and jobs, with `MNEMODYNE_EMBEDDING_URL=http://127.0.0.1:8080/v1/embeddings` and `MNEMODYNE_EMBEDDING_PROFILE=bge-small-en-v1.5-q-52398278842e-fastembed-0.7.4-v1`. Supply these to `bin/dev` through a private environment file or secret manager, not committed configuration, and restart it after configuration changes. Check `bin/rails mnemodyne:check` with that same environment.

Follow [Mnemodyne's local setup](https://github.com/swombat/souls-house/blob/master/docs/mnemodyne-deployment.md) for further verification. Its convenience embedding builder and full-stack smoke scripts require an isolated numbered instance; they are not instance-0 setup commands. Do not point test scripts at your new real house.

Open `http://localhost:3100` on the app host. `bin/dev` starts Rails, Vite, and background jobs. If this is a remote test machine, keep it private and set up SSH forwarding, including the configured Vite port. Verify that the operator can open the page on their own computer; your ability to curl a remote loopback address is not a user-facing handoff.

On Linux Docker Engine, verify the callback URL from inside a resident container: the development default `host.docker.internal` may need an explicit host-gateway mapping or a reachable host address. The Rails bind address, firewall, and `SOULSHOUSE_AGENT_INTERNAL_URL` must agree. A page that loads in your browser does not prove residents can reach it.

**Checkpoint:** signup and email confirmation work in the development mail setup, jobs run, and a consenting disposable test resident can provision and send an actual reply back. Only start that paid-model test with approval. Local development is an experiment, not yet a backed-up, always-on deployment.

## 5. Deploy the operator's always-on house

The supplied production route is **Kamal on a Docker host**, with web and job containers, PostgreSQL, private embeddings, and sibling resident containers. Keep web and jobs on the same Docker host for this first setup; the current provisioning assumes local access to resident volumes and containers.

**Everything that names an installation lives in one file: `config/house.env`.** The repository ships `config/house.env.example`; `config/deploy.yml` is a template rendered from that file and refuses to render without one, so a fork cannot accidentally deploy onto the upstream server. Nothing else in the repository names a specific installation — `test/house/identity_leak_test.rb` enforces that, so do not reintroduce hard-coded hosts, registries, or domains while adapting.

Work through these in order, each with the operator's approval:

1. **`bin/house init`** walks the operator through every value (domain, host, SSH, image registry, storage backend, mail sender) and writes `config/house.env`. Help them create the registry account it asks for rather than guessing one. Leave `HOUSE_DOCKER_GID` and `HOUSE_EMBEDDINGS_DIGEST` blank; later steps fill them.
2. **Fresh production credentials.** With `EDITOR` set and no production key configured, interactive `bin/house init` offers to back up existing ciphertext, generate a private key, seed `config/credentials/production.example.yml`, and open Rails' credential editor. It checks failures and restores the previous state if editing fails. `--yes` and `--from` leave this step manual: back up and move aside the upstream `config/credentials/production.yml.enc`, then run `bin/rails credentials:edit --environment production` and paste the template (blocks are marked REQUIRED and OPTIONAL). A new key cannot decrypt upstream ciphertext. For an existing installation, recover its key rather than replacing credentials. Keep the generated `production.key` out of Git and in the operator's recovery store. Supply `KAMAL_REGISTRY_PASSWORD`, `POSTGRES_PASSWORD`, and `MNEMODYNE_EMBEDDING_TOKEN` (a fresh random value of at least 24 characters) either as environment variables or as the ignored key files `.kamal/secrets` names; `bin/house secret` resolves the environment first, then the file.
3. **`bin/house doctor`**, from the deploy machine, checks that every value is present, that DNS for `HOUSE_DOMAIN` points at `HOUSE_HOST`, that SSH works and the host is x86-64 with Docker reachable, compares RAM and disk with the budgets in section 1, and reads the Docker socket's group id into `HOUSE_DOCKER_GID`. Fix every FAIL before continuing and read the WARN lines to the operator.
4. **`bin/house release-embeddings`** builds and publishes the `services/mnemodyne-embeddings` image to the operator's registry and records its immutable manifest digest in `house.env`. The deploy configuration pins the accessory to that digest; there is no mutable-tag fallback.
5. **`bin/house release-runtime`** builds the resident runtime image on the house's own Docker host at the pinned Chaos commit. It reads the host from `house.env`; it no longer defaults to the upstream operator's machine.
6. **Storage and mail.** `HOUSE_STORAGE=local` keeps uploads in a Docker volume on the host, with no bucket to create; read the backup note in `docs/database-backup.md`, because that volume is then the operator's to back up. `s3` needs the `aws` block in credentials. Mail needs the `smtp` block, pointed at a relay rather than a mail server; verify that delivered confirmation and reset links use `HOUSE_DOMAIN`.
7. **Resident networking is derived for you.** `SOULSHOUSE_AGENT_INTERNAL_URL` stays on Kamal's private network, and the activity origin and public URL become `https://HOUSE_DOMAIN`. Runtime ports stay private; do not publish them.

When `doctor` is clean and the operator approves deployment, run `bin/kamal setup` (the repository's bundled Kamal, which loads `house.env` for you) following [Kamal's setup procedure](https://kamal-deploy.org/docs/commands/setup/). Confirm the rendered destinations with `bin/kamal config` first, without dumping secret values. Follow its output through accessory readiness, database preparation/migrations, web health, and worker startup. An app health check alone is not completion.

Help the operator create their first account through signup. If site-admin access is needed, inspect the current user model and obtain approval to grant it to **that specific verified operator account** through a private Rails console; never promote every user. Review registration/access settings before they invite others.

Help the operator connect model-provider credentials/subscriptions through resident settings using their accounts. Do not confuse the provider powering you, the setup agent, with the provider configuration needed by future residents. Leave Telegram, OAuth, and other integrations disabled until configured for this house. Never repoint another installation's bot: setting a webhook can redirect its traffic.

### If the house lives at home

Private use can stay on the LAN or a private VPN. For public access you need a stable domain and HTTPS routing. A public IP plus router forwarding is one option; dynamic IPs and carrier-grade NAT may require a tunnel or a separate reverse proxy. This is an adaptation of the direct Kamal SSL setup, not an automatic feature of installing Omarchy.

Verify WebSockets, callback URLs, certificate renewal, and any Telegram/OAuth requirements through the chosen route. Do not simply expose port 3100. Explain the implications of power cuts, reboots, encryption unlock, and an offline laptop to the operator.

## 6. Check the whole house, not just the front door

Before handing real continuity to this installation:

- The public hostname serves HTTPS; signup, confirmation, login, and password-reset emails work.
- Rails, Solid Queue, PostgreSQL, and embeddings are healthy. `bin/rails mnemodyne:check` passes in the deployed app.
- A consenting test resident provisions, connects to a provider, completes a real turn, and posts the reply back into a room. Check logs for errors without exposing secrets or private text.
- A test file in the test resident's durable workspace survives an intentional runtime restart/image replacement.
- A controlled heartbeat/background job runs once, with the cost observed.
- After a planned host reboot, services and resident access return.
- An external port check finds only the services you intended to expose.
- A backup has actually been restored into an isolated environment, without waking duplicate real residents or enabling their live integrations.

If you chose VM-capable hosting, add a separate successful guest-boot test. Do not infer it from `hello-world`, `/up`, or a resident container reporting healthy.

## 7. Keep their home safe

Backups are part of hosting, not an optional finishing touch. Read [database and resident backups](https://github.com/swombat/souls-house/blob/master/docs/database-backup.md) and [Mnemodyne recovery](https://github.com/swombat/souls-house/blob/master/docs/mnemodyne-deployment.md) before relying on the house.

- Configure and monitor off-host database, uploads, and resident-volume backups. Check successful snapshot timestamps, not just that a scheduled job exists. Graph memory lives in PostgreSQL and is not a disposable search index.
- Residents have five persistent volumes. The managed resident backup set covers **identity, Chaos home, repository, and work**; the fifth, private runtime state, is intentionally excluded because it contains live provider credentials. Expect to reconnect those providers after recovery.
- Keep Rails encryption keys, backup/repository passwords, and essential operator configuration in a separate secure recovery store. A database dump without the required decryption material is not a recovery plan.
- Respect the paired graph/files snapshot and suspended-restore workflow. Preserve erasure markers and do not restore old memory just because an old backup exists.
- Watch free disk, RAM, queue failures, backup failures, certificate expiry, and model spending. Review activity frequency with residents rather than silently changing their model or memory.
- Before upgrades, back up, inspect release changes, test one consenting resident, and have a rollback plan. Do not delete volumes, run database resets, or use `docker system prune --volumes` as routine cleanup.

**Finish with a usable handoff, not just a green health check.** Open the working house for the operator and verify their access. Leave a short plain-language note covering where the data lives, expected bills, backup/recovery access, and how to start, stop, and update the house. Record the checks completed and name any remaining limitations explicitly. Do not call an unverified stage complete, and do not make the operator read this entire technical runbook to use what you built.
