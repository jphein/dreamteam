#!/usr/bin/env bash
# dreamteam — CHECK <host>-io: can an interactive process still use this host's disk? (docs/CHECKS.md)
#
#   host-io-check.sh        run the probe, read the pressure, publish the line
#
# Two instruments, because each one alone misleads (Flow row 7e039111):
#   victim   scripts/lib/io_probe.py: small direct reads and synced appends for a few seconds, as a session at a
#            prompt does them. Its fsync p99 is what a person feels.
#   pressure /proc/pressure/io "full avg60": the share of the last minute in which work waited on the disk.
#            High pressure with a calm victim is one batch reader waiting on itself; a slow victim at modest
#            pressure is a freeze.
#
# Line:  CHECK <host>-io ok   · fsync p99 8 ms (max 23), read p99 1 ms, io pressure full avg60 3%, on <dir> · every 5 min, owner Sen
#        CHECK <host>-io warn · the same facts · … when fsync p99 is over $DREAMTEAM_IO_FSYNC_WARN_MS (default 100),
#                               or pressure full avg60 is over $DREAMTEAM_IO_PSI_WARN (default 20)
#        CHECK <host>-io fail · the probe could not run: <reason> | pressure unreadable · owner Sen
#        The name carries the host itself (familiar-io, serialhub-io): each host has its own disk.
#
# Probe dir: $DREAMTEAM_IO_PROBE_DIR, else ${XDG_CACHE_HOME:-~/.cache}/dreamteam (so: the disk your home's cache
#   is on; point it at another disk to judge that one). A 64 MiB file is made there once.
# Seconds:   $DREAMTEAM_IO_PROBE_SECS (default 5).
# The probe runs at NORMAL priority on purpose: it stands in for the person, not for a batch job. Its unit must
# not be put in lanes.slice.
# Exit: 0 line published (any status) · 1 line not published · 22 bad argument.
set -uo pipefail
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck disable=SC1091
. "$ROOT/scripts/lib/check-line.sh"
[ "$#" -eq 0 ] || { echo "usage: host-io-check.sh" >&2; exit 22; }

h="${DREAMTEAM_CHECK_HOST:-$(hostname 2>/dev/null)}"; h=${h,,}; h=${h//[^a-z0-9-]/}; h=${h:-unknown-host}
NAME="$h-io"
OWNER="every 5 min, owner Sen"
DIR="${DREAMTEAM_IO_PROBE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/dreamteam}"
SECS="${DREAMTEAM_IO_PROBE_SECS:-5}"
FW="${DREAMTEAM_IO_FSYNC_WARN_MS:-100}"; PW="${DREAMTEAM_IO_PSI_WARN:-20}"
PSI_FILE="${DREAMTEAM_PSI_IO:-/proc/pressure/io}"
[[ "$FW" =~ ^[0-9]{1,6}$ ]] && [[ "$PW" =~ ^[0-9]{1,3}$ ]] || { check_line "$NAME" fail "a warn threshold is not a whole number" "$OWNER"; exit $?; }

psi=$(awk '$1 == "full" { for (i = 2; i <= NF; i++) if ($i ~ /^avg60=/) { sub("avg60=", "", $i); print $i } }' "$PSI_FILE" 2>/dev/null)
[[ "$psi" =~ ^[0-9]+(\.[0-9]+)?$ ]] || { check_line "$NAME" fail "pressure unreadable ($PSI_FILE)" "$OWNER"; exit $?; }

err=$(mktemp) || { check_line "$NAME" fail "no temp file" "$OWNER"; exit $?; }
trap 'rm -f "$err"' EXIT
if ! out=$(python3 -I "$ROOT/scripts/lib/io_probe.py" "$DIR" "$SECS" 2>"$err"); then
  check_line "$NAME" fail "the probe could not run: $(head -c 160 "$err" | tr '\n' ' ')" "$OWNER"; exit $?
fi
read -r fp99 fmax rp99 < <(printf '%s' "$out" | jq -r '[.fsync_p99, .fsync_max, .read_p99] | map(tostring) | join(" ")' 2>/dev/null) || true
[[ "${fp99:-}" =~ ^[0-9]+(\.[0-9]+)?$ ]] && [[ "${rp99:-}" =~ ^[0-9]+(\.[0-9]+)?$ ]] \
  || { check_line "$NAME" fail "the probe printed no numbers" "$OWNER"; exit $?; }

st=ok
awk -v a="$fp99" -v b="$FW" 'BEGIN { exit !(a > b) }' && st=warn
awk -v a="$psi" -v b="$PW" 'BEGIN { exit !(a > b) }' && st=warn
fact=$(printf 'fsync p99 %.0f ms (max %.0f), read p99 %.0f ms, io pressure full avg60 %.0f%%, on %s' "$fp99" "$fmax" "$rp99" "$psi" "$DIR")
check_line "$NAME" "$st" "$fact" "$OWNER"
