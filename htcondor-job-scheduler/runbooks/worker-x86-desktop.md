# Worker: x86 desktop / mini-PC

The fleet's repeated unit. Five in the pool: the entry node (also a limited
worker), the 16-thread flagship, and three 4-core desktops in daily use.

Config: `scripts/50-worker.config` for a donated machine, a per-machine variant
where sizing or interface differs, or `50-user-pc.config` if the owner also
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

## The other network trap: a host firewall

Check `ufw` before declaring the machine done. One desktop in the fleet had it
active and no other did, which is what makes this easy to miss.

The symptom is not a machine that fails to appear. It registers, publishes
every attribute, reads `Unclaimed` with `Start = true`, and the negotiator
matches jobs to it happily:

```
Matched 55.0 ... slot1@<host>
Successfully matched with slot1@<host>
```

Then nothing runs, because the **schedd cannot connect back** to claim it:

```
Failed to send REQUEST_CLAIM to startd slot1@<host> <...:9618...>
  SECMAN:2003: TCP connection to startd ... failed
```

It retries once a minute forever. `condor_status` never stops looking healthy,
and `condor_q -analyze` reports *"1 are able to run your job"* - because the
analysis is about requirements, and the requirements really do match. Only
`SchedLog` names the cause.

Worth knowing which direction is at fault: the worker reaches the entry node
fine, because outbound is allowed and the collector update is worker-initiated.
It is entry-to-worker that is dropped. Testing reachability from the new
machine proves nothing.

```
sudo ufw status verbose ; sudo -k
sudo ufw allow from <wifi-segment>/23  to any port 9618 proto tcp ; sudo -k
sudo ufw allow from <wired-segment>/23 to any port 9618 proto tcp ; sudo -k
```

One port covers everything: `condor_shared_port` multiplexes every daemon onto
9618, and `ss -ltn` on a working worker shows exactly one listener.

**Take the prefix from the machines, not from the DHCP lease.** Both pool
segments are `/23`; the wifi DHCP server nonetheless hands out a `/24`, which is
why `50-widen-wifi-prefix` exists. Write the rule from what `ip -br addr` shows
on the entry node, not from what the lease says. A rule one bit too narrow works
until some machine's lease lands in the upper half of the range, at which point
this whole failure returns with no configuration having changed - and the
addresses are DHCP, so that is a matter of timing rather than of design.

Concrete prefixes are in `condor-host-list`.

Scope to the subnets rather than to the entry node's address. Its address is
expected to move between segments - that is what the NetworkManager hook is
for - so a host-scoped rule breaks the next time it roams.

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

Then land a job on it. Appearing in `condor_status` is not the same thing - the
firewall case above passes every check on this page except this one.
