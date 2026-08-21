# HTCondor pool policy

Pooling office PCs into a batch system users treat as an extension of their own
machine.

Status: **two-machine pool running**, plus a third machine that joins and runs
jobs but cannot return their output - it sits on a different network from the
other two (section 11). Remote submission works from a third
machine with no login, no shared filesystem, and no home directory on the entry
node. Jobs distribute across both machines. Both carry a contention-driven owner
policy driven entirely by measured system state.

Reboot-tested: the entry node survives a restart with its queue, config and
policy intact (section 13a).

Not yet exercised **under load**: no suspend, eviction, or admission-closure has
been observed actually happening - only verified correct while idle.

Concrete hostnames and addresses live in `condor-host-list`, which is kept
untracked — this document names machine *classes* only.

## 1. Design goals

| goal | consequence |
|---|---|
| Users never log into the entry node | remote submit only; no shells, no home dirs on entry |
| Users' own PCs are also workers | pool is a symmetric co-op, not a donated cluster |
| Owner always wins on their own machine | preemption policy + machine RANK are mandatory, not optional |
| Jupyter allowed, but never on the entry node | notebooks spawn as Condor jobs on workers |
| Mixed hardware | two architectures, three distros, some GPUs |

## 2. Roles

| role | daemons |
|---|---|
| Entry node | `master`, `collector`, `negotiator`, `schedd`, `startd` (limited), `shared_port` |
| Worker | `master`, `startd`, `kbdd` |
| User PC | worker daemons + submit client (`condor_submit -remote -spool`); **no schedd** |

One schedd, on the entry node. User PCs do not queue locally — a schedd on a
laptop dies with the lid.

## 3. Entry node selection

Selected class: **low-power 4-core mini-PC**, not the highest-core machine.

| criterion | finding |
|---|---|
| Role bottleneck | fsync latency on `job_queue.log`, RAM per shadow, NIC bandwidth — not CPU |
| Core count | 16 threads buy nothing for this role; the high-core machine is the pool's only one |
| Commodity | the 4-core class is the fleet's repeated unit; the high-core box is scarce |
| Test validity | production entry node will be commodity class; test on that or learn nothing transferable |
| Scaling path | horizontal — add schedds, or split `collector`+`negotiator` off. Never vertical |

Requirements: `SPOOL` on NVMe; half its cores donated to compute, the rest reserved.

## 4. Machine classes

| class | arch | cores | RAM | disk free | count |
|---|---|---|---|---|---|
| Mini-PC (entry + worker) | x86_64 | 4 | 16 G | 30–70 G | 8+, growing |
| Flagship worker | x86_64 | 16 | 31 G | ~270 G | 1 |
| Laptop | x86_64 | 12 | 8 G | ~250 G | 1+ |
| Edge SBC | aarch64 | 4 | 4 G | ~36 G (SD) | 1+ |
| Jetson | aarch64 | TBD | TBD | TBD | future, GPU |

Distros: Ubuntu 24.04 LTS on x86_64; Debian 13 on the edge SBC; L4T expected on
Jetsons. The same login has a different UID on different hosts — irrelevant to
Condor, fatal to Slurm.

## 5. Resource donation

**Donate everything; protect dynamically.** Static reservation and the
contention policy in section 6 defend against the same thing, so holding
capacity back only idles it in the common case - nobody is using the machine -
while the policy would suspend anyway the moment someone arrives.

That applies to **workers**. The **entry node is deliberately different**: it
carries the collector, negotiator and schedd, and if the schedd cannot fork
shadows or fsync `job_queue.log` then nothing anywhere in the pool runs.

| resource | worker | entry node | why they differ |
|---|---|---|---|
| CPU | **all threads** | reserve ~half | daemons need guaranteed headroom |
| Memory | **90%** offered | ~35% offered | one shadow per running job, pool-wide |
| Disk | reserved + tiers | reserved + tiers **+ transfer caps** | SPOOL is the funnel every job crosses |
| Load scaling | `TotalCpus` | **`DetectedCpus`** | see below |
| Load thresholds | 0.50 / 0.75 | 0.50 / 0.75 | now the same - see below |

### Scale on DetectedCpus, not TotalCpus

