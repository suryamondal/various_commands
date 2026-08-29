# Handover: submit node on a laptop (macOS or Ubuntu)

Setting up a machine to submit jobs into the pool, where **the machine is not
yours**. That constraint decides most of what follows: no root, no daemons, no
launchd service, nothing outside the user's home directory, and a one-line
uninstall.

Hand this file to whoever owns the laptop. **Part B is macOS, Part C is
Ubuntu** — do one or the other, not both.

> **Placeholders.** `<ENTRY_NODE>`, `<POOL_DOMAIN>` and `<USER>` are filled in
> from `condor-host-list`. The filled copy contains real hostnames — keep it out
> of version control, same rule as the rest of this repo.

---

## 1. What this machine will and will not do

| | |
|---|---|
| **Will** | Submit jobs, check the queue, retrieve output |
| **Will** | Work from the office LAN, and from anywhere via Tailscale or an ssh tunnel |
| **Will not** | Run any HTCondor daemon — not even in the background |
| **Will not** | Execute other people's jobs |
| **Will not** | Need root, a service, a firewall change, or a login shell on the entry node |

Footprint is two directories in the user's home and one line in `~/.zshrc`.

### Why a laptop is submit-only

This is the **normal** configuration for a laptop, not an opt-out. The pool
expects donation from desktops, which sit still and stay plugged in; laptops
submit. Three reasons:

- **It sleeps.** A laptop that closes mid-job takes that job's work with it.
- **It leaves.** mDNS is link-local, and a worker must be *reachable inbound* by
  the entry node to be claimed. Off the LAN it would register, match, and then
  fail the claim.
- **It is not ours to spend.** Someone else's battery and fans is a conversation
  to have explicitly, not a default.

A submit client has none of those problems, because **every connection it makes
is outbound**. Nothing dials it back. That is why it works through a tunnel,
behind the macOS firewall, and from outside the office.

If the owner *does* want it to execute jobs while docked, that is a separate
change: `DAEMON_LIST = MASTER, STARTD`, the owner policy, and a *daemon* token —
worth it for a laptop that lives on a desk, not for one that travels.

---

## 2. Values you need

Fill these in before handing the file over.

| Placeholder | Value | Where it comes from |
|---|---|---|
| `<ENTRY_NODE>` | | The entry node's real hostname, e.g. `host.local` |
| `<POOL_DOMAIN>` | | `UID_DOMAIN` — identical pool-wide |
| `<USER>` | | The identity in the token, `<user>@<POOL_DOMAIN>` |
| Token file | | Delivered separately — see Part A |

---

## Part A — Operator: before you hand it over

### A1. Settle the account question first

**This is the one thing that can block the whole setup**, and it is now
confirmed rather than suspected.

The pool's second submitter hit it on 2026-08-25. Everything upstream passed -
`condor_ping` reported WRITE succeeding via IDTOKENS under the right identity,
and `condor_q` against the entry node worked and even reported a total for that
person - and then submission failed:

```
ERROR: Setting owner to "<USER>", which is not a valid user account
submit failed
```

`UID_DOMAIN` matches the token's domain, so `<USER>@<POOL>` maps to condor
owner `<USER>`, and the schedd requires that to be a resolvable Unix account
because it runs **one condor_shadow per running job as that user**. No account,
no UID to drop privileges to, and the job is refused before it is created.

It stayed hidden this long because every earlier submitter was the pool admin,
who already had a login on the entry node for ssh - an accident, not a design.

Note the asymmetry: **workers need no per-person account**, because jobs there
run as `nobody`. Only the entry node does.

Check before promising anything:

```
ssh <ENTRY_NODE> "id <USER> 2>&1"
```

- **Account exists** → proceed.
- **No account** → create a system account, no home directory, no shell. It is
  an accounting identity, not a login:

  ```
  sudo useradd --system --no-create-home --shell /usr/sbin/nologin <USER>
  ```

  A distinct UID per person, never a shared one — fair-share and spool
  isolation both depend on it. The shadow runs as that user and the spool
  directory holding each job's input and output is owned by that UID, so one
  shared account would let any submitter read or overwrite another's data.

  The first real instance was created with `adduser --disabled-password
  --shell /usr/sbin/nologin` instead, which gives a regular UID and a home
  directory. Both work — the shadow needs neither a home nor a system UID — but
  the `useradd` form above is the tidier one and is what to use next time.

