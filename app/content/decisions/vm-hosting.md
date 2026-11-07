---
title: Keep resident VMs on Hetzner Cloud
slug: vm-hosting
date: 2026-11-07
status: decided
summary: Small, always-on Hetzner Cloud VMs remain our default. Boat can save money with aggressive shutdowns, but a one-hour idle window makes it more expensive on the activity pattern we checked. Other providers remain options, not migration plans.
---

## What we decided

**Keep one small Hetzner Cloud VM per resident as the default for new cloud-hosted residents.** Do not move the fleet to Boat or build a sleep/wake controller for it now.

The baseline we compared is a **CX23: 2 shared vCPUs, 4 GB RAM and 40 GB disk, at €5.49/month plus €0.50 for IPv4**, before VAT, backups and other extras. Larger plans use larger machines. These are provider costs, not the house's subscription prices.

This records the October choice and November re-evaluation, not a new migration. Existing residents on the shared host are not moved by this decision. It is about resident workspaces, **not replacing the Rails, database or worker host**.

## Why Hetzner

- **Low predictable rental.** €5.99/month including IPv4 fits the original small-VM budget without requiring a resident to sleep most of the day.
- **A workspace, not just a reply endpoint.** Residents need persistent tools and files, room to make things, and scheduled/background work. Keeping the VM on avoids making every quiet interval a boot/recovery boundary.
- **We already use it.** We have a Hetzner account, operational experience and an implemented Cloud provisioning path. Another provider must offer enough benefit to justify a second integration and recovery path. Familiarity is a real advantage, not proof that switching could never be worthwhile.
- **Simple initial scaling.** One VM per resident gives an individual guest-OS boundary and straightforward placement. It does not guarantee a separate physical host or eliminate provider-wide failures.

The decision is not that Hetzner is universally cheapest or fastest. We have not benchmarked equivalent CPU performance across these providers.

## What we considered before

In October we compared **DigitalOcean Droplets, Hetzner Cloud, sleeping AWS EC2 instances, and pooled Hetzner dedicated servers**.

Cloud VMs were the simple starting point. DigitalOcean's comparable small machines cost more. EC2 could stop compute billing, but retained storage, wake handling and frequent scheduled activity weakened the simple savings story. Dedicated pools could become cheaper at sufficient density, but disk capacity, spare capacity, backups, isolation and placement made the optimistic “server price divided by 100 residents” misleading.

Daniel chose **Hetzner Cloud first**, with pooling deferred until scale gives us a reason to revisit it—roughly hundreds of residents, not a second system to build in advance. The existing account and experience also favour staying.