`TotalCpus` is what Condor **advertises** - capped by `NUM_CPUS` - while
`TotalLoadAvg` is measured across the **whole machine**. On a 4-core box
advertising 2, scaling load thresholds by `TotalCpus` compares a 4-core load
against a 2-core yardstick: the machine reads as saturated while half of it sits
idle. Workers where `NUM_CPUS` is unset are unaffected only by coincidence.

### The entry node's thresholds must be looser

`condor_shadow` processes are children of the **schedd**, not the startd, so
they are **not** counted in `CondorLoadAvg`. Every file transfer the entry node
brokers for the whole pool therefore lands in `NonCondorLoad` and looks like
owner activity. Worker-tight thresholds would make the entry node close
admission - and flap its own running jobs - purely for doing its job.

### Fractions scale; absolute headroom does not

Load thresholds are `TotalCpus * fraction`, which travels across machine sizes -
but the *slack* it leaves does not. At 0.25, a 16-core box has 4.0 of headroom
while a 4-core box has 1.0, and a desktop with a browser open already idles
above that. Measured: a 4-core desktop, otherwise idle, reported non-Condor load
1.23 against a 1.0 threshold and refused every job while `condor_status` showed
it healthy and Unclaimed.

0.50 to admit, 0.75 to suspend. Admitting while the owner uses half the machine
is safe, because `JOB_RENICE_INCREMENT` means Condor jobs lose the CPU to them
instantly; the gap between the two values is deliberate hysteresis.

### Disk floors: absolute on the entry node, fractional on workers

A fraction suits a volume dedicated to Condor. The entry node's SPOOL, EXECUTE,
`job_queue.log` and OS share one filesystem that is already ~86% full of
unrelated data; what the OS needs there is a **fixed reserve**, not a
percentage of a large mostly-full disk.

### SPOOL cannot be protected by the startd policy

`condor_submit -spool` writes into SPOOL at **submit** time, before any
matchmaking, so `START` never sees it. The only controls are schedd-side
`MAX_TRANSFER_INPUT_MB` / `MAX_TRANSFER_OUTPUT_MB`. Size them against the disk
that exists: at 2048 MB per job with 32 GB free, sixteen concurrent submissions
fill the volume - and `MAX_JOBS_RUNNING` permits 200. Filling SPOOL stops the
schedd writing its queue, which stops the **entire pool**.

### Sandbox hygiene

The starter removes scratch as soon as output transfer completes, so the normal
path is already immediate. The leak is **orphans** - crashed starters, evicted
and held jobs - which nothing reaps until `condor_preen` runs, defaulting to
**once every 24 hours**. On a disk-limited design that is the actual failure
mode. Set `PREEN_INTERVAL` hourly with `PREEN_ARGS = -r`.

## 6. Owner policy — contention-driven, mandatory on every worker

The trigger is local **work** appearing, not a human being detected. When the
machine's own workload grows, Condor jobs suspend; if contention persists they
are evicted.

```
NonCondorLoad = (TotalLoadAvg - TotalCondorLoadAvg)

TIER 1 - admission (costs nothing, loses nothing)
  START =        && (NonCondorLoad   < TotalCpus * 0.50)      is the OWNER busy?
       && (TotalLoadAvg    < TotalCpus * 0.90)      is the MACHINE busy?
       && (HostCpuPsiAvg10 < 20.0)                  actual CPU stall, 10s window
       && (HostMemAvailMB  > TotalMem  * 0.25)
       && (HostDiskAvailMB > TotalDisk * 0.10)
       && FITS_CPU && FITS_MEM && FITS_DISK         does THIS job fit?

  FITS_MEM = (TARGET.RequestMemory =?= UNDEFINED)
          || (TARGET.RequestMemory < (HostMemAvailMB - soft floor))

  SUSPEND  = (NonCondorLoad > TotalCpus * 0.75)
  CONTINUE = (NonCondorLoad < TotalCpus * 0.50)

TIER 2 - eviction (the only thing that discards work)
  PREEMPT = (HostMemAvailMB > 0)
         && (  (HostMemAvailMB  < max(1GB, TotalMem * 0.10))
            || (HostMemPsiAvg10 > 10.0)
            || (HostDiskAvailMB < TotalDisk * 0.05) )

  MaxJobRetirementTime = 0
  MachineMaxVacateTime = 30
```

