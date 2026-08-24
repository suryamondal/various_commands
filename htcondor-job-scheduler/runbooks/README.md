# Runbooks: adding a machine to the pool

One file per machine class, because the differences between classes are the
only part worth writing down. The common steps are identical everywhere and
are listed once here.

| class | file | status |
|---|---|---|
| **Entry node** | [entry-node.md](entry-node.md) | 1, the single point of failure |
| x86 desktop / mini-PC | [worker-x86-desktop.md](worker-x86-desktop.md) | in use, 5 machines |
| Jetson (L4T, aarch64, GPU) | [worker-jetson.md](worker-jetson.md) | in use, 1 machine |
| Raspberry Pi (aarch64, no GPU) | [worker-raspberry-pi.md](worker-raspberry-pi.md) | **not yet attempted** |
| Laptop, submit only | [../handover/submit-node.md](../handover/submit-node.md) | macOS and Ubuntu |

Concrete hostnames, addresses and the pool domain live in `condor-host-list`,
and the ready-made config drop-ins live in `scripts/`. **Both are untracked**,
because they name real machines on private networks. A fresh clone has neither.
These files use placeholders, and the policy every config implements is written
out in full in [../README.md](../README.md) — the drop-ins are a convenience,
not the source of truth.

## Common to every worker

Run these on the new machine, from a checkout of this repository. `<newhost>`
below is the new machine's hostname. Every `sudo` is followed by `sudo -k` so no
command runs on a cached credential.

**1. Install condor and check the version.** Ubuntu 24.04 ships **23.4.0** on
both x86\_64 and arm64, which is what the pool runs.

```
sudo apt-get update ; sudo -k
sudo apt-get install -y condor ; sudo -k
condor_version
```

Expect `$CondorVersion: 23.4.0 ...`. A different version is not automatically
fatal, but the central manager must not be older than the worker — see the
Raspberry Pi runbook, where Debian 13's 23.9.6 is an open question.

**2. Drop in the class config.**

```
sudo install -m 644 -o root -g root scripts/50-worker.config \
     /etc/condor/config.d/50-worker.config ; sudo -k
```

**3. Install the two helper scripts.** Without `condor-owner-session` the owner
policy still parses and is **silently inert** — every threshold compares against
an attribute that is never published.

```
sudo install -m 755 -o root -g root tools/condor-owner-session \
     /usr/local/bin/condor-owner-session ; sudo -k
sudo install -m 755 -o root -g root scripts/condor-network-select \
     /usr/local/bin/condor-network-select ; sudo -k
```

**4. Install a daemon token.** Created on the entry node, moved here, and the
staging copy shredded — see [entry-node.md](entry-node.md).

```
sudo install -m 600 -o root -g root ~/pool-daemon.token \
     /etc/condor/tokens.d/pool-daemon ; sudo -k
shred -u ~/pool-daemon.token
ls -l /etc/condor/tokens.d/pool-daemon
```

Expect `-rw------- 1 root root`. Any group or other bits mean condor will refuse
to read it.

**5. Install the systemd drop-in, the NetworkManager hook and the watchdog.**

```
sudo install -d -m 755 /etc/systemd/system/condor.service.d ; sudo -k
sudo install -m 644 scripts/60-network-select.conf \
     /etc/systemd/system/condor.service.d/60-network-select.conf ; sudo -k
sudo install -m 755 tools/60-condor-network-change \
     /etc/NetworkManager/dispatcher.d/60-condor-network-change ; sudo -k
sudo install -m 644 tools/condor-registration-watchdog.service \
     tools/condor-registration-watchdog.timer /etc/systemd/system/ ; sudo -k
sudo install -m 755 tools/condor-registration-watchdog \
     /usr/local/bin/condor-registration-watchdog ; sudo -k
sudo systemctl daemon-reload ; sudo -k
sudo systemctl enable --now condor-registration-watchdog.timer ; sudo -k
```

**6. Start condor and verify a job lands.**

```
sudo systemctl enable --now condor ; sudo -k
sudo systemctl restart condor ; sudo -k
```

Then, **from the entry node**:

```
condor_status -af Name Start HostMemAvailMB HostCpuPsiAvg10 HostDiskAvailMB | grep <newhost>
```

All four attributes must be present. `undefined` means step 3 did not take and
the policy is inert. Appearing in `condor_status` and **running a job** are
independent properties — land one before calling the machine done. Every
failure listed below except the token one passes the first half of this step.

## The five things that go wrong every time

**A user token is not a daemon token.** `condor_token_create -identity
condor@<pool>.internal`. With a user token the startd starts cleanly, never
registers, and reports nothing.

**Sizing is per machine, not per class.** `RESERVED_DISK` in particular: the
standard figure exceeded one machine's entire free space, which would have left
it advertising cores while refusing every job.

**Group changes need a restart.** `usermod -aG` does not reach a running
process. That applies to `sudo` for your own account, and to `video`/`render`
for the `condor` daemon. It does **not** apply to job processes, which the
starter forks fresh.

**A host firewall drops the claim, not the registration.** `ufw` was active on
one desktop and on no other. The machine registers, publishes every attribute,
reads `Unclaimed` / `Start = true`, and the negotiator matches jobs to it — then
the schedd cannot connect back, and `SchedLog` fills with `REQUEST_CLAIM …
SECMAN:2003`. Testing reachability from the new machine proves nothing: the
broken direction is entry-to-worker. See [worker-x86-desktop.md](worker-x86-desktop.md).

**Staged credentials must be shredded.** A daemon token is a bearer credential
with no machine binding. Do the cleanup as its own step: once, a `shred` at the
tail of a longer payload silently did not run.
