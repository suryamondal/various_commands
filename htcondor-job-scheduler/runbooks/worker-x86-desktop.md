# Worker: x86 desktop / mini-PC

The fleet's repeated unit. Seven in the pool: the entry node (also a limited
worker), the 16-thread flagship, and five 4-core desktops in daily use.

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

## Rename the machine first, and it is four steps not one

Three machines arrived named after their account rather than the fleet
convention. Do this **before condor first starts** - `FULL_HOSTNAME` is read at
daemon start, so a rename afterwards means a stale ad in the collector until the
startd restarts. Caught in time on all three; nothing had to be undone.

`hostnamectl` alone is not enough. Each of these is separately load-bearing:

```
sudo hostnamectl set-hostname <new> ; sudo -k
sudo sed -i.bak "s/^127\.0\.1\.1[[:space:]].*/127.0.1.1\t<new>/" /etc/hosts ; sudo -k
printf 'preserve_hostname: true\n' | sudo tee /etc/cloud/cloud.cfg.d/99-preserve-hostname.cfg ; sudo -k
sudo systemctl restart avahi-daemon ; sudo -k
```

**`/etc/hosts` is not touched by `hostnamectl`.** On all three machines the
`127.0.1.1` line still named the old host, and Condor resolves the local name.

**cloud-init ships `preserve_hostname: false`** on Ubuntu Server and will revert
the name from its datasource at the next boot. The change looks like it worked
until something reboots weeks later. The drop-in settles it without editing the
packaged `cloud.cfg`.

**avahi does NOT pick up the rename.** Measured on every one of them: it kept
answering for the old name and timed out on the new one until restarted.

A worse version of the same thing turned up on the machine that had been in the
pool longest: avahi **had never published an A record for itself at all**. It was
`active`, listening on 5353, and resolving every *other* machine's `.local` name
correctly - so every check short of the right one passed. What failed was the
reverse direction: nothing could resolve it, including itself.

```
getent hosts $(hostname).local     # on the machine itself - expect an address
```

Run that on any machine you add. It went unnoticed for as long as it did because
every path to that host used a literal IP, and Condor dials the address in the
sinful string rather than the name - so the pool worked perfectly while the name
did not exist. A restart of `avahi-daemon` fixed it.

**If condor is already running, restart it too.** These renames were all done
before first start, where a config reload is enough. On a machine already
registered, `FULL_HOSTNAME` is read only at daemon start, so the collector keeps
advertising the old name until the startd restarts. Restarting one worker is
cheap; restarting the entry node is not.

Verify from the **entry node**, not locally - both that the new name resolves and
that the old one has stopped:

```
getent hosts <new>.local     # expect the address
getent hosts <old>.local     # expect nothing
```

## The network trap: overlay interfaces

Condor advertises the most *public* address it finds, and its private set is
RFC1918. Two distinct hazards live here, and the second is the common one.

**Outside RFC1918 - takes the primary slot outright.** Tailscale's `100.64/10`
is not in the private set, so on a machine running tailscale the overlay address
is a candidate for the advertised one.
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

**Inside RFC1918 - joins the candidate set quietly.** Seen on two machines at
once: a WireGuard `wg0` on a `10/8` address on both, and on one of them a
Docker bridge on `172.17/16` with a live veth pair. These do not outrank the
pool address the way tailscale does, but they are candidates, and the entry node
can route to none of them. The failure shape is the expensive one - register, match,
run to completion, then fail to return output while `condor_status` shows the
machine healthy.

Pin both, then **verify what is actually advertised** rather than trusting the
pin:

```
condor_status -af Name MyAddress
```

`addrs=` must carry only the pool address. Measured on both machines after
pinning: each carried its own pool address alone, with no overlay prefix
anywhere in the list.

The NetworkManager hook already excludes `docker`, `veth`, `wg`, `tun`, `tap`
and `tailscale` from its comparison, so a pin and the hook agree rather than
fighting.

A machine with no overlay interface needs no pin, even if dual-homed on both
pool segments: either address is reachable.

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

**Add these before the first start, not after the diagnosis.** Three of the last
four machines had `ufw` active. On the first it cost sixteen minutes of a
machine looking perfect while every claim timed out; on the next two the rules
went in during the install and both landed jobs on the first negotiation cycle.

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

## Making a worker submit as well

A worker becomes a submit client by gaining a **user token**. That is the whole
change - there is no schedd, no extra daemon, no submit-specific config,
because submission is `condor_submit -remote <entry> -spool` and the client
talks to the entry node's queue directly. Diffing a worker config against a
user-PC config, the only role-related difference is one `RANK` line.

**A user token is not a daemon token, and it does not live in the same place.**

|  | daemon token | user token |
|---|---|---|
| identity | `condor@<pool>.internal` | `<person>@<pool>.internal` |
| path | `/etc/condor/tokens.d/pool-daemon` | `~/.condor/tokens.d/<name>` |
| read by | the daemons | that one user's client commands |

Never put a user token in `/etc/condor/tokens.d`. Anything there is read by the
daemons, which is the opposite of scoping it to a person.

**When an admin installs it for somebody else, `~` is the wrong home.** On a
shared machine the person who owns it and the person with the ssh session are
often not the same, so use absolute paths and hand over ownership:

```
sudo sh -c "install -d -m 700 -o <user> -g <user> \
      /home/<user>/.condor /home/<user>/.condor/tokens.d
   install -m 600 -o <user> -g <user> /var/tmp/<file>.token \
      /home/<user>/.condor/tokens.d/office-pool" ; sudo -k
sudo shred -u /var/tmp/<file>.token ; sudo -k
```

`install -d` is safe whether or not `.condor` already exists - and it usually
cannot be checked first, because a home directory at mode 700 is unreadable to
anyone else.

**Verify as the target user, not as yourself.** This is the check that proves
the identity landed on the right person:

```
sudo su - <user> -c "condor_ping -name <entry> -type SCHEDD WRITE"
```

Expect `WRITE command using (AES, AES, and IDTOKENS) succeeded as
<person>@<pool>.internal`. Three things must all be right: **WRITE**, which is
what submission needs; **IDTOKENS**, proving the token was used rather than some
fallback; and the identity, which is the accounting identity the pool will bill
the jobs to.

Then run the same command **as yourself** on that machine. It should fail - it
hangs working through the other authentication methods and has to be
interrupted. That negative result is the point: the token is scoped to one
person, not to the machine.

## Verify

```
condor_status -af Name Start HostMemAvailMB HostCpuPsiAvg10 HostDiskAvailMB
```

Attributes present means the `STARTD_CRON` job is feeding the policy. Absent
means the policy is inert while everything still looks healthy.

Then land a job on it. Appearing in `condor_status` is not the same thing - the
firewall case above passes every check on this page except this one.
