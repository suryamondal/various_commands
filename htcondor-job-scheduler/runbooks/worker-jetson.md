# Worker: Jetson (L4T, aarch64, GPU)

One in the pool: an Orin Nano, 6 cores, 7.5 G, dual-homed on both pool segments.

Config: `scripts/50-worker-jetson.config`.

## The policy needed no porting

Same owner policy, same `STARTD_CRON` job, same measured-memory override as the
x86 machines, unmodified. Jobs run as `nobody` at nice 10 exactly as elsewhere,
and Ubuntu ships the pool's exact Condor version for arm64. Nothing about the
architecture required a decision.

Everything below is either **size** or **device permissions**.

## Sizing: check free disk before anything else

```
RESERVED_DISK = 4096      not 20480
RESERVED_MEMORY = 750     10% of 7.5 G
```

The standard 20480 is **larger than this machine's entire free space** (12 G of
57.6 G). Applying it leaves nothing donatable, and the machine sits advertising
six cores while refusing every job. The fractional floors still stop admission
at 5758 MB free and evict at 2879 MB.

Do this arithmetic for any small-disk machine before deploying, not after.

## Network

**No `NETWORK_INTERFACE` pin.** Dual-homed on both pool segments with no VPN
interface, so either address Condor picks is reachable.

`l4tbr0` and `docker0` are excluded from the NetworkManager hook's comparison.
Both are DOWN, but `docker0` at `172.17/16` is RFC1918 and would become a
candidate for the advertised address if anything brought it up.

## GPU: the whole difficulty is group membership

Discovery works. `condor_gpu_discovery` reports the Orin cleanly. What fails is
*access*, because Tegra gates the GPU behind groups while HTCondor deliberately
runs unprivileged and in no supplementary groups at all.

**Two accounts need it, for two different reasons.**

```
sudo usermod -aG video,render condor ; sudo -k   # so the startd can ENUMERATE it
sudo systemctl restart condor ; sudo -k          # a group is read at process start

sudo usermod -aG video,render nobody ; sudo -k   # so a JOB can OPEN it
                                                 # no restart: starter forks per job
```

The failure messages are distinct and only the first mentions permissions:

```
no groups        NvRmMemInitNvmap failed: Permission denied
video only       Error: cuInit returned 801   (CUDA_ERROR_NOT_SUPPORTED)
video + render   DetectedGPUs="GPU-..."
```

`render` is for `/dev/dri/renderD12*`, the DRM render node CUDA uses for compute.

**Do not add `debug` or `root`.** They own some `nvhost-*` nodes, but an account
that has neither still initialises CUDA, so granting them would hand GPU
profiling access to a daemon whose job is counting devices.

### What that costs

**`request_gpus` is advisory here.** Access belongs to `nobody`, the account
every job shares, so any job landing on this machine can open the GPU whether it
reserved one or not. Consistent with how the pool already treats
`request_memory`. If it ever matters, the fix is per-slot job accounts
(`SLOT<N>_USER`) with only that account in the groups.

### Tegra memory has no separate budget

`GlobalMemoryMb` reports the same figure as system RAM, because an integrated
GPU shares the SoC's memory. So `request_memory` and `request_gpus` draw on one
budget, not two. The measured guards still work, since they read `MemAvailable`
and do not care which processor dirtied the pages, but matchmaking will place a
GPU job alongside CPU jobs whose requests already account for most of the
machine.

`nvidia-smi` reports `memory.total` as `N/A` on this platform. Use
`DetectedGPUs` and the `Common` ad.

## Targeting it from a submit file

```
requirements = (Arch == "AARCH64") && (HostBoardClass =?= "jetson")
request_gpus = 1
```

**`Arch` must be in the expression.** `condor_submit` appends
`Arch == "X86_64"` unless `requirements` already mentions `Arch`, so naming only
`HostBoardClass` builds a contradiction: a jetson that is also x86\_64. The job
sits Idle reporting *"N are rejected by your job's requirements"*, which reads
like the pool refusing work rather than a submit-file mistake.

`HostBoardClass` comes from `/proc/device-tree/model` and is the only thing that
separates a Jetson from a Raspberry Pi: both are aarch64, both may run Ubuntu.

## Deployment notes specific to this machine

- The account may exist for hardware access (`gpio`, `i2c`, `render`) with **no
  home directory and no sudo**. Both need creating before anything else.
- After `usermod -aG sudo`, **kill the tmux server**. It hands its old group set
  to every new window indefinitely, so sudo keeps failing in a way that looks
  like the change did not apply.