**Admission is gated on measurement, never on accounting.** Condor's slot
accounting is *request*-based: a job asking for 1 core may spawn 8 threads, one
asking 256 MB may use 10 GB. Sixteen "one-core" jobs can saturate a 16-core box
while matchmaking still believes it is empty. Every term above comes from
`/proc`.

**The two load terms are not redundant.** `NonCondorLoad` subtracts Condor's own
load and answers *is the owner busy*; `TotalLoadAvg` includes it and answers *is
the machine busy*. With only the first, a box at load 60 driven entirely by
Condor reads as idle and keeps admitting more - the owner stays protected while
the machine saturates.

**Admission is graduated, not binary.** Comparing each job's request against
measured headroom lets a small job land where a large one cannot. True dynamic
advertisement is not available: `Cpus`/`Memory` on a partitionable slot are
configured capacity minus request-based allocations, computed by the startd
itself, and cannot safely be overridden. So `condor_status` shows nominal
capacity while `START` holds the truth - a machine can display free slots and
still decline work. Diagnose with:

```
condor_status -af Name Start TotalLoadAvg HostCpuPsiAvg10 HostMemAvailMB HostDiskAvailMB
```

**PSI is the signal that means "the owner is suffering".** Free-memory and load
average are proxies; `/proc/pressure/*` measures the percentage of time tasks
actually stalled. A box can report gigabytes available while thrashing, and load
average is a decaying 1-minute mean that lets a negotiation cycle admit a burst
before it registers. PSI `avg10` reacts in ten seconds.

**Thresholds scale with the machine.** `TotalCpus * fraction` and
`max(1GB, TotalMem * 0.10)` via `ifThenElse`: 10% of a 4 GB SBC is 410 MB, too
little to avoid thrashing, while 25% of a 30 GB box is 7.5 GB, needlessly idle.
One expression, correct at both ends.

**CPU contention suspends. Memory pressure evicts. Time does nothing.**
A suspended job costs the owner no CPU at all - `SIGSTOP` means it is not
scheduled - so discarding its work merely because time passed is pure waste.
Memory is the one resource suspension cannot return: `SIGSTOP` freezes a
process but keeps its RSS. So memory pressure is the only justification for
killing, and when it fires reclaim is immediate (`MaxJobRetirementTime = 0`,
then 30s to exit cleanly before SIGKILL).

Thresholds are **busy cores measured against the reservation**, not arbitrary
numbers. On a 4-core box donating 2, SUSPEND at `> 2.0` means "the owner now
needs more than the 2 cores reserved for them". CONTINUE at `< 1.0` is
deliberate hysteresis - equal thresholds make jobs flap.

| setting | value | rationale |
|---|---|---|
| `CGROUP_MEMORY_LIMIT_POLICY` | `none` | **no per-job cap** - see below |
| `JOB_RENICE_INCREMENT` | 10 | covers the lag: load average is a decaying 1-minute mean and reacts in tens of seconds. Renice makes jobs yield the CPU instantly |
| `MaxJobRetirementTime` | 300 | too short wastes work, too long makes owners wait |
| `condor-kbdd` | installed | needed for console attributes, but see the warning below |

### No per-job memory ceiling

`hard` enforces `request_memory` as an absolute per-job limit, so a job asking
256 MB is OOM-killed at 256 MB with 14 GB free. On 4-16 GB machines that forces
everyone to over-request - wasting the RAM the fleet does not have - and turns
honest requests into spurious failures. `request_memory` stays a **matchmaking
figure only**; memory is protected system-wide by eviction instead.

The margin is a **fraction of installed RAM**, not an absolute floor: 2 GB is
12% of a 16 GB desktop and half of a 4 GB SBC, and the fleet spans both.

`HostMemAvailMB` / `HostMemTotalMB` come from the STARTD_CRON job - Condor
publishes no free-memory attribute. `MemAvailable` is used rather than
`MemFree`, which ignores reclaimable page cache and would report false pressure
on any long-running machine.

Two traps in that expression:

