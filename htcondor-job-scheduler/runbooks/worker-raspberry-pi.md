# Worker: Raspberry Pi (aarch64, no GPU)

**Not yet attempted.** Everything here is reasoned from the Jetson deployment
and from what the Pi class is known to be, not from a machine that has joined.
Treat the sizing as a starting point and the warnings as untested.

Expected: 4 cores, 4 G RAM, ~36 G on SD, Debian 13.

## What should carry over unchanged

The Jetson proved the policy needs no porting for aarch64: same owner policy,
same `STARTD_CRON` job, same measured-memory override, jobs as `nobody` at
nice 10. Expect the same here.

## What to check first, in this order

**Condor version.** The Jetson runs Ubuntu 24.04, which ships 23.4.0, matching
the pool. **Debian 13 ships 23.9.6.** That is a different version, and while
HTCondor tolerates some skew, the pool's own rule is that the central manager
should not be older than its workers. Confirm what `apt-cache policy condor`
offers before assuming this class is a drop-in.

**Disk.** ~36 G on an SD card is the tightest in the fleet and the standard
`RESERVED_DISK = 20480` is over half of it. The Jetson needed 4096 for the same
reason; this will need less again. Compute it from actual free space:

```
RESERVED_DISK   ~10% of free, leaving the fractional floors room to work
```

SD cards are also slow. `EXECUTE` on one will make file transfer and job
sandboxes noticeably worse than any other machine in the pool, which is a
throughput consideration rather than a correctness one.

**Memory floors bite differently at 4 G.** `MEM_HARD_FLOOR` is
`max(1024, 10% of total)`, so on a 4 G machine the **absolute** 1024 MB dominates
rather than the fraction. That is deliberate: 10% of 4 G is 410 MB, too little to
avoid thrashing. Expect this machine to decline work sooner than the others.

```
RESERVED_MEMORY = 400        10% of 4 G
```

## Board identity

Publish it, so a job can distinguish this from a Jetson. `Arch` alone cannot:
both are aarch64 and both may run Ubuntu or Debian.

```
HostBoard      = "<from /proc/device-tree/model>"
HostBoardClass = "rpi-<model>"
STARTD_ATTRS   = $(STARTD_ATTRS) HostBoard HostBoardClass
```

`HostBoardClass` names a **board, not a family** - `skull-n100`,
`skull-ryzen7`, `jetson-orin-nano`. So this is `rpi-5` or `rpi-4b`, not `rpi`:
a value that cannot tell a Pi 4 from a Pi 5 has the same defect as calling
every x86 machine `skull-saints`, which is what this convention replaced.

`/proc/device-tree/model` reads `Raspberry Pi ...` here and `NVIDIA Jetson ...`
on the Jetson, which is the authoritative discriminator.

## No GPU

Skip the entire GPU section of the Jetson runbook. Do **not** add `condor` or
`nobody` to `video`/`render`; there is nothing to reach and it grants access for
no reason.

## Targeting it

```
requirements = (Arch == "AARCH64") && (HostBoardClass =?= "rpi-<model>")
```

`Arch` must appear, or `condor_submit` appends `Arch == "X86_64"` and the job
never matches. Same trap as the Jetson.

## Open questions this class will answer

- Whether the Debian-shipped Condor version interoperates cleanly with a 23.4.0
  central manager.
- Whether an SD-backed `EXECUTE` makes disk-pressure eviction fire in normal use.
  It is the one policy branch never observed firing, and this is the machine most
  likely to trigger it honestly.