### A2. Issue a *user* token

Run these on the entry node, exactly as written. The second line creates the
token file so that only you can read it.

```
umask 077
sudo condor_token_create -identity <USER>@<POOL_DOMAIN> > ~/handover.token
ls -l ~/handover.token
```

The `ls` should show `-rw-------`, meaning nobody else on that machine can read
it. If it shows anything else, delete the file and run the three lines again.

> **User token, not a daemon token.** A daemon token (`condor@…`) would let that
> laptop act as pool infrastructure. It only needs to submit.

### A3. Deliver it, then destroy every copy you made

The token is a **bearer credential with no machine binding**: anything that can
read the file can act as that identity. It is not tied to the laptop, so a copy
left in `~/` or in a chat log is a live key.

Send it by a private channel — not email, not a group chat. Then delete every
copy you made. `shred` overwrites the file before deleting it, so it cannot be
recovered:

```
shred -u ~/handover.token
ls -l ~/handover.token
```

The `ls` should say `No such file or directory`. Run those two lines on **every**
machine the file passed through, including your own laptop.

### A4. Send them the helper script

`tools/pool-run` from this repository does the whole submit-and-retrieve cycle
in one command. Send it along with the token — it saves the recipient four
manual steps every time, and more importantly it means they cannot forget the
last one.

```
scp tools/pool-run <their-mac>:~/
```

If you have no direct route to their machine, send the file however you sent
the token. It contains no hostnames, addresses or credentials.

### A5. Tell them the retrieval rule

Spooled jobs stay in the queue in `Completed` state, holding disk on the entry
node, **until their output is fetched**. Someone who submits and never runs
`condor_transfer_data` slowly fills the volume that holds the schedd's queue —
which stops the entire pool, not just their jobs.

---

## Part B — On the MacBook

Everything here runs as the normal user. Nothing asks for a password.

### B0. Preflight

```
uname -m                  # arm64 = Apple Silicon, x86_64 = Intel
sw_vers -productVersion
ping -c1 <ENTRY_NODE>     # on the office LAN; Bonjour resolves .local natively
nc -zv <ENTRY_NODE> 9618  # the only port the pool uses
```

macOS resolves `.local` through Bonjour with no configuration — none of the
avahi/nsswitch work the Linux machines needed applies here.

