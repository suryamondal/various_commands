# Worker: Apple Mac mini (macOS)

The pool's first non-Linux execute node. Everything here that differs from
[worker-x86-desktop.md](worker-x86-desktop.md) differs because it *had* to —
this is not a style preference, and each difference is justified where it
appears.

Read that runbook first. This one only covers the deltas.

## Why bother

Measured on the machine, not estimated. openEMS FDTD is memory-bandwidth-bound,
which this pool established earlier when a 16-thread Ryzen beat a 4-core N100
by only 1.5x. Unified memory changes that ratio:

| | concurrent | per job | aggregate |
|---|---|---|---|
| Mac mini M4, raw shell | 8 | 144.0 | **1150.3 MCells/s** |
| Mac mini M4, through Condor | 8 | 136.4 | **1092.1 MCells/s** |
| `skull-ryzen7`, 16 thread | 16 | 19.8 | 317 |
| `skull-n100`, 4 core | 4 | 52.0 | 208 |

3.4x the pool's largest machine and 5.2x an N100, for this workload. Condor's
own overhead is 5%. All eight jobs finished within 0.8% of each other, so the
memory system is still not saturated at 8-way — which is exactly where the
Ryzen falls over, and why its 16 threads buy so little.

**This does not generalise.** FDTD streams memory. yosys and nextpnr are
latency- and branch-bound; measure them before promising anything.

## What is actually different

| | Linux worker | Mac mini |
|---|---|---|
| install | `apt` package | tarball, unpacked by hand |
| version | 23.4.0 | **23.0.4** — see below |
| architecture | native | x86_64 daemons under Rosetta |
| service account | `condor`, made by the package | `_condor`, made by hand |
| `CONDOR_IDS` | not defined | **required** |
| service manager | systemd | launchd |
| presence, memory, disk | `/proc`, `loginctl`, `ss` | `vm_stat`, `ioreg`, `netstat` |
| built-in benchmarks | fine | **must be disabled** |
| job targeting | default | `requirements = (OpSys == "macOS")` |

## 1. Version: use 23.0.x, not 24.x

HTCondor publishes exactly one macOS tarball per release and only for some
releases. At time of writing `23.0.4` and `24.0.15` exist; `23.0.29` does not.

Take **23.0.4**. The rule is that the central manager must not be older than
its workers, and this pool's CM runs 23.4.0 — so a 24.x worker is the wrong
direction. Check what exists before assuming:

```
curl -sL https://research.cs.wisc.edu/htcondor/tarball/23.0/23.0.4/release/
```

The workers cannot reach the internet. Download on the entry node or an
operator machine and copy it over.

## 2. Rosetta must already be present

The daemons are x86_64. Confirm before starting:

```
/usr/bin/pgrep -q oahd && echo yes || echo no
/usr/bin/arch -x86_64 /usr/bin/true && echo ok
```

If absent: `softwareupdate --install-rosetta`.

**Rosetta does not slow the jobs down.** An x86_64 process execs an arm64
binary natively, so anything under `/opt/products` runs at full speed. Only
the control-plane daemons are translated, and they are idle. Verify on any new
machine, because the whole case for adding it rests on this:

```
/usr/bin/arch -x86_64 /bin/sh -c 'file /opt/products/openEMS/bin/openEMS'
  -> Mach-O 64-bit executable arm64
```

## 3. Layout

There is no `/etc/condor` or `/var/lib/condor` to inherit. Everything is stated
explicitly, under one root:

```
sudo -k ; sudo mkdir -p /opt/condor/etc/config.d /opt/condor/etc/tokens.d \
  /opt/condor/etc/passwords.d /opt/condor/local/log /opt/condor/local/spool \
  /opt/condor/local/execute /opt/condor/local/lock /opt/condor/local/run ; sudo -k

sudo -k ; sudo tar xzf /var/tmp/condor-23.0.4-x86_64_macOS13-stripped.tar.gz -C /opt/condor ; sudo -k
sudo -k ; sudo mv /opt/condor/condor-23.0.4-x86_64_macOS13-stripped /opt/condor/release ; sudo -k
```

