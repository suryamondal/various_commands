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

## Build on every machine, or build once and copy? Check RUNPATH

This is the decision that shapes all the work, and it is answerable in one
command rather than by preference. Two installs done back to back landed on
opposite answers:

```
readelf -d <binary> | grep -E "RUNPATH|RPATH"
grep -rl "/home/" <install-tree>
```

| | openEMS | the ECP5 FPGA toolchain |
|---|---|---|
| `RUNPATH` | `/home/<user>/products/openEMS/lib` - **absolute, into a home** | `$ORIGIN/../lib/trellis` on `ecppack`, none on the others |
| refs to `/home` | in the binary itself | one shell script only |
| external data | none | none - `nextpnr-ecp5` is 186 MB because the chip database is **embedded** |
| therefore | **must be built per machine** | **build once, copy** |
| cost | ~20 min x 7 machines | 82 MB tarball, ~1 min x 7 |

`$ORIGIN` is the point. A relative RUNPATH means the binary finds its libraries
wherever the tree is placed; an absolute one into a home directory means the
binary is welded to a path that does not exist on any other machine, and copying
it produces `cannot open shared object file` at run time rather than an error at
install time.

**So check before choosing.** Assuming "build everywhere" wastes hours;
assuming "copy" ships something that fails only when a job runs.

**When copying, still grep the tree for hardcoded paths.** In the FPGA trees
exactly one file had them - `yosys-config`, which reports `--cxxflags`,
`--bindir` and `--datdir` for building yosys plugins. Left alone it would point
every plugin build at a path that does not exist on the target. A `sed` at
install time fixes it; not noticing it leaves a trap for whoever first compiles
a plugin.

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

**Make that job do real work, not a version check.** The FPGA install was
verified by running an actual flow - Verilog through `yosys synth_ecp5`, then
`nextpnr-ecp5` place-and-route, then `ecppack` - on four machines at once. The
outputs came back **byte-identical**:

```
synth 717497 B    pnr 17821 B    bitstream 582369 B
```

Identical byte counts are far stronger evidence of a consistent toolchain than
matching version strings: two builds can report the same version and still
differ. Sizes to the byte cannot.

A cheap job that reports `id -un`, runs the binary, and counts
`ldd ... | grep -c "not found"` is enough.

## Two traps met while doing this

**Do not probe with a flag you have not checked.** Twice now. `openEMS --version` prints
the banner and then aborts with `unrecognised option`, exit 134, because there
is no such flag. Every job reported `Aborted (core dumped)` on stderr while the
output looked perfect. The install was fine; the probe was wrong.

**Naming a version is not the same as having it.** Confirm the built binary
reports the version you pinned, on every machine, rather than assuming the
checkout took.
