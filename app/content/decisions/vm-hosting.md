---
title: Re-evaluating resident VM hosting
slug: vm-hosting
date: 2026-11-12
status: under review
summary: CX stock shortages have reopened the provider choice. CPX is substantially more expensive, Boat's economics now deserve reconsideration, and cheap OVH prices come with their own stock constraints. No provider switch has been approved.
---

## 12 November: the decision is reopened

**We are comparing providers before changing procurement.** The 7 November decision below used a €5.99 CX23 baseline. That remains a real price when stock exists, but is not a dependable quote for every size and location. It must not be silently replaced with a much dearer CPX plan while retaining the old conclusion.

At approximately **10:10 UTC on 12 November 2026**, a read-only check with the house's Hetzner account found:

- **CX23**: €5.49 plus €0.50 IPv4, available in **Nürnberg and Helsinki**, unavailable in Falkenstein.
- **CX33 and CX43**: unavailable in all three EU locations.
- **CPX12/22/32/42**: available in all three EU locations.
- The checked CX types have **no announced deprecation in the API**. A stock shortage does not establish that Hetzner is retiring CX. Stock already changed during this investigation; availability is an observation, not a reservation or a purchase guarantee.

Existing VMs are unchanged. No CPX allowlist, credentials, subscription prices or plan mapping has been changed by this comparison.

### Current conventional-VM costs

These are **provider costs, not house subscription prices**, before VAT, inference and optional extras. IPv4 is included in the Hetzner totals below. Dollar prices remain in their billing currency; CPU counts are not performance benchmarks.

| Provider / size               | vCPU / RAM / included disk |                   Monthly price | Important qualification                                                     |
| ----------------------------- | -------------------------- | ------------------------------: | --------------------------------------------------------------------------- |
| Hetzner CX23                  | 2 / 4 GB / 40 GB           |                           €5.99 | Available in two checked EU locations, not a reliable larger-size fallback  |
| Hetzner CPX22                 | 2 / 4 GB / 80 GB           | €16.99 Helsinki; €19.99 Germany | Roughly 2.8–3.3 times the old small-VM rental, with twice the disk          |
| Hetzner CPX32                 | 4 / 8 GB / 160 GB          | €30.49 Helsinki; €35.99 Germany | Available at the check                                                      |
| Hetzner CPX42                 | 8 / 16 GB / 320 GB         | €59.49 Helsinki; €69.99 Germany | Available at the check                                                      |
| Vultr regular Cloud Compute   | 2 / 4 GB / 80 GB           |                             $20 | Fresh public plan API; region stock and our integration not tested          |
| Akamai / Linode shared CPU    | 2 / 4 GB / 80 GB           |                             $24 | Fresh public plan API; no demonstrated price advantage over CPX in Helsinki |
| AWS Lightsail Linux with IPv4 | 2 / 4 GB / 80 GB           |                             $24 | Still bills while stopped                                                   |

Vultr's checked 8 GB/160 GB and 16 GB/320 GB plans cost **$40 and $80**. Linode's cost **$48 and $96**. Lightsail's corresponding bundles are **$44 for 2 vCPU/8 GB/160 GB** and **$84 for 4 vCPU/16 GB/320 GB**; those are not matching CPU allocations.

DigitalOcean's previous $24/$48/$96 Basic quotes are retained only in the historical comparison below: its pricing pages refused this investigation's direct requests, so they were **not freshly verified**. Scaleway's pricing page was also inaccessible; zero-valued price fields in its public instance API are not evidence of free machines.

### OVH: attractive prices, but check Linux stock and the actual basket

OVH's current public VPS catalogue is materially cheaper on paper. Its website labels the line **VPS 2027**; that label alone does not mean a future delivery date. Monthly, no-commitment base prices in the Ireland catalogue are **€4.49 (2 vCPU/4 GB/40 GB), €8.49 (4/8/75), €12.24 (6/12/100) and €23.49 (8/24/200)**. Lower website “from” prices use twelve-month upfront commitment, not the monthly rate.

These are **base prices, not verified all-in checkout totals**. The catalogue requires a backup option whose price does not simply match the website's “included” wording. Conservatively adding the cheapest mandatory backup gives **€4.84/€8.99/€12.84/€24.49** respectively, with the first IPv4 included. Additional 100 GB disk is listed at €4.31/month; the smallest plan plus 50 GB extra storage would be **€6.99 for 40 GB root plus 50 GB separate disk**, subject to an actual quote and stock.

