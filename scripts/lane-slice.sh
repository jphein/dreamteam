#!/usr/bin/env bash
# dreamteam — lane-slice: one systemd slice that every lane session and every gate runs under.
#
# WHY (Flow row 7e039111). Lanes share a host with the lead's session and with the person typing. "nice 15,
# idle class" is a request each lane has to remember and that stops at the first socket; a slice is a property of
# where the process lives. The slice carries CPUWeight, MemoryHigh / MemorySwapMax and IOWeight, so under
# contention the lanes together get a small share and everything outside keeps its normal one. With no
# contention a weight costs nothing: a lane alone on the host runs at full speed.
#   IOWeight is real only where (a) io.cost is enabled for the device (scripts/host/io-shield) and (b) the io
#   controller is delegated to the user manager (systemd/system/user@.service.d/20-delegate-io.conf, effective
#   from the next boot). `status` says which of the two is missing. CPUWeight and the memory limits need neither.
#
#   lane-slice.sh install     write the slice unit and the Slice= drop-ins from config, reload the user manager
#   lane-slice.sh attach      move every lane session's processes into lane-<session>.scope inside the slice
#   lane-slice.sh status      the slice's settings, each session's place, and what IOWeight still waits for
#   lane-slice.sh uninstall   remove the unit and drop-ins this tool wrote (running scopes stay until they end)
#
# CONFIG (config.json `.lanes`, per-host overlay config.<host>.json; this repo is public, so session names live
# in the overlay):
#   enabled        false by default: nothing happens on a host that has not opted in
#   exclude        REQUIRED when enabled, may be []: tmux session names that are NOT lanes (the lead's session,
#                  a person's own). Without the key the tool refuses: a default that put the lead in the lanes
#                  slice would be the opposite of the point.
#   lead           tmux session names of the fleet lead (default []). Never a lane (excluded without being listed
#                  there), and PROTECTED from systemd-oomd: the cgroup of each of its panes gets the
#                  `user.oomd_avoid` mark on every attach run. See "THE LEAD" below.
#   cpuWeight 50 · ioWeight 25 · memoryHigh "" · memorySwapMax ""   (empty = not set)
#   units          user units that are gates or batch timers; each gets <unit>.d/20-lanes-slice.conf with
#                  Slice=lanes.slice (effective at that unit's next start)
#
# attach: a session's processes are the panes' pids and all their descendants. Each one not yet in the slice is
# moved with the manager's AttachProcessesToUnit (the call scope-attach.sh uses); children started later
# inherit the place. A process inside a dreamteam-*.scope (a memory-capped agent fleet) is left there. A
# lane-<session>.scope whose session is gone and that holds only its anchor is stopped, by unit name.
# Nothing here signals or restarts a session.
#
# THE LEAD (Flow row f72945bc). 2026-11-22 04:26 systemd-oomd killed the lead's pane scope, 473 MB, out of 127
# cgroups under the user manager, and the lead was down 37 hours. oomd picks by reclaim activity, not by who
# matters; a cgroup marked "avoid" is passed over while any unmarked candidate exists. Measured on serialhub
# 2026-11-23 in a test slice with its own MemoryHigh and its own oomd watch (two scopes, the bigger one the
# "lead"; /home/jp/work/iotest/oom-test*.sh on that host):
#     no mark                                                      → oomd killed the LEAD scope
#     ManagedOOMPreference=avoid given when the scope is created   → the lane scope killed, the lead lives
#     `systemctl --user set-property --runtime … ManagedOOMPreference=avoid` on the EXISTING scope
#                                                                  → the property reads "avoid", NO mark is
#                                                                    written, and oomd killed the LEAD scope
#     the mark written straight onto the existing scope's cgroup   → the lane scope killed, the lead lives
# The lead's scope always exists already (tmux made it), so this tool writes the mark itself: the extended
# attribute user.oomd_avoid=1 on the pane's cgroup directory, which the user owns. No process is moved, nothing
# restarts, and a relaunched lead (a new scope) is marked again within one timer period. Lanes get no mark.
# OOMScoreAdjust is the KERNEL's out-of-memory order and a user cannot lower it (measured: a scope refuses the
# property, a user service is clamped to the manager's 100, a write to /proc/self/oom_score_adj is denied).
# Root can: scripts/host/io-shield `oomprotect <uid> <score>` gives that score to every process in a cgroup
# that carries the mark.
#
# Exit: 0 done (also: not enabled) · 1 something could not be done · 2 refused (config) · 22 bad argument.
set -uo pipefail
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CFG="${DREAMTEAM_CONFIG:-$ROOT/config.json}"
UDIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
PROC="${DREAMTEAM_PROC:-/proc}"
CGROOT="${DREAMTEAM_CGROUP_ROOT:-/sys/fs/cgroup}"
MARK="# written by dreamteam lane-slice.sh; edit config.json .lanes and run install again"
SLICE=lanes

