# Self-hosting memory measurements — September 7, 2026

Read-only observations supporting the RAM guidance in `public/self-host.md`.
No resident was woken, no model request was sent, and no container limit,
configuration, or cache was changed for the measurements.
Only process/container resource metadata was inspected; no identity files,
conversations, credential values, or process arguments were collected.

## Local Chaos processes

`ps -axo pid=,ppid=,rss=,comm=` found 12 Chaos main processes:

- RSS: 21.0–105.6 MiB.
- A later snapshot still found 12 processes, spanning 21.6–116.7 MiB RSS.
- The setup-guide session's process: 105.6 MiB RSS in that snapshot.
- Separate journal daemons: approximately 4.7–19.0 MiB RSS.

Three `vmmap -summary PID` spot checks gave these physical footprints and
lifetime physical-footprint peaks, reported in the tool's `M` units:

| Sample | Physical footprint | Peak |
| --- | ---: | ---: |
| Current setup-guide session | 79.5 M | 86.2 M |
| Another local Chaos process | 193.6 M | 225.8 M |
| Another local Chaos process | 83.0 M | 111.2 M |

RSS is not macOS physical footprint: shared pages, compressed memory, and other
accounting differences matter. These are host-side main-process measurements,
not totals for browser, compiler, MCP, or other tool subprocesses. No prompt or
session state was read to classify the other processes' workloads.

## Production souls.house

First Docker sample: **2026-09-07 13:59:35 UTC**. A second sample a few minutes
later showed essentially the same resident figures.

All nine resident containers were between turns in these observations.
`docker top CONTAINER -eo pid,ppid,rss,comm` showed `tini`, the Python trigger
shim, and `chaos_journald`; no active Chaos generation or provider subprocess.
Therefore these numbers establish the quiet resident-container footprint, not
the memory required by an active conversation.

### Docker display: first sample

| Component | Used memory |
| --- | ---: |
| Resident containers, nine independent values | 30.73, 30.93, 42.73, 48.12, 48.21, 48.88, 48.96, 55.53, 126.10 MiB |
| Resident containers combined | About 480 MiB |
| Rails web | 617.1 MiB |
| Rails jobs | 820.6 MiB |
| PostgreSQL | 213.6 MiB |
| Embeddings | 238.5 MiB |
| Shared services combined | 1,889.8 MiB / about 1.85 GiB |

The nine configured resident limits were 8 GiB each. The embedding limit was
512 MiB. Neither value is a reservation or a measurement of actual usage.

The [Docker stats documentation](https://docs.docker.com/reference/cli/docker/container/stats/)
explains that the Linux CLI subtracts cache from total usage, using
`inactive_file` on cgroup v2. This is not an interchangeable measurement with
process RSS or raw `memory.current`.

### Raw cgroup v2 high-water marks

These containers started around 2026-09-06 15:53 UTC, roughly 22 hours before
inspection. Read `memory.current`, `memory.peak`, `memory.stat`,
`memory.swap.current`, and `memory.events` from their host cgroups. Do not reset
these counters to repeat this inspection.

- Eight raw peaks: approximately 119, 206, 211, 286, 331, 632, 679, and 850 MiB.
- One raw peak: 5,701.65 MiB, or approximately 5.6 GiB.
- That outlier's **current** memory was 2,468.95 MiB, including 2,342.86 MiB
  of inactive file cache; its Docker-displayed usage was about 126.1 MiB.
- None of the nine showed swap usage, an OOM, or an OOM kill in these counters.

The cache composition **at the peak is unknown**. Subtracting today's cache
from the historical peak would be invalid. Raw peaks include reclaimable
memory, but this observation cannot establish that the high peak was all cache
or that a small hard limit would have survived that workload.

See the kernel's [cgroup v2 memory controller documentation](https://docs.kernel.org/admin-guide/cgroup-v2.html)
for the definitions of these counters.

## Recommendation and limits of the evidence

- Reduce the personal-house RAM recommendation from **16 GB to 4 GB**.
- Use **8 GB**, rather than 32 GB, as a comfortable starting budget for a few
  lightly active residents.
- Count the shared stack once: approximately 2–3 GiB including OS allowance,
  plus an initial **512 MiB allowance per concurrently active light resident**.
- Add separately for desktop applications, agent tools, provider subprocesses,
  concurrent builds, browsers, and actual VMs. Prefer off-host image builds on
  small installations.
- Treat these as planning estimates. No complete 4 GB host was load-tested,
  and active hosted conversation/tool peaks were not sampled.
- Do not translate the 512 MiB planning allowance into an enforced container
  limit without representative workload tests and operator/resident agreement.

This is evidence for removing an inflated blanket requirement, not a benchmark
claim that every workload or every resident fits in a particular memory limit.