## 4. The service account, and why `CONDOR_IDS` is needed here alone

On Linux the systemd unit has an empty `User=`, so `condor_master` starts as
**root** and drops privilege to the `condor` account *by name*. That name
lookup is why no Linux host in this pool defines `CONDOR_IDS`.

macOS has no account called `condor`. A root-started master looks it up, fails,
and refuses to start. So the account is created by hand and named explicitly.
uid/gid 442: free, below 500 so the login window hides it.

```
sudo -k ; sudo dscl . -create /Groups/_condor ; sudo -k
sudo -k ; sudo dscl . -create /Groups/_condor PrimaryGroupID 442 ; sudo -k
sudo -k ; sudo dscl . -create /Users/_condor ; sudo -k
sudo -k ; sudo dscl . -create /Users/_condor UniqueID 442 ; sudo -k
sudo -k ; sudo dscl . -create /Users/_condor PrimaryGroupID 442 ; sudo -k
sudo -k ; sudo dscl . -create /Users/_condor UserShell /usr/bin/false ; sudo -k
sudo -k ; sudo dscl . -create /Users/_condor NFSHomeDirectory /var/empty ; sudo -k
sudo -k ; sudo dscl . -create /Users/_condor Password "*" ; sudo -k
sudo -k ; sudo dscl . -create /Users/_condor IsHidden 1 ; sudo -k
```

Ownership mirrors a Linux worker exactly — daemons write to `local/` after
dropping privilege; `tokens.d` is read by the master while it is still root:

```
sudo -k ; sudo chown -R 442:442 /opt/condor/local ; sudo -k
sudo -k ; sudo chown -R root:wheel /opt/condor/release /opt/condor/etc ; sudo -k
sudo -k ; sudo chmod 700 /opt/condor/etc/tokens.d /opt/condor/etc/passwords.d ; sudo -k
```

## 5. Config

Two files, from the repo: a minimal top-level `condor_config` and the usual
per-host worker config in `config.d`. The top-level one carries a line that is
easy to omit and fails silently:

```
use security:recommended_v9_0
```

The Debian package ships this in `00-htcondor-9.0.config`; the tarball ships
nothing. Without it the built-in default is **host-based** security, the
daemons start cleanly, and the machine simply never authenticates to the pool.

`CONDOR_IDS = 442.442` and the `/opt/condor` paths go in the same file.

## 6. The presence/memory/disk script

`/usr/local/bin/condor-owner-session` — **same path as every Linux host, so the
config stanza is identical fleet-wide**, but the file behind it is
`tools/condor-owner-session-macos`. Every input the Linux version reads is
absent here:

| Linux | macOS |
|---|---|
| `/proc/meminfo` | `memory_pressure`, `sysctl` |
| `/proc/pressure/*` | `kern.memorystatus_vm_pressure_level`; no CPU equivalent |
| `loginctl` | console user + `ioreg` HIDIdleTime |
| `ss` | `netstat` |

It publishes the same attribute names in the same units, so no policy changes.

## 7. Token

Minted on the entry node, where the pool signing key lives:

```
sudo -k ; sudo condor_token_create -identity condor@<pool>.internal > /var/tmp/mac.token 2>/var/tmp/mac.err ; sudo -k
chmod 600 /var/tmp/mac.token
```

Copy it via the operator machine — do not open a new host-to-host ssh — then:

```
sudo -k ; sudo install -o root -g wheel -m 600 /var/tmp/mac.token /opt/condor/etc/tokens.d/mac.token ; sudo -k
sudo -k ; sudo rm -f /var/tmp/mac.token ; sudo -k
```

Shred every staging copy afterwards, on the entry node and the operator
machine both. `shred -u <file>`.