If `uname -m` says **arm64**, see [B1a](#b1a-apple-silicon).

### B1. Download

```
cd
curl -fsSL https://get.htcondor.org | /bin/bash -s -- --download
```

**Check what you got before unpacking:**

```
ls -l condor*.tar.gz
```

> **Version skew.** The pool runs **23.4.0**. This script fetches current
> stable, which may now be a later series. HTCondor tolerates some skew, but a
> client much newer than the schedd is asking for trouble.
>
> To see whether the download script can pin a specific release series, run:
>
> ```
> curl -fsSL https://get.htcondor.org | /bin/bash -s -- --help
> ```
>
> If it offers a version or channel option, use it to request 23.x. If it does
> not, download the matching 23.x macOS tarball by hand from the HTCondor
> release archive instead. Prefer a client at or below the pool's version.

<a name="b1a"></a>
#### B1a. Apple Silicon

The published macOS tarballs have been `x86_64_macOS*`. If that is what
downloaded, it runs under **Rosetta 2**, which is fine for command-line tools:

```
softwareupdate --install-rosetta --agree-to-license
```

That is the one step that may prompt for a password. If an `arm64_macOS`
tarball exists by the time you read this, prefer it and skip Rosetta.

### B2. Clear the quarantine flag, then unpack

```
xattr -d com.apple.quarantine condor*.tar.gz
tar -x -f condor*.tar.gz
mv condor-*stripped condor
```

> **This step is not optional and its failure is confusing.** macOS marks
> anything downloaded as quarantined, and Gatekeeper then refuses to execute
> the extracted binaries. The symptom is not a permissions error — it is a
> "cannot be opened" dialog or a killed process. Clear it on the **tarball**,
> before extracting, and the extracted files inherit nothing.

### B3. Do **not** run `make-personal-from-tarball`

The tarball ships a helper that configures a complete personal pool — collector,
negotiator, schedd and startd, all on this laptop. That is the opposite of what
we want. Skip it.

### B4. Configuration

The settings go in a file you own, and one environment variable points HTCondor
at it. Run every line below.

> **Why not `~/.condor/user_config`?** That per-user file is only read when
> HTCondor *daemons* run as a non-root user. This machine runs no daemons at
> all, so it would be silently ignored — the tools would keep using the stock
> configuration and never find the pool. `CONDOR_CONFIG` is read by the tools
> themselves, which is what we need. Verified, not assumed.

```
mkdir -p ~/condor-pool
cat > ~/condor-pool/condor_config <<'EOF'
# Submit-only client for the <POOL_DOMAIN> pool.
#
# No daemons run on this machine. Every connection is outbound, so nothing
# needs to reach this laptop and no firewall change is required.

# --- which pool ---------------------------------------------------------
# The entry node's REAL hostname. Bonjour answers a machine's own name per
# interface, so this resolves to whichever address is reachable from here.
CONDOR_HOST    = <ENTRY_NODE>
COLLECTOR_HOST = $(CONDOR_HOST):9618

# --- naming -------------------------------------------------------------
# condor_submit -remote and condor_q -name call get_full_hostname(), which
# REJECTS any name without a dot. This is what makes remote submission
# possible at all.
DEFAULT_DOMAIN_NAME = local

# Principal namespace only, never resolved as a hostname. Must match the pool
# exactly or the token maps to a different identity.
UID_DOMAIN = <POOL_DOMAIN>

# --- where the token lives ----------------------------------------------
SEC_TOKEN_DIRECTORY = $ENV(HOME)/.condor/tokens.d

# --- run nothing --------------------------------------------------------
# Belt and braces: even if condor_master were started by accident, it would
# have nothing to start.
DAEMON_LIST =
EOF
```

Now make that file the one HTCondor uses, permanently:

```
echo 'export CONDOR_CONFIG="$HOME/condor-pool/condor_config"' >> ~/.zshrc
export CONDOR_CONFIG="$HOME/condor-pool/condor_config"
condor_config_val CONDOR_HOST
```

The last line should print `<ENTRY_NODE>`. If it prints something else, or
`Not defined`, the export did not take — open a new terminal and try again.

`FILESYSTEM_DOMAIN` is deliberately left alone. Hosts that share one are assumed
to share storage and **skip file transfer entirely** — there is no shared
storage here, so setting it pool-wide would silently break every job.

### B5. Install the token

Assuming the file you were given is in your `Downloads` folder and is called
`handover.token`, run all five lines:

```
mkdir -p ~/.condor/tokens.d
chmod 700 ~/.condor/tokens.d
mv ~/Downloads/handover.token ~/.condor/tokens.d/office-pool
chmod 600 ~/.condor/tokens.d/office-pool
ls -l ~/.condor/tokens.d/office-pool
```

If the file is somewhere else or has a different name, change the `mv` line to
match. The name it ends up with — `office-pool` — does not matter to Condor; any
name works, as long as it is inside that folder.

The `ls` should show `-rw-------`. If it does not, run the `chmod 600` line again.

### B6. Make the tools available at every login

macOS defaults to zsh:

```
echo '. ~/condor/condor.sh' >> ~/.zshrc
. ~/condor/condor.sh
```

Open a new terminal and confirm it survived:

```
which condor_submit
```

---

## Part C — On an Ubuntu laptop

Skip this whole part if you are on macOS; Part B covers that.

Ubuntu is the easier of the two, for one reason worth knowing: the version
`apt` installs is **23.4.0**, which is exactly what the pool runs. There is no
version-skew question to worry about, unlike the macOS tarball.

You need `sudo` for step C1 only. If you do not have it, see C7.

### C0. Preflight

```
lsb_release -d
uname -m
ping -c1 <ENTRY_NODE>
```

The `ping` must succeed. If it says `Name or service not known`, mDNS is not
working yet — do C5 first, then come back.

### C1. Install

```
sudo apt update
sudo apt install -y condor
condor_version
```

`condor_version` should print `23.4.0`. If it prints something noticeably
newer, tell the operator before going further.

### C2. Stop it from running anything

The package installs a system service and starts it. This machine submits jobs;
it does not execute them, so nothing should be running.

```
sudo systemctl disable --now condor
systemctl is-active condor
```

The last line should print `inactive`. That is correct, not a failure.

### C3. Configuration

```
sudo tee /etc/condor/config.d/50-submit-client.config > /dev/null <<'EOF'
# Submit-only client. No daemons run on this machine; every connection it makes
# is outbound, so nothing needs to reach this laptop.

# --- which pool ---------------------------------------------------------
CONDOR_HOST    = <ENTRY_NODE>
COLLECTOR_HOST = $(CONDOR_HOST):9618

# --- naming -------------------------------------------------------------
# condor_submit -remote and condor_q -name reject any name without a dot.
DEFAULT_DOMAIN_NAME = local

# Principal namespace only, never resolved as a hostname. Must match the pool
# exactly or the token maps to a different identity.
UID_DOMAIN = <POOL_DOMAIN>

# --- run nothing --------------------------------------------------------
DAEMON_LIST =
EOF
condor_config_val CONDOR_HOST
```

The last line should print `<ENTRY_NODE>`.

`FILESYSTEM_DOMAIN` is deliberately left alone. Machines sharing one are assumed
to share storage and **skip file transfer entirely** — there is no shared
storage here, so setting it would silently break every job.

### C4. Install the token

Assuming the file you were given is in your `Downloads` folder and is called
`handover.token`, run all five lines:

```
mkdir -p ~/.condor/tokens.d
chmod 700 ~/.condor/tokens.d
mv ~/Downloads/handover.token ~/.condor/tokens.d/office-pool
chmod 600 ~/.condor/tokens.d/office-pool
ls -l ~/.condor/tokens.d/office-pool
```

The `ls` should show `-rw-------`. If it does not, run the `chmod 600` line
again.

### C5. Make `.local` names resolve

macOS does this natively; Ubuntu does not always. Check first:

```
getent hosts <ENTRY_NODE>
```

If that prints an address, skip the rest of C5. If it prints nothing:

```
sudo apt install -y avahi-daemon libnss-mdns
grep '^hosts:' /etc/nsswitch.conf
```

The `hosts:` line must contain `mdns4_minimal` **and** end with `mdns4`. A
working line looks exactly like this:

```
hosts:          files mdns4_minimal [NOTFOUND=return] dns mdns4
```

If the trailing `mdns4` is missing, add it:

```
sudo sed -i 's/^\(hosts:.*dns\)$/\1 mdns4/' /etc/nsswitch.conf
grep '^hosts:' /etc/nsswitch.conf
getent hosts <ENTRY_NODE>
```

The trailing `mdns4` matters: without it, a name is only tried through mDNS
*before* DNS, and a DNS server that answers "no such host" ends the search.

### C6. Verify

Run all of these. Do not stop early — passing the first three and failing the
fourth is the normal failure.

```
condor_config_val CONDOR_HOST
condor_config_val UID_DOMAIN
condor_config_val DAEMON_LIST
pgrep -a condor_ || echo "no condor processes - correct"
condor_ping -verbose -type COLLECTOR READ
condor_status
condor_q -name <ENTRY_NODE>
```

`condor_config_val DAEMON_LIST` printing an empty line is correct. Then run the
hello-job test in section 3 — that is the only check that proves anything.

### C7. If you do not have sudo

Use the tarball instead, exactly as in Part B, with three changes:

- Skip B1a and B2 entirely. Those are macOS-specific (Rosetta, and clearing
  Gatekeeper's quarantine flag). Linux has neither.
- In B6, use `~/.bashrc` instead of `~/.zshrc`, since Ubuntu defaults to bash.
- Everything else — the download, `CONDOR_CONFIG`, the token — is identical.

---

## 3. Verification

Run all four. **Passing the first three and failing the fourth is the normal
failure**, so do not stop early.

```
# 1. Tools present and configured
condor_config_val CONDOR_HOST
condor_config_val UID_DOMAIN
condor_config_val DAEMON_LIST        # must be empty

# 2. Nothing is running locally
pgrep -fl condor_ || echo "no condor processes - correct"

# 3. The token authenticates
condor_ping -verbose -type COLLECTOR READ

# 4. The pool answers
condor_status
condor_q -name <ENTRY_NODE>
```

Then the only test that actually proves anything — a job that runs and comes
back:

```
mkdir -p ~/condor-hello && cd ~/condor-hello
cat > hello.sh <<'EOF'
#!/bin/sh
echo "ran on : $(hostname -f)"
echo "as     : $(id -un)"
EOF
chmod +x hello.sh
cat > hello.sub <<'EOF'
universe                = vanilla
executable              = hello.sh
output                  = out.$(Cluster).$(Process)
error                   = err.$(Cluster).$(Process)
log                     = hello.log
should_transfer_files   = YES
when_to_transfer_output = ON_EXIT
request_cpus            = 1
request_memory          = 128
request_disk            = 64MB
queue 2
EOF

condor_submit -remote <ENTRY_NODE> -spool hello.sub
```

Now watch the queue. Run this line again every few seconds:

```
condor_q -name <ENTRY_NODE>
```

Each job shows a status letter. `I` means idle (waiting for a machine), `R`
means running, `C` means completed. When both jobs show `C`, or the queue prints
`0 jobs`, they are finished — usually well under a minute.

Then fetch the output and look at it:

```
condor_transfer_data -name <ENTRY_NODE> -all
cat out.*
```

Two files naming two different pool machines means it works end to end.

---

## 4. Daily use

### The easy way

If you were given `pool-run`, put it somewhere permanent and make it runnable.
Do this once:

On **macOS**:

```
mkdir -p ~/bin
mv ~/pool-run ~/bin/pool-run
chmod +x ~/bin/pool-run
echo 'export PATH="$HOME/bin:$PATH"' >> ~/.zshrc
export PATH="$HOME/bin:$PATH"
```

On **Ubuntu**, the same five lines with `~/.bashrc` in place of `~/.zshrc`:

```
mkdir -p ~/bin
mv ~/pool-run ~/bin/pool-run
chmod +x ~/bin/pool-run
echo 'export PATH="$HOME/bin:$PATH"' >> ~/.bashrc
export PATH="$HOME/bin:$PATH"
```

After that, every run is one command:

```
pool-run myjob.sub <ENTRY_NODE>
```

It submits, waits, brings each job's output back the moment that job finishes,
and frees the space on the entry node. It prints progress like
`retrieved 7/100` as results arrive. When it says `done`, everything is on your
laptop and nothing is left behind.

That is all most people need. The rest of this section explains what it is
doing, and how to do it by hand if you prefer.

### The manual way

Four steps every time. Step 1 prints a cluster number, like
`1 job(s) submitted to cluster 42`. Use that number — `42` in this example — in
steps 3 and 4.

```
condor_submit -remote <ENTRY_NODE> -spool myjob.sub
```

```
condor_q -name <ENTRY_NODE>
```

```
condor_transfer_data -name <ENTRY_NODE> 42
```

```
condor_rm -name <ENTRY_NODE> 42
```

`-spool` sends the input files with the job, so the laptop does not need to stay
reachable — or awake — while the job runs.

**Step 3 is not optional.** Output sits in the entry node's spool until you
fetch it. Nothing sends it to you.

**Step 4 is not optional either, and it deletes nothing of yours.** The job has
already finished and its output is already on your laptop by then; `condor_rm`
only frees the disk the job was still holding on the entry node. Skip it and
that space stays occupied for ten days. See A5 for why that matters to everyone
else.

### Writing jobs for this pool

Machines here are people's desktops and reclaim themselves without warning:

- Many short jobs, not few long ones.
- Jobs must be **idempotent** — restartable from scratch without corrupting state.
- Long work should self-checkpoint (`checkpoint_exit_code`).
- "My job keeps restarting" is a property of a desktop pool, not a bug.
- `request_memory` is a **matchmaking figure**, not an enforced cap. Ask for
  roughly what you need; nothing will OOM-kill you at that number.
- Jobs are pinned to the submitting machine's architecture by default, so an
  x86_64 client will not accidentally match ARM workers.
- They are pinned to **Linux** by default too. `condor_submit` adds
  `(OpSys == "LINUX")` unless your requirements already mention `OpSys`, so the
  pool's two Mac minis are invisible to an ordinary job. Reaching them is opt-in:
  `requirements = (OpSys == "macOS")`. Note `macOS`, not `OSX`. Check what your
  job will actually ask for with `condor_submit -dry-run /dev/stdout <file>.sub`
  before queueing — this is the one requirement people get wrong, and the
  symptom is a job that sits Idle forever against a machine that is Unclaimed.

### Software already on every worker

Installed under `/opt/products` on all seven x86\_64 machines, identical
version on each, and on both Mac minis at the same paths but **not** the same
versions — see the warning at the end of this section. **Call these by
absolute path.** They are deliberately not
assumed to be on `PATH` inside a job, and a job that means a particular version
should say which.

```
openEMS       /opt/products/openEMS/bin/openEMS
              /opt/products/openEMS/venv/bin/python     (import openEMS, CSXCAD)

yosys         /opt/products/yosys/v0.66/install/bin/yosys
nextpnr-ecp5  /opt/products/nextpnr/v0.10/install/bin/nextpnr-ecp5
ecppack       /opt/products/prjtrellis/1.4-79-g56bb170/install/bin/ecppack
```

A worked ECP5 flow, verified running on the pool as `nobody`:

```
yosys -q -p "synth_ecp5 -json out.json" design.v
nextpnr-ecp5 --25k --package CABGA256 --json out.json --textcfg out.config
ecppack out.config out.bit
```

**Why `/opt` and not a home directory.** Jobs run as `nobody`, and a home
directory at mode 750 cannot even be traversed by that account - software
installed under `~` is invisible to every job on every machine. All of
`/opt/products` is world-readable; your own home directory on a worker is not.

**The versions are pinned and identical pool-wide**, so the same job produces
the same result wherever it lands. That is not automatic: before this was
tidied, a bare `yosys` resolved to four different versions across seven
machines, and jobs synthesised differently depending on placement. If you need
a version that is not installed, ask rather than installing your own on one
machine.

**The Mac minis are currently an exception, deliberately and temporarily.** They
were built against the newest release tags so the Linux hosts could be brought
up to them afterwards, so right now the pool is not uniform:

| | Linux workers | both Mac minis |
|---|---|---|
| yosys | `v0.66` | `v0.68` |
| nextpnr-ecp5 | `v0.10` | `v0.11` |
| prjtrellis | `1.4-79-g56bb170` | same |
| openEMS | `v0.37.0-rc1-2-g7b051bb` | same |

For openEMS this does not matter — same commit, and the numerical result was
identical. For the FPGA flow it does: yosys 0.68 and 0.66 do not emit
byte-identical netlists, so a synthesis job would produce different output
depending on where it landed. The two Macs agree with each other - verified
byte-identical, same sha256, on an ECP5 flow run through Condor on both - so
placement between them is safe; it is Mac-versus-Linux that differs.

**In practice the default protects you.** An ordinary job carries
`OpSys == "LINUX"` and cannot reach the Mac at all, so this can only bite
someone who has explicitly opted in. Until the Linux hosts are upgraded, do not
target the Mac for FPGA work you intend to compare against earlier results.
openEMS is safe to send there, and considerably faster.

---

## 5. Off the office LAN

mDNS is link-local: `<ENTRY_NODE>` stops resolving the moment the laptop leaves.
Two options, both already in use elsewhere in this project.

**Tailscale (simplest).** Install it on the laptop, join the tailnet, and use
the MagicDNS name instead of the `.local` one. Nothing else changes — swap the
name in `CONDOR_HOST`, or keep two config snippets and switch.

**ssh tunnel.** Forward the one port the pool uses:

```
ssh -N -L 9618:<ENTRY_NODE>:9618 <ENTRY_NODE>
```

then point `CONDOR_HOST` at `localhost`. Note this needs an ssh login on the
entry node, which the normal path deliberately avoids — it is a fallback, not
the design.

### What happens when the laptop sleeps

Nothing bad, and this is by design. There is no schedd here, so the queue lives
on the entry node and keeps running. Jobs continue, complete, and wait in spool.
On waking, `condor_q` and `condor_transfer_data` pick up where they left off.

A machine with a local queue would not behave that way — which is exactly why
user machines in this pool do not run one.

---

## 6. When it does not work

This pool has a well-documented failure signature: **the configuration parses
cleanly, the tools report correct values, and nothing works.** Diagnose in this
order.

| Symptom | Likely cause | Check |
|---|---|---|
| `Error: unknown host` | Off-LAN, so mDNS cannot resolve | `ping -c1 <ENTRY_NODE>`; use Tailscale |
| Binary "cannot be opened" / killed | **macOS**: Gatekeeper quarantine not cleared | Re-do B2 from a fresh tarball |
| `command not found: condor_submit` | **macOS**: `condor.sh` not sourced in this shell | `. ~/condor/condor.sh`; check `~/.zshrc` |
| `command not found: condor_submit` | **Ubuntu**: package not installed | `sudo apt install -y condor` |
| Tools find the wrong pool, or `Not defined` | **macOS**: `CONDOR_CONFIG` not exported in this shell | `echo $CONDOR_CONFIG`; open a new terminal |
| `getent hosts <ENTRY_NODE>` prints nothing | **Ubuntu**: mDNS not set up | See C5 |
| A condor daemon is running on this laptop | **Ubuntu**: the package service was left enabled | `sudo systemctl disable --now condor` |
| `condor_ping` fails or hangs on a trust prompt | Token missing, wrong mode, or wrong identity | `ls -l ~/.condor/tokens.d/` — must be `600` |
| Authenticates but jobs never start | Identity has no account on the entry node | See A1 — this is the known open risk |
| `Hold code 16` during submit | Normal and transient — input files spooling | Wait |
| Jobs complete but no output locally | `condor_transfer_data` not run | Run it; spooled output is not pushed |
| Everything looks fine, nothing runs | Pool machines are busy and declining work | `condor_status -af Name Start TotalLoadAvg HostMemAvailMB` |

That last row is worth understanding rather than escalating. Machines in this
pool advertise their full capacity but refuse work based on **measured** load,
memory and disk pressure. A machine showing free slots and still declining is
working as designed — its owner is using it.

---

## 7. Uninstall

Complete removal, no root, nothing left behind:

**On macOS**, run all five lines. The third and fourth delete the two startup
lines from your shell configuration; the fifth confirms they are gone and
should print nothing.

```
rm -rf ~/condor ~/condor-pool ~/.condor ~/condor-hello
rm -f ~/condor*.tar.gz
sed -i '' '/condor\/condor.sh/d' ~/.zshrc
sed -i '' '/CONDOR_CONFIG/d' ~/.zshrc
grep -i condor ~/.zshrc
```

**On Ubuntu**, run all four lines instead. `--purge` removes the configuration
in `/etc/condor` as well as the program.

```
sudo apt remove --purge -y condor
sudo rm -rf /etc/condor
rm -rf ~/.condor ~/condor-hello
grep -i condor ~/.bashrc
```

The `grep` should print nothing. If you used the no-sudo tarball route instead
of `apt`, use the macOS lines above but with `~/.bashrc` in place of
`~/.zshrc`, and drop the `''` after `sed -i` — that empty argument is a macOS
quirk that Ubuntu's `sed` rejects.

Then tell the operator, so the token can be treated as revoked and the entry
node account removed if it was created for this.

---

## 8. Known open risks

Stated plainly, because two of these are unverified rather than solved.

| Risk | Status |
|---|---|
| Remote submit **without** a Unix account on the entry node | **Confirmed impossible**, 2026-08-25. `condor_submit` fails with *"Setting owner to X, which is not a valid user account"* while authentication, authorisation and `condor_q` all still succeed. The schedd runs one shadow per job as that user, so the account is required. A1 is not a workaround but the fix |
| Apple Silicon native build | **Unverified.** Published macOS tarballs have been x86_64; Rosetta 2 covers it, at some startup cost |
| Client/pool version skew | Pool is 23.4.0. Pin the client to 23.x if the download script allows it |
| Token revocation | There is no per-token revocation short of rotating the pool signing key, which invalidates **every** token. Treat the file accordingly |
| Off-LAN access depends on Tailscale | Not part of the pool's own design; if the tailnet is down, so is submission from outside |