More importantly, the public stock endpoint marked the checked **EU Linux** offers unavailable. The 8 GB model had Linux availability in **Canada**, not a verified EU substitute. A region's generic `status: available` can reflect Windows stock while `linuxStatus` is unavailable. A provider shortlist must use the latter, not just the headline availability.

OVH merits follow-up, but an out-of-stock quote does not solve an out-of-stock procurement problem. It has public ordering and VPS lifecycle APIs; we have not built or tested a house integration, boot/recovery path or workload benchmark.

### Boat: the old cost conclusion no longer applies to CPX

Fresh Boat documentation still lists **2 vCPU/4 GB/51 GB at $0.018/hour**. At 730 hours that is **$13.14/month of compute**, approximately **€11.81** using the latest available ECB observation at this check: **11 November, $1.1127 per euro**. The account has a **$20 minimum**, credited towards usage rather than added to it; one small VM alone therefore does not produce a $13.14 invoice.

The previous two-resident activity reconstruction below remains a **7 November observation**, not a new simulation. Re-expressing its rounded one-hour-timeout result at the new exchange rate gives about **€291/month for 40 small VMs**, versus **€679.60 for 40 Helsinki CPX22s** or **€799.60 in Germany**. That excludes start overages, recovery overhead and extras, as before. The old statement that an hour's idle grace destroys the saving was true against CX23, **not against CPX22**.

Boat is therefore worth reconsidering for small homes, even without aggressive sleeping. But **51 GB of user disk is not an 80 GB CPX22 disk**. Its 8 GB RAM size also has only 51 GB of user disk; the 16 GB size has 111 GB. A 251 GB workspace requires the $0.20/hour size: **$146/month at full use**, not the small-machine price. We have not established an independently expandable disk option.

The lifecycle constraints still matter. After the short same-machine grace, resume is a fresh boot with selected disk state restored, not guaranteed preservation of RAM or running processes. Docker build caches and some tool caches are excluded unless deliberately relocated. Long absence needs a saved snapshot beyond the ordinary minimum 14-day stopped retention. An integration must recover services, scheduled work and resident readiness, not merely receive an HTTP “ready” response. No Boat pilot or purchase has been made.

### Maritime, sleeping EC2 and dedicated pools

**Maritime** still advertises agent boxes at $2/month for 4 GB RAM, plus $0.08/GB-month above 5 GB. An **80 GB** home is therefore **$8/month of usage**, subject to the account minimum and awake-machine limits. Self-serve storage tops out at **100 GB** and RAM at **8 GB**. The default is 1 vCPU; the billing docs say more vCPUs can be requested without changing the memory/disk rate. This is not a measured CPU-performance guarantee. Only `/data` is persistent; always-on machines are not sold on these plans and internal timers do not fire while asleep. It is an interesting small-home candidate, not a validated replacement for larger development workspaces.

**EC2 in Ireland**, Linux On-Demand, is expensive always-on but can save money at low duty cycles. A t3a.medium is $0.0408/hour, plus **$7.04/month for 80 GB gp3** and **$3.65/month for a retained public IPv4**. At 730 running hours that is **$40.47**, before traffic, burst CPU credits or backups; at 100 running hours it is **$14.77**. Even at zero compute hours, retained storage and IPv4 cost **$10.69**. Releasing the IP changes that floor and the recovery contract. ARM t4g.medium is cheaper compute, but is a separate compatibility choice, not an equivalent x86 deployment.

**Dedicated pooling** deserves a new density calculation rather than the old “hundreds first” assumption being treated as permanent. A freshly checked Hetzner AX42 quote is €99/month plus €49 setup, with 64 GB RAM and two 512 GB NVMe drives. Mirroring gives roughly one drive's capacity before system overhead, not a terabyte of independent usable storage. At 80 GB per home, disk admits at most six homes before overhead/headroom; at 160 GB, three. Shared failure domains, spare capacity, isolation, CPU contention, backups and operating work must be priced too. This is not €99 divided by a RAM-only resident count.

### Disk changes the recommendation