- **Do not gate eviction on `Activity == "Suspended"`.** SUSPEND fires on CPU
  load, so a job quietly eating RAM without loading the CPU would never suspend
  and therefore never be preempted - unenforceable in exactly the case that
  matters.
- **Guard with `HostMemAvailMB > 0`.** Before the cron's first run the attribute
  is 0 or UNDEFINED, and a bare comparison reads as pressure - evicting every
  job the moment the startd starts.

### Presence must not gate admission

`OwnerSessionActive` is published and useful for diagnostics, but it is
deliberately **not** in `START`. People do not log out: on any desktop the
attribute reads True essentially forever, so gating admission on it makes the
machine advertise its cores and refuse everything, permanently - indistinguishable
from a healthy idle machine.

The policy reacts to local **work**, not to a human existing. If they start doing
something, load and PSI catch it within seconds. Presence alone costs them
nothing, because Condor jobs already yield the CPU instantly.

This only surfaced when the first machine that is both **small** and **actually
in use** joined. Servers and headless boxes never expose it.

### The policy is inert without the stanza that feeds it

Every attribute the policy references comes from the `STARTD_CRON` job. Without
that stanza the config still **parses**, `condor_config_val` still reports the
correct expressions, and `condor_status` still shows a healthy `Unclaimed/Idle`
slot - while `START` evaluates to `UNDEFINED` and both admission control and
eviction are silently dead.

`UNDEFINED` is **worse than `false`**: a false `START` parks the slot in `Owner`
state, which is visible. Undefined leaves it displaying `Unclaimed/Idle`,
indistinguishable from healthy.

This was introduced twice by edits that replaced the policy section wholesale
and took the stanza with it. Keep the stanza **above** the policy header, and
after any config edit verify the attributes are on the **slot ad**, not merely
in the config:

```
condor_status -af Name Start OwnerSessionActive HostMemAvailMB HostDiskAvailMB
```

Note the collector only sees a changed ad on the startd's next update
(`UPDATE_INTERVAL`, default 300s), so a newly published attribute can read
`undefined` for several minutes without anything being wrong. A `condor_reconfig`
forces a fresh ad.

### Do not write this policy against ConsoleIdle or KeyboardIdle

On a **partitionable** slot, the machine-level attributes behave differently on
the dynamic slots where jobs actually run:

| attribute | partitionable parent | dynamic slot |
|---|---|---|
| `ConsoleIdle` | real value | **absent (UNDEFINED)** |
| `KeyboardIdle` | real value | `-1` sentinel |
| `LoadAvg` | real value | `-1.0` sentinel |
| `TotalLoadAvg`, `TotalCondorLoadAvg` | real | **real** |
| STARTD_CRON attributes | present | **present** |

One UNDEFINED term makes an entire `&&` chain non-TRUE, so a policy written
against `ConsoleIdle` leaves every dynamic slot in state `Owner`, refusing every
claim - while the parent still reports `Unclaimed/Idle` with `Start = true`.

**This failure is invisible from `condor_status`.** The pool looks healthy, jobs
sit Idle forever, and `condor_q -better-analyze` reports "1 are able to run your
job". Only `StartLog` shows `Request to claim resource refused` /
`Claiming protocol failed`. Use the machine-wide `Total*` attributes.

`KeyboardIdle` is separately wrong on any administered machine: it counts
activity on **any tty, including ssh ptys**, so an admin session makes the box
look permanently busy. Measured with nobody present: `KeyboardIdle = 2` while
`ConsoleIdle = 359657`.

### Detecting remote users

`condor_kbdd` only sees the local X console. On machines used over RDP or VNC it
is blind to the actual user. A `STARTD_CRON` job publishing an
`OwnerSessionActive` attribute - derived from established connections on the
remote-desktop port plus active non-greeter graphical sessions - covers that,
and unlike the console attributes it *does* propagate to dynamic slots.

### Adoption

`RANK = (RemoteOwner =?= "<owner>")` gives each owner first call on their own
machine, including preempting a stranger's job. This is the adoption lever -
"I contribute and still get my PC first".

Failure mode to avoid: nobody files a bug when Condor makes their PC stutter.
They run `systemctl disable condor` and the pool shrinks silently.

## 7. Workload constraints

