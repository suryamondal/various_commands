#!/bin/sh
# Fail if anything that must stay local has reached a TRACKED file.
#
# TWO DESIGN RULES, both learned by getting them wrong.
#
# 1. Scan `git ls-files`, not a hand-written list. The list version scanned
#    only latex/, so the same text pasted into README.md was invisible to it -
#    and it could not see the Makefile that called it either. Scanning what git
#    tracks makes the check self-covering by construction: this script is in
#    its own scan.
#
# 2. Never list machine names here. Names are read at runtime from
#    condor-host-list, which is untracked BY DESIGN. An earlier version spelled
#    them out in the Makefile, which put the exact strings the check exists to
#    catch into a tracked, public file.
#
# If condor-host-list is absent (a fresh clone), only the structural patterns
# run. That is a weaker check, not a silent pass - it says so.

cd "$(dirname "$0")/.." || exit 2

NAMES_FILE=condor-host-list

# Structural patterns describe a SHAPE, not a value, so they are safe to track.
# Deliberately require digits in the last two octets, so a masked form like
# 172.16.0.x/23 - which is intentional in the docs - still passes.
P='(10|172\.(1[6-9]|2[0-9]|3[01])|192\.168)\.[0-9]{1,3}\.[0-9]{1,3}'
P="$P|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}"
P="$P|fd[0-9a-f]{2}[0-9a-f]*[:-][0-9a-f]+[:-][0-9a-f:-]{4,}"
P="$P|BEGIN [A-Z ]*PRIVATE KEY"
P="$P|eyJ[A-Za-z0-9_-]{20,}"

if [ -f "$NAMES_FILE" ]; then
    NAMES=$(grep -ohE '[A-Za-z0-9][A-Za-z0-9._-]*\.(local|internal)' "$NAMES_FILE" 2>/dev/null |
            sed -E 's/\.(local|internal)$//' | sort -u | sed '/^$/d' | paste -sd'|' -)
    [ -n "$NAMES" ] && P="$P|$NAMES"
else
    echo "   note: $NAMES_FILE absent - structural patterns only, names unchecked"
fi

# --cached --others --exclude-standard: tracked files PLUS new files that are
# not ignored. A brand-new file is not in `git ls-files` until it is added, so
# without --others its first commit would go unchecked - including this script's
# own first commit.
if git ls-files -z --cached --others --exclude-standard | xargs -0 grep -nEI "$P" 2>/dev/null; then
    echo "   LEAK - the above are TRACKED files and must not be committed"
    exit 1
fi

echo "   clean"