Hetzner's account API now quotes **€0.0572 per GB-month** for extra volumes: **€5.72 per 100 GB**, before VAT. Some descriptive website copy still shows the older €0.044 rate; the current API price governs this comparison.

For a home that needs disk rather than more CPU/RAM, **CPX22 plus a 100 GB volume is €22.71/month in Helsinki for 80 GB root plus 100 GB separately mounted storage**. That can be much more sensible than buying CPX42 merely to obtain disk. It is not a single enlarged root disk; provisioning, mounts and backups would need implementing and verifying.

Moving a large development workspace to another host also does not fix unbounded checkout/cache growth. Capacity and retention are separate questions. No private files or development volumes are moved or deleted by this research.

### Recommendation, not an approved migration

1. **Do not replace CX with CPX by default yet.** Keep using verified available CX capacity where appropriate; do not silently downsize CPU/RAM or increase provider spend.
2. **Reconsider Boat for small homes**, because the old financial rejection no longer holds against CPX. A disposable compatibility test is the next useful evidence, not moving a resident first.
3. **Keep OVH on the conventional-VM shortlist**, conditional on a real Linux quote and acceptable region stock. Vultr is a plausible conventional fallback, but its price is close to CPX, not a transformative saving.
4. **Treat large development homes separately.** Compare a smaller VM plus storage with a properly costed dedicated pool, rather than extrapolating the smallest sandbox's price.

The provider decision remains with Daniel. This update authorises **no purchases, provider switch, paid pilot, resident move or provisioning change**.

### Sources for this update

Checked by actual HTTP retrieval on 12 November 2026, with the stock timestamps above:

- [Hetzner regular-performance plans](https://www.hetzner.com/cloud/regular-performance/) and [the website's current price data](https://www.hetzner.com/_resources/app/data/app/live_data_prices.json); independently checked against account-scoped `GET /server_types` and `GET /pricing`. No credential or customer data is published.
- [Hetzner block storage](https://www.hetzner.com/cloud/block-storage/) and [AX42](https://www.hetzner.com/dedicated-rootserver/ax42/).
- [Boat pricing](https://docs.boat.dev/pricing.md), [machine sizes](https://docs.boat.dev/machines.md), [snapshot exclusions](https://docs.boat.dev/snapshots/whats-saved.md) and [readiness](https://docs.boat.dev/readiness.md).
- [ECB latest daily reference rates](https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml), containing the 11 November USD observation at retrieval.
- [Maritime agent boxes](https://maritime.sh/docs/persistent-sandboxes.md), [billing](https://maritime.sh/docs/billing.md) and [sleep/wake](https://maritime.sh/docs/how-it-works.md).
- [Vultr plan API](https://api.vultr.com/v2/plans), [Linode type API](https://api.linode.com/v4/linode/types), [Lightsail prices](https://aws.amazon.com/lightsail/pricing/) and [billing FAQ](https://aws.amazon.com/lightsail/faq/).
- [OVH Ireland VPS plans](https://www.ovhcloud.com/en-ie/vps/), [public order catalogue](https://eu.api.ovh.com/v1/order/catalog/public/vps?ovhSubsidiary=IE) and [Linux-specific stock API](https://eu.api.ovh.com/v1/vps/order/rule/datacenter/aggregated?ovhSubsidiary=IE&planCodes=vps-2027-model1,vps-2027-model2,vps-2027-model3,vps-2027-model4,vps-2025-model1). Public catalogue inclusion is not proof that an order will succeed.
- [AWS Ireland EC2 price catalogue](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonEC2/current/eu-west-1/index.csv), published 10 November with 1 November effective prices; [IPv4 pricing](https://aws.amazon.com/vpc/pricing/) and [EC2 stop/start behaviour](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/Stop_Start.html).

Mira checked Hetzner, Boat, Maritime, storage and the recommendation. Phil, a GPT-6.1 Sol helper, retrieved the additional provider evidence and caught OVH's commitment, mandatory-option and Linux-stock distinctions. No new performance benchmarks were run.

---

## Historical decision: 7 November 2026

**The remainder preserves the earlier decision and its dated evidence. It is not the current provider recommendation.** In particular, its Boat comparison uses CX23, not CPX, and its stock and list-price statements must not be read as a 12 November quote.

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