Eviction is the normal case, not an exception. Users must be told this up front.

- Many short jobs, not few long ones. A 10-hour job on a desktop may never complete.
- Jobs must be idempotent — restartable from scratch without corrupting state.
- Long work uses self-checkpointing (`checkpoint_exit_code`).
- "My job keeps restarting" is a design property of a desktop pool, not a bug.

## 8. Scheduling and fairness

| mechanism | purpose |
|---|---|
| `condor_userprio` fair-share | heavy recent users decay in priority automatically |
| Machine `RANK` | owner preference on own hardware |
| `NEGOTIATOR_PRE_JOB_RANK` | fill the entry node last |
| `MAX_JOBS_RUNNING` | ceiling on concurrent shadows; converts "entry node falls over" into "jobs stay queued" |
| `MAX_TRANSFER_INPUT_MB` | refuse fat submissions rather than filling spool |

## 9. Data movement

All job I/O funnels through the shadows on the entry node. This is the pool's
scaling limit — not CPU, not RAM.

| condition | approach |
|---|---|
| MB-scale jobs | `transfer_input_files`, indefinitely fine |
| GB-scale jobs | shared storage + `FILESYSTEM_DOMAIN` so matched jobs skip transfer entirely |
| Jupyter home dirs | NFS export required — scratch sandboxes evaporate, notebooks must persist across sessions and across workers |

The scaling answer is not transferring the data, not a bigger entry node.

## 10. Security and trust

| item | decision |
|---|---|
| Authentication | IDTOKENS; token per user in `~/.condor/tokens.d/` |
| Transport | single TCP port 9618 via `condor_shared_port` |
| Entry-node accounts | system accounts only — `--no-create-home --shell /usr/sbin/nologin` |
| Account per user | distinct UIDs, not a shared one — required for fair-share and spool isolation |
| Worker accounts | none, ever. Jobs run as `nobody` in a scratch sandbox |
| Job isolation | **decide now**: jobs can read world-readable files and use the network on any machine they land on. If unacceptable, Apptainer for every job from day one |

Retrofitting containerization onto an established pool is far harder than
starting with it.

## 11. Naming and networking

Nothing in the pool config names a machine or an IP. Concrete values live in
`condor-host-list`; placeholders below.

| layer | value | resolved how |
|---|---|---|
| Pool entry point | `<pool>-htcondor-entry-node.local` | mDNS alias, republished if the address moves |
| Daemon advertised names | same role name | `NETWORK_HOSTNAME` on the entry node |
| Principal namespace | `<pool>.internal` | never resolved; keeps IDTOKENS stable across naming changes |
| Host qualification | `DEFAULT_DOMAIN_NAME = local` | satisfies `get_full_hostname()` *and* is avahi-resolvable |
| Worker addresses | advertised in each ClassAd | Condor dials them directly |
| `FILESYSTEM_DOMAIN` | per-host default, never pool-wide | a shared value makes Condor skip file transfer entirely |

### Why names, not addresses

Condor routes by **advertised address** - the sinful string each daemon puts in
its ClassAd - never by resolving a name at connect time. A worker that changes
IP is reachable again at its next collector update, so **DHCP churn on workers
needs no DNS, no hosts file, and no action**. Only the entry node must be
findable by name, because every worker's `CONDOR_HOST` points at it.

### Why the pool must have a domain

`condor_submit -remote` and `condor_q -name` call `get_full_hostname()`, which
**rejects any name without a dot**. A pool of bare hostnames cannot use remote
submission at all. `DEFAULT_DOMAIN_NAME = local` qualifies them and stays
resolvable through avahi via nsswitch (`files mdns4_minimal ... dns mdns4`).

### A multi-homed entry node cannot serve two unroutable networks

Attempted: dual-home the entry node (wired + wifi) so machines on both networks
could reach it, treating it as a star hub. It does not work, and the way it fails
is expensive.

`BIND_ALL_INTERFACES` is true and the daemons listen on `0.0.0.0:9618` - they
**accept** on every address. But a daemon advertises **one primary address** in
its sinful string, and peers are told to dial that. So:

