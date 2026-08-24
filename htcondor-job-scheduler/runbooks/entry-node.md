# Entry node

The pool's single point of failure and the only machine that needed careful
engineering. Everything else in the fleet is interchangeable; this one is not.

Config: `scripts/50-entry-node.config`.

```
DAEMON_LIST = MASTER, COLLECTOR, NEGOTIATOR, SCHEDD, STARTD, SHARED_PORT
```

Also a limited worker, deliberately: half its cores donated, the rest reserved.

## Choosing the machine

A **commodity 4-core mini-PC**, not the highest-core machine, and the reasoning
matters because the instinct is the opposite.

The role is bounded by `fsync` latency on `job_queue.log`, RAM per shadow, and
NIC bandwidth. Not CPU. Sixteen threads buy nothing here, and spending the
fleet's only high-core machine on this role wastes its one scarce resource.

The 4-core class is also the repeated unit, so testing on it teaches something
transferable. Scaling is horizontal: add schedds, or split collector and
negotiator off. Never vertical.

Requirements: `SPOOL` on NVMe, always-on, and **a stable address**. Every
worker's `CONDOR_HOST` resolves this machine by mDNS, so a reservation on the
router is not strictly required, but the NetworkManager hook below exists
precisely because its address does move.

## Why its settings differ from a worker's

**Thresholds must be looser.** `condor_shadow` processes are children of the
**schedd**, not the startd, so they are not counted in `CondorLoadAvg`. Every
file transfer this machine brokers for the whole pool lands in `NonCondorLoad`
and looks like owner activity. Worker-tight thresholds would make it close
admission, and flap its own jobs, purely for doing its job.

**Scale on `DetectedCpus`, not `TotalCpus`.** `NUM_CPUS` caps what it advertises
while `TotalLoadAvg` is measured across the whole machine. Scaling by `TotalCpus`
compares a 4-core load against a 2-core yardstick, so it reads as saturated with
half of itself idle.

**Disk floors are absolute, not fractional.** `SPOOL`, `EXECUTE`,
`job_queue.log` and the OS share one volume that is already ~86% full of
unrelated data. A percentage of a large mostly-full disk is the wrong shape; a
fixed reserve is right.

**It keeps the reservation ledger.** Workers publish measured memory headroom
from the `STARTD_CRON` job; this machine does not, and the script detects that
itself by checking for `SCHEDD` in `DAEMON_LIST`. Its failure is not local, the
reservation protects one shadow per running job pool-wide, and its
`RESERVED_MEMORY` is large on purpose.

## SPOOL cannot be defended by the startd policy

`condor_submit -spool` writes into `SPOOL` at **submit** time, before any
matchmaking, so `START` never sees it. The only controls are schedd-side:

```
MAX_TRANSFER_INPUT_MB  / MAX_TRANSFER_OUTPUT_MB
```

At 2048 MB per job with 32 G free, sixteen concurrent submissions fill the
volume, and `MAX_JOBS_RUNNING` permits 200. **Filling SPOOL stops the schedd
writing its queue, which stops the entire pool**, not just one machine.

Completed spooled jobs also hold their spool directory for `LeaveJobInQueue`'s
window, **864000 seconds by default, ten days**, whether or not the output was
retrieved. `tools/pool-run` releases it; submitting by hand and walking away
does not.

## Naming and addressing

`CONDOR_HOST` on every worker is this machine's **real hostname**, resolved by
mDNS. avahi answers for a machine's own name **per interface**, so one value
resolves to whichever address is reachable from wherever the worker is.

**The role alias was retired and must not come back.** `avahi-publish -a` binds
a name to one literal address with no interface awareness, so an alias hands the
same address to every querier including machines that cannot route to it. That
is what broke the multi-homed pool. The cost of the real hostname is that moving
the entry node means editing `CONDOR_HOST` on every worker; correctness across
networks beats the abstraction.

**Multi-homing.** This machine holds two addresses and publishes both:

```
PRIVATE_NETWORK_NAME      = $(FULL_HOSTNAME)
PRIVATE_NETWORK_INTERFACE = <interface on the private segment>
```

Peers choose between them. Workers derive which to use at startup rather than
being configured, so no machine holds a network fact.

**Retiring any name means finding every consumer, not every worker.** When the
alias was removed, the entry node and both workers were checked; the submit-only
client was not, and remote submission from it broke silently until that machine
was next touched.

## What it needs that workers do not

**A NetworkManager hook for its own addresses.** Workers watch whether their
*derivation* changes. This machine derives nothing, so a worker-style hook is
silent when one of its own addresses moves. Observed: its wifi roamed to another
subnet, the collector kept advertising an address that no longer existed, and
nothing recovered until that address happened to return. `tools/60-condor-network-change`
restarts on either trigger.

**No registration watchdog.** Workers get one; this machine does not. Its startd
registers with a collector on the same machine, so a failure there is a different
problem, and restarting condor to fix one slot would disrupt every worker.

**Startup ordering enforced, not assumed.** `CONDOR_HOST` is an mDNS name, and at
boot condor and avahi started in the same second. `After=` is insufficient
because a `Type=simple` unit counts as started the moment it execs. Wait for the
**condition** with an `ExecStartPre` that blocks until the name resolves, and
have it always exit 0 so a slow name cannot hang a boot.

```
sudo install -m 755 scripts/condor-wait-for-name \
     /usr/local/bin/condor-wait-for-name ; sudo -k
sudo install -d -m 755 /etc/systemd/system/condor.service.d ; sudo -k
sudo install -m 644 scripts/condor-ordering.conf \
     /etc/systemd/system/condor.service.d/condor-ordering.conf ; sudo -k
sudo systemctl daemon-reload ; sudo -k
```

**Pin its wifi to one network.** It roamed to a different SSID, landed on the
wrong subnet, and took the pool down. Remove every wifi profile except the
intended one.

## Restarting it is expensive

Every worker loses roughly **two update intervals** while cached security
sessions tied to the old collector process are discovered dead and renegotiated.
Nothing in `condor_status` explains it: the machines are simply missing. With
many workers they all disappear together, which looks like a catastrophe and is
not.

The queue survives a reboot. Completed jobs were still in `job_queue.log`
afterwards, and the pool degraded gracefully rather than failing.

## Issuing tokens

```
umask 077
sudo condor_token_create -identity condor@<pool>.internal > <file>
```

`condor@*` matches `ALLOW_DAEMON`. A **user** token does not satisfy it, and a
worker given one starts cleanly, never registers, and reports nothing.

Move it straight to the target machine and shred every intermediate copy, as its
own step. It is a bearer credential with no machine binding, and there is no
per-token revocation short of rotating the pool signing key, which invalidates
everyone's.

## Also hosts the dashboard

`pool-sample`, `pool-plots` and `pool-web` from `tools/pool-web/`, served at
`http://<entry-node>.local/condor-status/`. Two sandbox constraints, both learned
the hard way:

- **`PrivateTmp` must not be set** on `pool-sample`. FS authentication needs a
  `/tmp` that is writable *and* shared; a private one makes the method vanish
  from the list rather than fail in it.
- **`ProtectSystem=full`, not `strict`.** `strict` makes `/tmp` read-only, so the
  client cannot create the file FS auth depends on.
