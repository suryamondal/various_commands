# Worker: x86 desktop / mini-PC

The fleet's repeated unit. Four in the pool: the entry node (also a limited
worker), the 16-thread flagship, and two 4-core desktops in daily use.

Config: `scripts/50-worker.config`, or `50-user-pc.config` if the owner also
submits from it.

## Sizing

| | value | why |
|---|---|---|
| `NUM_CPUS` | unset | all threads offered; `JOB_RENICE_INCREMENT` makes jobs yield instantly |
| `RESERVED_MEMORY` | ~10% of installed | 1600 on 16 G, 3000 on 31 G |
| `RESERVED_DISK` | 20480 | **check free space first**, see the Jetson runbook for why |
| load thresholds | 0.50 admit / 0.75 suspend | 0.25 is below a 4-core desktop's idle floor |

## The network trap: a VPN interface

Condor advertises the most *public* address it finds, and its private set is
RFC1918 only. **Tailscale's `100.64/10` is not in that set**, so on a machine
running tailscale the overlay address is a candidate for the advertised one.
Measured: the entry node cannot reach `100.x` at all, so the worker would
register, match, run jobs to completion, then fail to return output while
`condor_status` showed it healthy.

On a machine with a VPN interface, pin it:

```
NETWORK_INTERFACE = <the pool-facing interface>
```

Choose the segment the entry node's **primary** address is on, so entry-to-worker
takes the direct path. Cost: the line is wrong if the machine's attachment ever
changes.

**The pin only constrains IPv4.** The overlay's global IPv6 can still appear in
`addrs=`, because the pool interfaces carry only link-local `fe80::`. Nothing
has failed from this, since the entry node advertises and dials IPv4, but check
`addrs=` and not just the primary. `ENABLE_IPV6 = FALSE` closes it.

A machine with no VPN interface needs no pin, even if dual-homed on both pool
segments: either address is reachable.

## Owner policy

Applies in full and unmodified. These are people's daily drivers, so `SUSPEND`
on CPU contention and `PREEMPT` on memory pressure will both fire in normal use.

Set `RANK` if the owner has a Condor identity:

```
RANK = (RemoteOwner =?= "<user>@<pool>.internal")
```

That is the adoption lever, and the only thing an owner gets for joining that a
donated-only machine does not.

## Verify

```
condor_status -af Name Start HostMemAvailMB HostCpuPsiAvg10 HostDiskAvailMB
```

Attributes present means the `STARTD_CRON` job is feeding the policy. Absent
means the policy is inert while everything still looks healthy.

Then land a job on it. Appearing in `condor_status` is not the same thing.