| direction | initiator | result |
|---|---|---|
| worker -> collector (register, update) | worker dials `CONDOR_HOST` | works - outbound |
| shadow -> startd (claim) | entry node dials the worker's address | works |
| **starter -> shadow (file transfer)** | **worker dials the shadow's advertised address** | **fails** |

Three of four directions work. The machine registers, jobs match, jobs **run to
completion** - and then the return channel fails and the work is discarded:

```
ERROR "Error from slot1_1@...: Could not initiate file transfer"
```

The job is re-queued and loops forever, burning slots, while `condor_status`
shows a healthy machine. Pinning `NETWORK_INTERFACE` does not fix it - it only
moves the breakage to the other network. There is no single address both
networks can reach, and Condor will not advertise two.

**Put every pool member on one network**, by cable or by overlay VPN. A machine
with unplugged ethernet ports on a wifi-only config is one cable away from
working; that is cheaper than any of this.

### Why a role alias failed, and was retired

Config points at the *role*, not at whichever machine holds it. Moving the entry
node = start the alias service on the new box, stop it on the old one. No worker
changes. Two pieces are needed together:

- **mDNS alias** - fixes ADDRESS lookups (`CONDOR_HOST`, `COLLECTOR_HOST`).
  avahi has no CNAME support, so a small service publishes `avahi-publish -a`
  and republishes if the machine's address changes. Publish with `-R`: the real
  hostname already owns the reverse record, and a second one makes reverse
  lookups ambiguous - which breaks Condor's security layer, not DNS.
- **`NETWORK_HOSTNAME`** - fixes NAME lookups. Without it the schedd still
  advertises its hardware name and `-remote <alias>` fails with
  "Can't find address of schedd". `SCHEDD_NAME` cannot substitute: with no `@`
  it becomes `$(SCHEDD_NAME)@$(FULL_HOSTNAME)`.

**This was retired.** `avahi-publish -a` binds a name to ONE literal address
with no interface awareness, so the alias answered every querier with the same
address regardless of which network they were on. A machine's **own** hostname
behaves differently: avahi answers per-interface, giving each querier the address
it can actually reach. Verified from both sides - the same real hostname resolved
to the wired address from the wired LAN and the wifi address from wifi.

Worse, `NETWORK_HOSTNAME` pointing at the alias forced the daemons to bind and
advertise that single address, which is what broke file transfer above.

Use the entry node's real hostname for `CONDOR_HOST`. The cost is losing role
indirection: relocating the entry node means updating `CONDOR_HOST` on each
worker. Correctness across networks beats the abstraction.

### Why UID_DOMAIN is deliberately different

`UID_DOMAIN` is a principal namespace, never resolved as a hostname. Keeping it
distinct from `DEFAULT_DOMAIN_NAME` means the naming scheme can change without
invalidating every IDTOKEN. Tokens carry `<user>@<pool>.internal`.

**Changing `UID_DOMAIN` invalidates every token.** Old tokens still authenticate
but map to a different principal, silently splitting fair-share accounting.

### Operational notes, learned the hard way

- Changing `DEFAULT_DOMAIN_NAME` or `NETWORK_HOSTNAME` changes daemon names, so
  it needs a **restart**, not `condor_reconfig`.
- **Install config and restart in one step.** A daemon that fails to resolve the
  collector at startup does not retry until its next update interval (schedd:
  `SCHEDD_INTERVAL`, default 300s), leaving ads missing for minutes.
- `CONDOR_HOST = $(FULL_HOSTNAME)` stops resolving the moment the domain
  changes, until that name resolves **on the entry node itself**. Daemons come
  up but cannot reach their own collector.
- Hold code 16 (`Spooling input data files`) is transient and normal during
  `-spool` submission, not a failure.
- avahi can serve cached names for dead hosts, and `getent` may return an IPv6
  link-local address for a `.local` name where avahi's IPv4 answer is correct.
  Neither has broken anything yet; both are plausible sources of intermittent
  failures.

Vanilla-universe jobs need no worker-to-worker connectivity - every conversation
is entry <-> worker. The entry node is a star hub, not a router.

## 12. Heterogeneity

