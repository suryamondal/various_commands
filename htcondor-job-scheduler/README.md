# HTCondor pool policy

Pooling office PCs into a batch system users treat as an extension of their own
machine.

Status: **phase 0 complete** - single-machine pool running, remote submission
working from a second machine with no login, no shared filesystem, and no home
directory on the entry node.

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

| setting | desktop / laptop | entry node | flagship | edge SBC |
|---|---|---|---|---|
| `NUM_CPUS` | n−1 | 2 (of 4) | 12 (of 16) | 2 (of 4) |
| `RESERVED_MEMORY` (MB) | 4096 | 10240 | 12288 | 2048 |
| `RESERVED_DISK` (MB) | 20480 | 20480 | 20480 | 20480 |
| Slot model | partitionable | partitionable | partitionable | partitionable |

The flagship reserves heavily: it runs a production database. A DB whose page
cache is evicted does not crash, it gets slow.

Edge SBC restrictions: SD-card storage (write endurance), runs a wireless AP and
other listening services. Small slot, no I/O-heavy work.

## 6. Owner policy — contention-driven, mandatory on every worker

The trigger is local **work** appearing, not a human being detected. When the
machine's own workload grows, Condor jobs suspend; if contention persists they
are evicted.

```
NonCondorLoad = (TotalLoadAvg - TotalCondorLoadAvg)

START    = (OwnerSessionActive =!= True) && (NonCondorLoad < 1.0)
SUSPEND  = (NonCondorLoad > 2.0)
CONTINUE = (NonCondorLoad < 1.0)
MEM_MARGIN_FRACTION = 0.15
PREEMPT  = (HostMemAvailMB > 0) && (HostMemAvailMB < (HostMemTotalMB * MEM_MARGIN_FRACTION))

MaxJobRetirementTime = 0
MachineMaxVacateTime = 30
KILL     = FALSE
```

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

### Why a role alias

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

Cost: `condor_status` shows the entry node's slot under the role name, hiding
its hardware hostname. Jobs still see the real machine - `NETWORK_HOSTNAME`
changes Condor's naming, not the OS hostname - so diagnostics are not lost.

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

## 14. Phases

| phase | scope | status |
|---|---|---|
| 0 | Install on entry node. Single-machine pool. Prove submit path | **done** |
| 3 | Remote submission: IDTOKENS + 9618, no shell anywhere | **done** (brought forward) |
| — | Role-based mDNS naming; no IPs or hostnames in config | **done** |
| 1 | Add one x86 worker. Owner policy, cgroups, kbdd | blocked on cgroups |
| 2 | Add flagship worker | not started |
| 4 | JupyterHub + batchspawner CondorSpawner | not started |
| 5 | ARM workers; GPU discovery | not started |
| 6 | Overlay VPN for off-LAN machines | not started |

Phase 3 was pulled ahead of 1 and 2 because it is the requirement the whole
design exists to satisfy; proving it early on two machines de-risks the rest.

## 15. Open decisions and risks

| item | status |
|---|---|
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