## 8. launchd

`/Library/LaunchDaemons/edu.wisc.cs.htcondor.plist`, running
`condor_master -f`. **The `-f` is not optional**: launchd supervises the
process it spawned, so a master that daemonises is seen to exit immediately and
gets restarted forever. systemd's `Type=simple` has the same requirement.

`UserName` is `root` — an execute node must switch users to run a job as
`nobody`. `CONDOR_CONFIG` must be set in `EnvironmentVariables`, because the
tarball has no compiled-in config path.

```
sudo -k ; sudo launchctl enable system/edu.wisc.cs.htcondor ; sudo -k
sudo -k ; sudo launchctl bootstrap system /Library/LaunchDaemons/edu.wisc.cs.htcondor.plist ; sudo -k
```

`load -w` is the deprecated equivalent if `bootstrap` is unavailable.

## 9. Verify

```
condor_status -constraint 'regexp("<host>", Name)' -af:lrn \
  Name OpSys Arch HostBoardClass Cpus Memory State \
  HostMemAvailMB OwnerSessionActive HostDiskAvailMB
```

**`Memory` and `HostMemAvailMB` must be non-zero, and must CHANGE between two
queries a minute apart.** A frozen value means the cron is dead — see the traps
below. This is the check that matters; everything else can look perfect while
the machine is incapable of running a job.

Then run something real:

```
requirements = (OpSys == "macOS")
```

## Traps

**1. `vm_stat` is the wrong way to measure free memory, and being wrong here
takes the machine out of the pool silently.** The obvious port of Linux
`MemAvailable` is `free + inactive + speculative + purgeable`. On this machine
that read 4845 MB where the kernel said 9666 MB — it misses clean file-backed
pages that are *active* and ignores the compressor, which was holding 14.0 GB
of data in 4.5 GB of pages. macOS keeps very little memory free *by design*.

The consequence was `Memory = 0`, `START` false against the 25% floor, and a
machine sitting Unclaimed and healthy-looking that could never match. It also
collapsed to 1268 MB under load, so even above the floor it would have flapped.

Use `memory_pressure`'s own free percentage. It is what macOS consults to
decide memory is short, so admission and eviction then read the same source.

**2. Disable the built-in benchmarks.** `condor_mips` under Rosetta ran for 5.5
minutes without exiting, pinning a core, where the same binary finishes in
under a second on Linux — it is a timing loop, which is exactly what binary
translation ruins. It also blocked the startd cron, freezing every published
attribute at its first sample.

```
BENCHMARKS_JOBLIST =
RunBenchmarks      = False
```

The numbers would be lies anyway: `KFlops`/`Mips` would measure translated x86
throughput, not the machine. Nothing in this pool's policy reads either.

**3. `OpSys` is `macOS`, not `OSX`.** And naming it is mandatory:
`condor_submit` injects `(Arch == "X86_64") && (OpSys == "LINUX")` into any job
that does not mention those attributes, so a job targeting `HostBoardClass`
alone silently carries a `LINUX` clause and never matches. Check with
`condor_submit -dry-run` before queueing.

**4. `Arch` reads `X86_64` on an arm64 machine.** Only one macOS build exists
and it is x86_64, so the daemons report the binary's architecture. Harmless —
jobs exec native arm64 — but it means `Arch == "X86_64"` is the correct thing
to match on, and `HostBoardClass` is what to use when you mean the hardware.

**5. Leave the hostname alone unless you have a reason.** mDNS advertises
`LocalHostName`, which is what the collector resolves; `scutil --get
LocalHostName` is the value that matters. Changing `ComputerName` is visible to
the machine's user in Finder and AirDrop for no functional gain.

**6. sudo is cached in a shared pane.** A sent `sudo` command runs immediately
if the timestamp is still live, with no prompt to validate at. Prefix with
`sudo -k` as well as suffixing it.