| item | detail |
|---|---|
| Architectures | x86_64 + aarch64 |
| Default safety net | `condor_submit` pins `Requirements` to the submitting machine's arch — ARM capacity is invisible until opted into |
| Cross-arch jobs | interpreted code or multi-arch containers only |
| Condor versions | distro-supplied versions differ per OS. Pin deliberately; the central manager should not be older than its workers |
| GPUs | `condor_gpu_discovery`, `DetectedGPUs`, `request_gpus`. Jetson iGPU detection under L4T is not reliably clean — verify, do not assume |

Three distros and two architectures is where "just ship the binary" stops working.

## 13. Deployment

Config management is the bulk of the work, not scheduling. Every machine needs
install, config, token, and repeated owner-policy revisions.

| item | decision |
|---|---|
| Channel | `../ssh-tunnel/ssh-tunnel.py` — already the authenticated fan-out to every host |
| Layout | `/etc/condor/config.d/` drop-ins, rendered from this repo |
| Loop | render → push → `condor_reconfig` |
| Slot changes | require `condor_restart` of the startd, not `condor_reconfig` |
| Verification | `condor_config_val -v <KNOB>` — never trust the file, `config.d` precedence bites |

## 13a. Restart and recovery

Verified by rebooting the entry node.

### What survives a reboot

Everything, provided the services are enabled: config drop-ins, the mDNS alias
service, `/usr/local/bin` helpers, the pool signing key, and - importantly - the
**job queue**. Completed jobs were still in `job_queue.log` afterwards.

The pool also degrades gracefully rather than failing: with the worker absent it
ran a 6-job cluster on the entry node's 2 cores, queueing the rest.

### A central-manager restart costs ~2 x UPDATE_INTERVAL of worker capacity

Workers do **not** come back promptly. Observed sequence:

```
17:19:41  collector starts as a NEW process
17:19:45  worker MASTER update  -> "SECMAN: Server rejected our session id"
17:24:00  worker STARTD update  -> "SECMAN: Server rejected our session id"
17:29:00  worker STARTD update  -> succeeds, re-registers
```

Each daemon holds a cached security session tied to the *old* collector process.
It spends one full update cycle discovering the session is dead, invalidates it,
and only re-authenticates on the **next** cycle - about 10 minutes at the default
300s `UPDATE_INTERVAL`.

It self-heals with no intervention, but **nothing in `condor_status` explains
it** - the machine is simply missing. With many workers they all disappear
together after any entry-node restart. The evidence lives in `CollectorLog`
(`DC_AUTHENTICATE: attempt to open invalid session`) and the worker's own log
(`SECMAN: Invalidating negotiated session rejected by peer`). Restarting condor
on a worker clears its sessions and re-registers it immediately.

### Startup ordering must be enforced, not assumed

`CONDOR_HOST` is an mDNS name published by the alias service. At boot both
started **in the same second** and it worked only by a hair. If condor wins that
race, its daemons come up unable to reach their own collector and each sits out a
full update interval - the pool looks alive and does nothing.

`After=` alone is insufficient: the alias service is `Type=simple`, so systemd
considers it started the moment it execs, before `avahi-publish` has established
the name. Wait for the **condition** instead, via an `ExecStartPre` that blocks
until the name resolves. Ship it as a `condor.service.d/` drop-in - editing the
packaged unit gets silently reverted on upgrade - and have the script always exit
0 so a slow name can never hang a boot.

### Do not list a daemon whose package is not installed

`KBDD` in `DAEMON_LIST` without `condor-kbdd` present makes the master log
`Cannot execute (errno=2)` and retry every ~34 minutes forever. Workers whose
policy does not reference `ConsoleIdle`/`KeyboardIdle` should not run it at all.

## 14. Phases

| phase | scope | status |
|---|---|---|
| 0 | Entry node install. Single-machine pool. Prove submit path | **done** |
| 3 | Remote submission: IDTOKENS + 9618, no shell anywhere | **done** (brought forward) |
| — | Role-based mDNS naming; no IPs or hostnames in config | **done** |
| — | Contention-driven owner policy on the entry node | **done** |
| 1/2 | Add a second worker; daemon token; jobs distribute | **done** |
| 4 | JupyterHub + batchspawner CondorSpawner | not started |
| 5 | ARM workers; GPU discovery | not started |
| 6 | Overlay VPN for off-LAN machines | deferred by decision |

