# Handover: submit node on a macOS laptop

Setting up a machine to submit jobs into the pool, where **the machine is not
yours**. That constraint decides most of what follows: no root, no daemons, no
launchd service, nothing outside the user's home directory, and a one-line
uninstall.

Hand this file to whoever owns the laptop. They can do all of Part B without
you, and without administrator access.

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

**This is the one thing that can block the whole setup**, and it is currently
unverified in this pool.

Every submitter so far has had a Unix account on the entry node, so we have
never proven that remote submission works *without* one. The schedd has to map
an authenticated identity to something it can run a shadow as.

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
  isolation both depend on it.

### A2. Issue a *user* token

On the entry node:

```
sudo condor_token_create -identity <USER>@<POOL_DOMAIN>
```

That prints the token to stdout. Capture it to a file with `umask 077`.

> **User token, not a daemon token.** A daemon token (`condor@…`) would let that
> laptop act as pool infrastructure. It only needs to submit.

### A3. Deliver it, then destroy every copy you made

The token is a **bearer credential with no machine binding**: anything that can
read the file can act as that identity. It is not tied to the laptop, so a copy
left in `~/` or in a chat log is a live key.

Hand it over out of band, then `shred -u` every intermediate copy on every
machine that touched it, including your own.

### A4. Tell them the retrieval rule

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
> client much newer than the schedd is asking for trouble. Run the script with
> `--help` to see whether it can pin a release series; if it cannot, download
> the matching 23.x macOS tarball directly from the HTCondor release archive
> instead. Prefer a client at or below the pool's version.

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

```
mkdir -p ~/.condor
cat > ~/.condor/user_config <<'EOF'
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

# --- run nothing --------------------------------------------------------
# Belt and braces: even if condor_master were started by accident, it would
# have nothing to start.
DAEMON_LIST =
EOF
```

`FILESYSTEM_DOMAIN` is deliberately left alone. Hosts that share one are assumed
to share storage and **skip file transfer entirely** — there is no shared
storage here, so setting it pool-wide would silently break every job.

### B5. Install the token

```
mkdir -p ~/.condor/tokens.d
chmod 700 ~/.condor/tokens.d
# move the token file you were given into place, then:
chmod 600 ~/.condor/tokens.d/*
```

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
condor_q -name <ENTRY_NODE>
# wait until JobStatus is 4 (Completed), then:
condor_transfer_data -name <ENTRY_NODE> -all
cat out.*
```

Two files naming two different pool machines means it works end to end.

---

## 4. Daily use

```
condor_submit -remote <ENTRY_NODE> -spool myjob.sub
condor_q      -name   <ENTRY_NODE>
condor_transfer_data -name <ENTRY_NODE> -all
```

`-spool` sends the input files with the job, so the laptop does not need to stay
reachable — or awake — while the job runs.

**Always retrieve.** Output sits in the entry node's spool until fetched, and
that volume also holds the schedd's queue. See A4.

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
| Binary "cannot be opened" / killed | Gatekeeper quarantine not cleared | Re-do B2 from a fresh tarball |
| `command not found: condor_submit` | `condor.sh` not sourced in this shell | `. ~/condor/condor.sh`; check `~/.zshrc` |
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

```
rm -rf ~/condor ~/.condor ~/condor-hello
rm -f  ~/condor*.tar.gz
# remove the '. ~/condor/condor.sh' line from ~/.zshrc
```

Then tell the operator, so the token can be treated as revoked and the entry
node account removed if it was created for this.

---

## 8. Known open risks

Stated plainly, because two of these are unverified rather than solved.

| Risk | Status |
|---|---|
| Remote submit **without** a Unix account on the entry node | **Unverified.** Every submitter so far had one. A1 works around it by creating one |
| Apple Silicon native build | **Unverified.** Published macOS tarballs have been x86_64; Rosetta 2 covers it, at some startup cost |
| Client/pool version skew | Pool is 23.4.0. Pin the client to 23.x if the download script allows it |
| Token revocation | There is no per-token revocation short of rotating the pool signing key, which invalidates **every** token. Treat the file accordingly |
| Off-LAN access depends on Tailscale | Not part of the pool's own design; if the tailnet is down, so is submission from outside |