[ "$#" -eq 1 ] || { echo "usage: lane-slice.sh install|attach|status|uninstall" >&2; exit 22; }
MODE=$1
case "$MODE" in install|attach|status|uninstall) ;; *) echo "usage: lane-slice.sh install|attach|status|uninstall" >&2; exit 22 ;; esac
command -v jq >/dev/null 2>&1 || { echo "lane-slice: jq is needed" >&2; exit 1; }

MERGED="$(python3 -I "$ROOT/scripts/lib/config_merge.py" "$CFG" 2>/dev/null)" || { echo "lane-slice: the config or this host's overlay is not valid; nothing done" >&2; exit 2; }
get() { printf '%s' "$MERGED" | jq -r "$1" 2>/dev/null; }
ENABLED=$(get 'if .lanes.enabled == true then "true" else "false" end')
uc() { systemctl --user "$@"; }
ours() { [ -f "$1" ] && [ ! -L "$1" ] && head -n 1 "$1" 2>/dev/null | grep -qxF "$MARK"; }

if [ "$MODE" = uninstall ]; then
  rc=0
  for f in "$UDIR/$SLICE.slice" "$UDIR"/*.d/20-lanes-slice.conf; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    if ours "$f"; then rm -f -- "$f" && echo "removed $f" || rc=1; rmdir --ignore-fail-on-non-empty "$(dirname "$f")" 2>/dev/null || true
    else echo "lane-slice: $f is not ours; left alone" >&2; rc=1; fi
  done
  uc daemon-reload || rc=1
  exit "$rc"
fi

if [ "$ENABLED" != true ]; then
  [ "$MODE" = status ] && echo "lanes: not enabled on this host (config .lanes.enabled)"
  exit 0
fi
[ "$(get '.lanes | has("exclude")')" = true ] && [ "$(get '.lanes.exclude | type')" = array ] \
  || { echo "lane-slice: .lanes.exclude is required when enabled (a list, may be empty): name the sessions that are not lanes" >&2; exit 2; }
mapfile -t EXCLUDE < <(get '.lanes.exclude[] | strings')
[ "$(get '.lanes.lead // [] | type')" = array ] || { echo "lane-slice: .lanes.lead must be a list of tmux session names" >&2; exit 2; }
mapfile -t LEAD < <(get '.lanes.lead // [] | .[] | strings')
EXCLUDE+=("${LEAD[@]}")                                   # the lead is never a lane, listed in exclude or not
CPUW=$(get '.lanes.cpuWeight // 50'); IOW=$(get '.lanes.ioWeight // 25')
MHIGH=$(get '.lanes.memoryHigh // ""'); MSWAP=$(get '.lanes.memorySwapMax // ""')
mapfile -t UNITS < <(get '.lanes.units // [] | .[] | strings')
weight() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 10000 ]; }
size() { [[ "$1" =~ ^([0-9]{1,6}[KMGT]?|[0-9]{1,3}%|infinity)$ ]]; }
weight "$CPUW" && weight "$IOW" || { echo "lane-slice: cpuWeight and ioWeight must be 1-10000" >&2; exit 2; }
{ [ -z "$MHIGH" ] || size "$MHIGH"; } && { [ -z "$MSWAP" ] || size "$MSWAP"; } || { echo "lane-slice: memoryHigh / memorySwapMax must look like 12G, 800M, 40% or infinity" >&2; exit 2; }
for u in "${UNITS[@]}"; do [[ "$u" =~ ^[A-Za-z0-9][A-Za-z0-9@_.:-]{0,120}\.(service|scope)$ ]] || { echo "lane-slice: '$u' in .lanes.units is not a plain unit name" >&2; exit 2; }; done
excluded() { local e; for e in "${EXCLUDE[@]}"; do [ "$e" = "$1" ] && return 0; done; return 1; }

put() {   # put <path> <content>: write a file of ours; refuse to replace one that is not
  if [ -e "$1" ] || [ -L "$1" ]; then ours "$1" || { echo "lane-slice: $1 exists and is not ours; refusing" >&2; return 1; }; fi
  mkdir -p "$(dirname "$1")" && printf '%s\n' "$2" > "$1.tmp.$$" && mv -f "$1.tmp.$$" "$1"
}

case "$MODE" in
  install)
    rc=0
    body="$MARK
[Unit]
Description=dreamteam lanes: every lane session and gate on this host (scripts/lane-slice.sh)

[Slice]
CPUWeight=$CPUW
IOWeight=$IOW"
    [ -n "$MHIGH" ] && body="$body
MemoryHigh=$MHIGH"
    [ -n "$MSWAP" ] && body="$body
MemorySwapMax=$MSWAP"
    put "$UDIR/$SLICE.slice" "$body" && echo "wrote $UDIR/$SLICE.slice" || rc=1
    for u in "${UNITS[@]}"; do
      put "$UDIR/$u.d/20-lanes-slice.conf" "$MARK
[${u##*.}]
Slice=$SLICE.slice" && echo "wrote $UDIR/$u.d/20-lanes-slice.conf (effective at the unit's next start)" || rc=1
    done
    # '[service]' / '[scope]' is not a section systemd knows: the section name is capitalised
    for u in "${UNITS[@]}"; do f="$UDIR/$u.d/20-lanes-slice.conf"; ours "$f" && sed -i -e 's/^\[service\]$/[Service]/' -e 's/^\[scope\]$/[Scope]/' "$f"; done
    uc daemon-reload || { echo "lane-slice: daemon-reload failed" >&2; rc=1; }
    exit "$rc" ;;
esac

# ── attach and status both need the sessions ─────────────────────────────────────────────────────────────
command -v tmux >/dev/null 2>&1 || { echo "lane-slice: no tmux here; nothing to place"; exit 0; }
mapfile -t SESSIONS < <(tmux list-sessions -F '#{session_name}' 2>/dev/null)
declare -A KIDS=()
while read -r p pp; do [ -n "${p:-}" ] && KIDS[$pp]="${KIDS[$pp]:-} $p"; done < <(ps -eo pid=,ppid= 2>/dev/null)
tree() {   # tree <pid>...: the pids and all their descendants
  local q=("$@") out=() p c
  while [ "${#q[@]}" -gt 0 ]; do
    p=${q[0]}; q=("${q[@]:1}"); out+=("$p")
    for c in ${KIDS[$p]:-}; do q+=("$c"); done
  done
  printf '%s\n' "${out[@]}"
}
cg() { local l; l=$(cat "$PROC/$1/cgroup" 2>/dev/null | tail -n 1) && printf '%s' "${l#*::}"; }
unit_of() { printf 'lane-%s.scope' "$(printf '%s' "$1" | tr -c 'A-Za-z0-9_-' '_')"; }

# The cgroup directory of a pane's process, if it is a scope of its own below the user manager (never a slice or
# a service shared with others: marking those would shield whatever else lives there).
lead_dirs() {   # lead_dirs <session> → one cgroup dir per line
  local p c
  while read -r p; do
    [ -n "$p" ] || continue
    c=$(cg "$p") || continue
    case "$c" in */user@*.service/*.scope) printf '%s\n' "$CGROOT$c" ;; esac
  done < <(tmux list-panes -s -t "=$1" -F '#{pane_pid}' 2>/dev/null) | sort -u
}
marked() { python3 -I -c 'import os, sys
try: sys.exit(0 if os.getxattr(sys.argv[1], "user.oomd_avoid") == b"1" else 1)
except OSError: sys.exit(1)' "$1" 2>/dev/null; }

if [ "$MODE" = status ]; then
  for s in "${LEAD[@]}"; do
    n=0; while read -r d; do [ -n "$d" ] || continue; n=$((n + 1)); if marked "$d"; then echo "lead $s: $(basename "$d") carries the oomd avoid mark"; else echo "lead $s: $(basename "$d") is NOT marked (the next attach run marks it)"; fi; done < <(lead_dirs "$s")
    [ "$n" -gt 0 ] || echo "lead $s: no pane in a scope of its own (session gone, or its panes share a unit)"
  done
  echo "slice $SLICE.slice: CPUWeight=$(uc show "$SLICE.slice" -p CPUWeight --value 2>/dev/null) IOWeight=$(uc show "$SLICE.slice" -p IOWeight --value 2>/dev/null) MemoryHigh=$(uc show "$SLICE.slice" -p MemoryHigh --value 2>/dev/null)"
  mine="$CGROOT/user.slice/user-$(id -u).slice/user@$(id -u).service"
  if grep -qw io "$mine/cgroup.controllers" 2>/dev/null && grep -qw io "$mine/cgroup.subtree_control" 2>/dev/null; then echo "io controller: in use by the user manager"
  elif grep -qw io "$mine/cgroup.controllers" 2>/dev/null; then echo "io controller: delegated, NOT yet used by the running user manager (IOWeight waits for the next boot)"
  else echo "io controller: NOT delegated to the user manager (IOWeight does nothing; see systemd/system/user@.service.d/20-delegate-io.conf)"; fi
  if grep -q 'enable=1' "$CGROOT/io.cost.qos" 2>/dev/null; then echo "io.cost: on ($(grep -c 'enable=1' "$CGROOT/io.cost.qos") device(s))"; else echo "io.cost: off (no weight is in force on this host; see scripts/host/io-shield)"; fi
  for s in "${SESSIONS[@]}"; do
    if excluded "$s"; then echo "session $s: excluded (not a lane)"; continue; fi
    n=0; in=0
    while read -r p; do [ -n "$p" ] || continue; c=$(cg "$p") || continue; [ -n "$c" ] || continue; n=$((n + 1)); case "$c" in */"$SLICE.slice"/*) in=$((in + 1)) ;; esac
    done < <(tree $(tmux list-panes -s -t "=$s" -F '#{pane_pid}' 2>/dev/null))
    echo "session $s: $in of $n processes in $SLICE.slice"
  done
  exit 0
fi

# ── attach ───────────────────────────────────────────────────────────────────────────────────────────────
rc=0; moved=0
# the lead first, and before anything that can fail: its mark does not depend on busctl or on any lane
for s in "${LEAD[@]}"; do
  while read -r d; do
    [ -n "$d" ] || continue
    marked "$d" && continue
    if python3 -I -c 'import os, sys; os.setxattr(sys.argv[1], "user.oomd_avoid", b"1")' "$d" 2>/dev/null; then echo "lead $s: marked $(basename "$d") for oomd to avoid"
    else echo "lane-slice: could not mark the lead's scope $(basename "$d")" >&2; rc=1; fi
  done < <(lead_dirs "$s")
done
command -v busctl >/dev/null 2>&1 && command -v systemd-run >/dev/null 2>&1 || { echo "lane-slice: busctl and systemd-run are needed" >&2; exit 1; }
declare -A LIVE=()
for s in "${SESSIONS[@]}"; do
  excluded "$s" && continue
  unit=$(unit_of "$s"); LIVE[$unit]=1
  pend=()
  while read -r p; do
    [ -n "$p" ] || continue
    c=$(cg "$p") || continue
    [ -n "$c" ] || continue                              # gone already
    case "$c" in */"$SLICE.slice"/*|*/dreamteam-*.scope*) continue ;; esac
    pend+=("$p")
  done < <(tree $(tmux list-panes -s -t "=$s" -F '#{pane_pid}' 2>/dev/null) | sort -n)
  [ "${#pend[@]}" -gt 0 ] || continue
  if ! uc is-active --quiet "$unit" 2>/dev/null; then
    # Delegate=yes: the manager refuses to move processes into a scope that is not delegated (scope-attach.sh)
    systemd-run --user --quiet --scope --unit="${unit%.scope}" --slice="$SLICE.slice" -p Delegate=yes sleep infinity > /dev/null 2>&1 &
    disown 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do uc is-active --quiet "$unit" 2>/dev/null && break; sleep 0.2; done
  fi
  if busctl call --user org.freedesktop.systemd1 /org/freedesktop/systemd1 org.freedesktop.systemd1.Manager \
       AttachProcessesToUnit "ssau" "$unit" "/" "${#pend[@]}" "${pend[@]}" > /dev/null 2>&1; then
    moved=$((moved + ${#pend[@]})); echo "session $s: ${#pend[@]} process(es) → $unit"
  else
    echo "lane-slice: could not move session $s into $unit" >&2; rc=1
  fi
done
# a lane scope whose session is gone and that holds only its anchor
while read -r u; do
  [ -n "$u" ] || continue
  [ -n "${LIVE[$u]:-}" ] && continue
  [ "$(uc show "$u" -p TasksCurrent --value 2>/dev/null)" = 1 ] || continue
  uc stop "$u" 2>/dev/null && echo "stopped $u (its session is gone)"
done < <(uc list-units 'lane-*.scope' --no-legend --plain 2>/dev/null | awk '{print $1}')
exit "$rc"
