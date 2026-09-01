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

## Installing it is not enough: check what PATH actually resolves to

The installs can be perfect and identical and the pool still be inconsistent,
because a job that invokes a tool **by name** gets whatever PATH finds first.

Surveyed across seven machines after a correct, identical install of the ECP5
toolchain into `/opt/products`, a bare `yosys` gave **four different answers**:

```
three machines   /usr/bin/yosys         0.33          (from apt)
one machine      /usr/local/bin/yosys   0.56+165      (hand-built by someone)
two machines     none                   -             (would simply fail)
one machine      ~/.local/bin/yosys     0.66          (the pinned build)
```

So the same submit file synthesised differently depending where the negotiator
placed it, and failed outright on two machines. Nothing reports this. The
output is simply not what you think it is.

**This is not hypothetical.** The identical confusion on a single workstation -
PATH quietly resolving to an older toolchain while the newer one sat installed -
cost two weeks of debugging elsewhere before it was noticed, and it was noticed
only because deploying to the pool forced a comparison of what was on PATH
against what was in the install tree.

**The fix, on every machine:**

```
sudo ln -sfn /opt/products/yosys/v0.66/install/bin/yosys /usr/local/bin/yosys
```

`/usr/local/bin` precedes `/usr/bin`, so this wins over a distro package without
removing it - the packaged version stays installed and reachable by absolute
path for anything that depends on it.

**Preserve anything real that is already there.** If `/usr/local/bin/<tool>` is
a regular file rather than a symlink, someone installed it deliberately. Move it
to `<tool>.preexisting` and say so, rather than overwriting it - destroying
somebody's build silently is the same class of surprise this change exists to
remove.

**Then survey again rather than assuming.** `command -v <tool>` plus the version
string, on every machine, is the check. Doing it for one tool is not enough:
here `yosys` was present-but-wrong on four machines while `nextpnr-ecp5` and
`ecppack` were missing entirely on three, so one machine had a synthesiser and
no place-and-route.

## Pruning the superseded copies

Once PATH is uniform, remove the old copies - not for disk, but so the question
"which version ran?" has exactly one answer. The saving here was ~450 MB across
seven machines, invisible against 29 GB free; the ambiguity was the cost.

**Audit before removing, and read the simulation.**

```
dpkg-query -W -f='${Package} ${Version} ${Installed-Size}kB\n' <names>
apt-get -s remove <names>          # simulation, needs no root
apt-cache rdepends --installed <names>
ls -l /usr/local/bin/<tool>*       # hand-built copies live here, not in dpkg
```

**Name every package, not the obvious ones.** Removing `yosys nextpnr-ecp5
fpga-trellis` looks complete and leaves `nextpnr-ecp5-chipdb` behind - 102 MB,
three quarters of the total, because a chip database is a separate package that
nothing then depends on. The simulation shows this: it reported three removals
against six installed packages.

**Prove leftovers are inert before deleting them.** One machine had a hand-built
yosys 0.56 whose companions - `yosys-abc`, `yosys-config` and friends - were
still first on PATH while `yosys` itself had been repointed at 0.66. Whether
that mattered depended on how yosys locates its helpers, which is a question to
answer by measurement, not by reading:

```
run the same synthesis on a machine that HAS the leftovers and one that does not
```

Identical output (`717285` bytes both) showed yosys resolves its companions
relative to its own real path, not via PATH, so the leftovers were never
invoked. That is what made deleting them safe rather than hopeful.

**Do not prune a tool for a different target.** The same machine carried
`nextpnr-ice40`, 300 MB - larger than everything else combined, and the obvious
thing to sweep up. It targets a different FPGA family, and the `/opt` install
ships `nextpnr-ecp5` only, so removing it would have deleted capability nothing
replaces. Check what a binary is *for* before treating it as a duplicate.

**Remove regular files only, never the symlinks.** The prune and the PATH fix
write to the same directory; a script that deletes by name will happily remove
the symlink it is supposed to preserve.

**Then run the real pipeline again.** Output byte counts should be unchanged
from before the prune. If they moved, something the toolchain depended on went
with the packages.

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

## Upstream code that only breaks on one platform

Two tools in this pool needed a source change to build or run on macOS, and
**neither failure is visible from Linux**. Both are the same shape: an upstream
assumption that held for years until a toolchain default changed.

**iverilog 13.0 does not compile on macOS as shipped.** `driver/main.c` picks a
platform-specific way to find its own executable:

```
#if   defined(__MINGW32__)  -> GetModuleFileName      (includes <windows.h>)
#elif defined(__APPLE__)    -> _NSGetExecutablePath   <- no include for it
#else                       -> readlink /proc/self/exe
```

The Apple branch never includes `<mach-o/dyld.h>`, where that function is
declared. That was historically an implicit-declaration *warning*; the build
now runs `gcc -std=gnu23`, and **C23 makes implicit declarations a hard
error**. So code that compiled for years fails with:

```
main.c:1066: error: use of undeclared identifier '_NSGetExecutablePath'
```

Add the guarded include before compiling. The patch lives only in the build
tree, so a fresh clone needs it again.

**yosys on macOS crashes under Condor after producing correct output** - the
libedit/`HOME` bug, written up in [worker-mac-mini.md](worker-mac-mini.md)
trap 6.

The lesson for both: **when a tool is built on more than one OS, the second OS
is where upstream's untested paths live.** Budget for a patch, and verify by
running the tool, not by seeing the build succeed.

## Also check the system copy is not what jobs actually get

`iverilog` is the sharpest example in this pool. Ubuntu ships `iverilog` at
`/usr/bin/iverilog` and it is **12.0** (2022); the pool builds **13.0** into
`/opt/products`. Both are present on most machines. A job calling a bare
`iverilog` gets the apt one - so the same job can behave differently depending
on which path it used, on the same machine.

This is the same failure as the yosys/PATH problem in the section above, with
an extra wrinkle: here the wrong version is not a stale symlink but a
legitimately installed distro package that cannot simply be removed, because
other things may depend on it. **Absolute paths are the only reliable answer.**

## Two traps met while doing this

**Do not probe with a flag you have not checked.** Twice now. `openEMS --version` prints
the banner and then aborts with `unrecognised option`, exit 134, because there
is no such flag. Every job reported `Aborted (core dumped)` on stderr while the
output looked perfect. The install was fine; the probe was wrong.

**Naming a version is not the same as having it.** Confirm the built binary
reports the version you pinned, on every machine, rather than assuming the
checkout took.