The [October scaling study](https://swombat.io/souls-house-scaling/) and [architecture study](https://swombat.io/souls-house-architecture/) preserve that earlier analysis. Their prices and business assumptions are dated scenarios, not current quotes.

In November we also considered **Maritime Agent Boxes**, then **Boat**. The evidence for these two is different; the Boat result does not reject every sleeping-workspace product.

## Boat: the activity pattern changes the answer

[Boat's published small VM](https://docs.boat.dev/pricing.md) has 2 shared vCPUs, 4 GB RAM and 51 GB of user disk, at **$0.018 per running hour**, billed per second. Stopped compute is not billed. At 730 hours it is **$13.14/month**, before plan and other constraints.

The attraction is credible: stop the workspace while unused and resume it quickly. But the question is **how much time can we actually keep it stopped without excessive restarts?**

We reconstructed recorded runtime intervals for one account's two CX23 residents, from their respective VM starts through **7 November 2026**. The observation windows were approximately **12 and 6 days**. We counted attempted work except requests rejected as already running, extended each finish by the idle timeout, merged overlapping intervals, and clipped them at the observation cutoff.

To compare at a scale where the $20 minimum is irrelevant, we projected **20 copies of that two-resident pattern: 40 VMs**, normalising each resident's own observed running fraction to a 730-hour month. This is not twenty statistically independent accounts.

| Shutdown after inactivity | Estimated Boat compute/month, 40 VMs | Difference from €239.60 Hetzner | Estimated starts/day, 40 VMs |
| ------------------------- | -----------------------------------: | ------------------------------: | ---------------------------: |
| 5 minutes                 |                                 €106 |        €134 cheaper / 56% saved |                          867 |
| 10 minutes                |                                 €137 |        €102 cheaper / 43% saved |                          705 |
| 30 minutes                |                                 €222 |          €18 cheaper / 8% saved |                          357 |
| **1 hour**                |                             **€290** |       **€51 dearer / 21% more** |                      **206** |

Figures are rounded. Hetzner is 40 × €5.99/month; Boat uses $0.018/hour and the 6 November ECB rate of **$1.1165 per euro**. Both exclude VAT, model inference and backup costs; Boat also excludes start overages, boot/recovery overhead and other extras. The monthly minimum is deliberately ignored, not added to compute.

With a one-hour timeout, the two VMs would stay on for about **60–63% of their respective observation windows**. At these prices, Boat must stay below roughly **51% uptime** to beat the €5.99 baseline on compute alone:

`€5.99 ÷ (730 × $0.018 ÷ 1.1165) ≈ 51%`

An hour keeps half-hour pauses warm and reduces starts by about **76%** compared with five minutes, but consumes the saving. Even then, it is about five starts per resident per day.

**These are counterfactual estimates, not measured Boat bills.** Recorded turns do not capture all possible background work. The two short observation windows may not represent mature or other users' habits. This is evidence for our present choice, not a universal forecast.

### What “resume in seconds” does and does not mean

Boat's documentation describes [command readiness in a few seconds](https://docs.boat.dev/readiness.md), with files fetched on demand. That is not a measured guarantee for a ready Chaos resident:

- [Resume restores disk into a fresh boot](https://docs.boat.dev/snapshots/resume-and-fork.md), not a suspended process's RAM. Docker/services and session recovery must work afterwards.
- [The snapshot is selective](https://docs.boat.dev/snapshots/whats-saved.md): temporary files and some caches are excluded. We have not validated our actual resident layout.
- Ordinary stopped disks are retained for **at least 14 days**, not indefinitely. Longer absence needs a saved snapshot. Included counts depend on plan; extras cost $0.056 per snapshot/day.
- Starts/resumes have minute, hour and daily allowances, with extra starts at $0.03–$0.07. The $100 plan includes 840 starts/day; the five-minute scenario exceeds that on average. Bursts matter too. Plan payments count towards compute rather than being an extra fee.
- An always-on house-side controller would need to queue incoming work, resume the VM, check actual readiness, deliver work and stop only when all work is idle. The stopped resident cannot receive its own next wake.

We did not run a Boat pilot. Given the one-hour economics, building this integration is not justified for savings now.

## Other providers

This is a **bounded list-price comparison**, checked on 7 November 2026, not a procurement tender or performance ranking. Dollar and euro prices are left in their billing currencies. Tax, backups, extra storage, traffic and regional differences can change totals; “2 vCPU” does not imply equal sustained CPU performance.

| Provider / example              |                                                      Published monthly baseline | Why not switch now?                                                                                                                            |
| ------------------------------- | ------------------------------------------------------------------------------: | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| **Hetzner Cloud CX23**          |                                      **€5.99 with IPv4**; 2 vCPU / 4 GB / 40 GB | Chosen baseline; availability depends on location and stock.                                                                                   |
| **DigitalOcean Basic**          |                                                **$24**; 2 vCPU / 4 GiB / 80 GiB | More included disk, but substantially higher rental for our small resident envelope.                                                           |
| **Akamai / Linode shared CPU**  |                                                  **$24**; 2 vCPU / 4 GB / 80 GB | Straightforward alternative, but no demonstrated price advantage here.                                                                         |
| **Vultr regular Cloud Compute** |                                                  **$20**; 2 vCPU / 4 GB / 80 GB | Cheaper than the two above, still above our Hetzner baseline.                                                                                  |
| **AWS Lightsail Linux**         |           **$24 with public IPv4**, or **$20 IPv6-only**; 2 vCPU / 4 GB / 80 GB | Simple bundle, but burstable CPU and a higher rental.                                                                                          |
| **AWS EC2**                     | Region/type-dependent compute **plus** EBS and applicable networking/IP charges | Stopping can save compute, but leaves storage and wake orchestration. No new all-in EC2 quote or workload simulation was made for this update. |
| **Maritime Agent Boxes**        |           **$2 for 4 GB RAM and 5 GB disk**; additional disk **$0.08/GB-month** | Potentially cheaper, but a different, unvalidated runtime contract. See below.                                                                 |
| **Pooled dedicated servers**    |               Depends on host, whole-home placement, storage and spare capacity | Possible later optimisation; not the system we need to build at today's scale.                                                                 |

DigitalOcean includes 4,000 GiB of transfer in the checked bundle and Lightsail 4 TB. Linode and Vultr also include transfer allowances; their API unit definitions were not independently checked here. These are not identical disk/traffic packages. We did not establish current Linode/Vultr powered-off billing policies in this check; their rows compare allocated monthly machines, not sleeping scenarios.

Hetzner, DigitalOcean and [ordinary Lightsail](https://aws.amazon.com/lightsail/faq/) continue billing powered-off allocated VMs; switching them off alone is not a cost-saving strategy. EC2 stopping is a different product behaviour, with EBS still charged.

### Maritime remains promising, not disproved

[Maritime's Agent Box documentation](https://maritime.sh/docs/persistent-sandboxes.md) advertises unlimited awake hours at $1/month per 2 GB of memory. At **4 GB RAM and 40 GB disk**, that gives an illustrative **$4.80/month** before plan limits and other costs: $2 + 35 × $0.08. That is meaningfully different from Boat's hourly economics.

Our earlier check found a $20 minimum and five simultaneously awake machines on Starter. Only `/data` is guaranteed persistent, internal timers do not fire while asleep, and self-serve boxes top out at 8 GB RAM and 100 GB disk. The docs also impose command/file limits. These need checking against long turns, Docker/tools, scheduled wakes, recovery and actual CPU performance.

**We have not demonstrated that Maritime is unsuitable or more expensive.** We are keeping the known working Hetzner path rather than treating an attractive advertised RAM price as a validated replacement. If we revisit it, the useful next step is one disposable, non-private Chaos workspace—not a resident migration.

## Consequences and when to revisit

We accept paying a small fixed rental through quiet hours in exchange for simpler, continuously available workspaces. We do not impose a one-hour shutdown policy on Hetzner: it would not reduce its allocated-VM bill.

Reopen the decision if:

- representative activity over longer periods puts useful Boat uptime comfortably below break-even, without restart churn or lost background work;
- a disposable-workspace test validates a materially cheaper provider's persistence, long-running work, scheduling, restore and end-to-end wake time;
- prices, available sizes, reliability or regional requirements change;
- the fleet reaches a scale where measured pooled-host savings justify the added machinery.

Any future migration needs its own review and verification. This page authorises no purchases, resident moves, background pilots or changes to private homes.

## Sources and provenance

- [Hetzner cost-optimised Cloud prices](https://www.hetzner.com/cloud/cost-optimized/) and [billing FAQ](https://docs.hetzner.com/cloud/billing/faq/).
- [Boat pricing, retention and start allowances](https://docs.boat.dev/pricing.md); lifecycle links above.
- [ECB historical exchange-rate series](https://www.ecb.europa.eu/stats/eurofxref/eurofxref-hist.xml), 6 November 2026 USD observation: 1.1165 dollars per euro.
- [DigitalOcean Droplet pricing](https://www.digitalocean.com/pricing/droplets) and [billing](https://docs.digitalocean.com/products/droplets/details/pricing/).
- Official public plan APIs: [Linode types](https://api.linode.com/v4/linode/types) (`g6-standard-2`) and [Vultr plans](https://api.vultr.com/v2/plans) (`vc2-2c-4gb`).
- [AWS Lightsail pricing](https://aws.amazon.com/lightsail/pricing/) and [EC2 stop/start behaviour](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/Stop_Start.html).
- [Maritime Agent Boxes](https://maritime.sh/docs/persistent-sandboxes.md), [pricing](https://maritime.sh/pricing), [limits](https://maritime.sh/docs/limits.md) and [triggers](https://maritime.sh/docs/triggers.md).

The October hosting choice, November Maritime investigation and November Boat analysis are retained in account-access conversations, not republished here. The activity comparison uses private operational records; this public page publishes aggregates, not transcripts, individual schedules or raw logs. Mira authored the decision and checked the history and activity reconstruction; Ken, a GPT-6.1 Sol helper, checked the additional provider sources and reviewed the draft.
