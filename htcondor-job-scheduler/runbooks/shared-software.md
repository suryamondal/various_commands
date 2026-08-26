# Installing shared software on every machine

Worked example: openEMS. The reasoning generalises to anything a job needs to
find on the machine it lands on.

## Where it goes, and why not a home directory

```
/opt/products/<name>-Project/    source
/opt/products/<name>/            install prefix
```

Mirrors the layout an operator already keeps under `~/products`, but under
`/opt`, mode 755. Two independent reasons, either sufficient on its own:

**Jobs run as `nobody`.** A home directory is mode 750, so `nobody` cannot even
traverse it. An install under `~` is invisible to every job on every machine -
it looks installed, and no job can use it.

**The install path is baked into the binary.** Measured on the reference build:

```
RUNPATH: /home/<user>/products/openEMS/lib:/usr/lib/x86_64-linux-gnu/hdf5/serial
```

So a build cannot be made in one place and copied to another - it would fail to
load its own libraries. **The prefix is a build-time decision and is permanent
for that build**, which is why each machine builds rather than receiving a copy.

## Pin the version

Every machine must run the same build. A solver that differs between machines
makes results depend on where a job happened to land, and nothing in the output
says so. Take the exact commit from the reference install:

```
git -C ~/products/<name>-Project log -1 --format=%H
git -C ~/products/<name>-Project describe --tags
```

and check that out on every machine, with `git submodule update --init
--recursive` so the submodules match too.

## Build what a headless worker needs, and nothing more

For openEMS that is `--disable-GUI --python`: the solver, `nf2ff`, `sar_calc`
and the Python bindings, with no Qt and no AppCSXCAD. There is no reason to put
a GUI toolkit on eight headless machines.

## Nice it, and cap the parallelism per machine

```
nice -n 19 ./update_openEMS.sh --disable-GUI --python --njobs=N /opt/products/openEMS
```

`nice 19` so Condor jobs, which run at nice 10, keep CPU priority over the
build. Choose N per machine rather than using `nproc` everywhere:

| machine | N | why |
|---|---|---|
| entry node | 2 | it runs the collector, negotiator and schedd; it is the pool's single point of failure |
| 4-core desktops | 4 | fine, the build is nice'd |
| the 16-thread machine | 8 | not 16 - a VTK-heavy C++ build uses 1-2 GB per compiler, and nice does nothing for memory |

## Fix ownership at the end, or nothing can use it

```
chown -R root:root /opt/products
chmod -R a+rX /opt/products
```

Uniform ownership on every machine, and `a+rX` so `nobody` can traverse and
execute. Skip this and the install exists but every job fails.

## Verify three things, then verify with a real job

On each machine:

```
/opt/products/<name>/bin/<binary>          # runs, and prints its version
readelf -d .../bin/<binary> | grep RUNPATH # points at /opt, not a home
.../venv/bin/python -c "import <module>"   # bindings load
```

**Then land a Condor job that runs it as `nobody`.** Everything above can pass
while the software is still unusable to the pool - that is precisely the failure
`/opt` exists to prevent, and it is not exercised until a real job does it.

A cheap job that reports `id -un`, runs the binary, and counts
`ldd ... | grep -c "not found"` is enough.

## Two traps met while doing this

**Do not probe with a flag you have not checked.** `openEMS --version` prints
the banner and then aborts with `unrecognised option`, exit 134, because there
is no such flag. Every job reported `Aborted (core dumped)` on stderr while the
output looked perfect. The install was fine; the probe was wrong.

**Naming a version is not the same as having it.** Confirm the built binary
reports the version you pinned, on every machine, rather than assuming the
checkout took.