Phase 3 was pulled ahead of 1 and 2 because it is the requirement the whole
design exists to satisfy; proving it early de-risked the rest.

### Adding a worker

1. Install the package.
2. Drop in the worker config: pool alias, `DEFAULT_DOMAIN_NAME`, `UID_DOMAIN`,
   pinned `NETWORK_INTERFACE`, donation limits, owner policy, STARTD_CRON.
3. Install `condor-owner-session` to `/usr/local/bin` (755).
4. Install a **daemon** token to `/etc/condor/tokens.d/` (600 root).
5. Restart, then confirm it appears in `condor_status` **and** that a job lands
   on it.

Step 4 is the one that is easy to miss. A user token does not satisfy
`ALLOW_DAEMON`; without a daemon credential the worker starts cleanly, fails to
register, and simply never appears - no error surfaces at the client.

Do not test daemon auth with `condor_ping ... DAEMON` as an unprivileged user:
it cannot read the root-owned token, falls back to SSL, and blocks on an
interactive trust prompt. Check pool membership instead.

## 15. Open decisions and risks

| item | status |
|---|---|
| **A third machine on a separate network cannot complete jobs.** It registers, matches and runs work, then fails to return output because the entry node advertises a single address the machine cannot route to | **Blocked.** Fix is one network - a cable, or the overlay VPN. Do not attempt to serve two unroutable networks from one multi-homed entry node |
| The role alias for the entry node has been **retired** | Resolved. `avahi-publish` is not interface-aware; a machine's own hostname is. `CONDOR_HOST` now names the machine, so relocating the entry node means editing every worker |
| **Entry node SPOOL shares an 86%-full volume with the OS**, along with EXECUTE and `job_queue.log` | **Mitigated, not fixed.** Transfer caps and disk tiers are the whole defence. The structural fix is SPOOL on its own filesystem, where exhausting it degrades the pool instead of destroying the machine |
| Both hosts now run the same cron script and the same two-tier policy shape, differing only where the schedd role requires it | **Resolved.** Differences are documented in section 5, not drift |
| A central-manager restart removes every worker from the pool for ~2 x `UPDATE_INTERVAL` (~10 min) while stale security sessions are discovered and re-negotiated | **Understood, not mitigated.** Self-heals; invisible in `condor_status`. Lower `UPDATE_INTERVAL` if that window matters |
| Nothing has been tested **under real load** - no suspend, eviction, or admission-closure has been observed happening | **Untested.** Verify before other people's machines join |
| `request_disk` may be advisory rather than enforced, like `request_memory` | **Unverified.** If advisory, one job can fill the disk regardless of what it asked for, and the admission tier is the only protection |
| cgroup per-job enforcement does not work on the installed build | **Resolved by decision, not by fix.** Per-job caps are not wanted on machines this size; memory is protected system-wide by eviction. `CGROUP_MEMORY_LIMIT_POLICY = none` makes the config honest about it |
| Memory eviction is only as fresh as the STARTD_CRON period (20s) | **Accepted.** A job can allocate hard within that window. The kernel OOM killer is the backstop, and it may pick the wrong victim |
| A job can stay suspended indefinitely on a persistently busy machine, holding its claim and RSS | **Accepted deliberately.** It resumes when load drops. If it becomes a problem the fix is a cap on suspended time, not a shorter PREEMPT |
| `JOB_RENICE_INCREMENT` | **verified working** (job niceness 10) |
| `nproc` inside a job reports `request_cpus` | comes from `OMP_NUM_THREADS`, **not** enforcement - cpuset still shows all cores |
| Entry node is an actively-used desktop owned by another user | **Risk.** Single point of failure; must be always-on. Give it a DHCP reservation |
| Remote submit without local Unix accounts | **Still unverified** - the test user already had an account on the entry node |
| Job isolation model (bare vs Apptainer) | **Undecided.** Blocks phase 1 if the answer is containers |
| Jetson GPU discovery | **Unverified** |
| Shared storage for Jupyter homes | **Required, unprovisioned** |
| `MAX_TRANSFER_INPUT_MB` | set to 2048 as a starting guard; unvalidated against real workloads |
| Off-LAN machines | mDNS is link-local. Deferred by decision |
