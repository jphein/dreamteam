#!/usr/bin/env bash
# dreamteam — lane-slice: lane sessions run under one systemd slice, each in its own scope with its own budget.
#
# WHY (Flow row 7e039111). Lanes share a host with the lead's session and with the person typing. "nice 15,
# idle class" is a request each lane has to remember and that stops at the first socket; a slice is a property of
# where the process lives.
#
# WHAT IS COVERED, exactly:
#   • Every tmux session that is not in `.lanes.exclude` or `.lanes.lead`: its panes and all their descendants
#     are moved into `lane-<session>-<hash>.scope` (the hash is of the raw session name), a scope of that lane alone, inside `lanes.slice`. Whatever a lane
#     starts afterwards (a test suite, a gate it runs as a child) is born there.
#       - lanes.slice carries the AGGREGATE: CPUWeight, IOWeight, MemoryHigh, MemorySwapMax for all lanes together.
#       - each lane scope carries its OWN budget (`.lanes.perLane`: memoryHigh, memorySwapMax), so one lane's
#         runaway is throttled before it spends the aggregate.
#   • User units named in `.lanes.units` (gates and batch timers that are units of their own, not a lane's
#     child): a `Slice=lanes.slice` drop-in, effective at that unit's next start.
# WHAT IS NOT, and what is done about it:
#   • A new session is outside the slice until the first attach: the SessionStart hook runs one at once
#     (`attach --hook`), and the 2-minute timer is the safety net.
#   • An agent fleet in a `dreamteam-<project>.scope` (scope-attach.sh's memory-capped scope) is NOT moved: that
#     scope is the fleet's own accounting unit. When it holds a lane's processes it gets the slice's CPUWeight
#     and IOWeight set on it at runtime, so it competes at the lanes' share; its memory stays under its own cap,
#     not under the lanes' MemoryHigh. `status` counts those processes.
#   • A gate unit not listed in `.lanes.units` runs wherever its unit file says. There is no way to recognise
#     "a gate" from here; the list is the mechanism.
#   IOWeight is real only where io.cost is on for the device and the io controller is delegated to the user
#   manager. Both are root's to set and NEITHER is part of this tool or of this change (the root side is a
#   separate piece of work). `status` says which is missing. CPUWeight and the memory limits need neither: they
#   are what this tool delivers by itself.
#
# THE LEAD is never a lane. A session in `.lanes.lead` or `.lanes.exclude` is skipped, and if any of its
# processes are found inside lanes.slice (it was a lane once, or was attached by mistake) they are MOVED OUT,
# into `out-<session>.scope` in app.slice, on every attach. The lead's own protection is not this tool's.
# Nothing here marks or protects anything, and nothing here runs as root.
#
#   lane-slice.sh install     write the slice unit and the Slice= drop-ins from config; REMOVE drop-ins of ours
#                             for units no longer listed; reload the user manager
#   lane-slice.sh attach      place every lane session; move excluded sessions out; set each lane's budget
#   lane-slice.sh attach --hook   the same, silent, always exit 0 (SessionStart)
#   lane-slice.sh status      the slice's settings, each session's place, what IOWeight still waits for
#   lane-slice.sh uninstall   THE ROLLBACK, of what this tool did and nothing else: move the processes of each
#                             lane scope IT CREATED out of the slice (into an out-* scope) and stop that scope;
#                             reset the weights on each fleet scope IT WEIGHTED; remove the unit and drop-ins
#                             it wrote; disable the attach timer. A lane-*.scope or dreamteam-*.scope it has
#                             no record of is left exactly as it is. Works without a readable config.
#
# CONFIG (config.json `.lanes`, per-host overlay config.<host>.json; this repo is public, so session names live
# in the overlay): enabled (false) · exclude (REQUIRED when enabled, may be []) · lead ([]) ·
# cpuWeight 50 · ioWeight 25 · memoryHigh "" · memorySwapMax "" (the aggregate; empty = not set) ·
# perLane {memoryHigh "", memorySwapMax ""} · units [].
#
# Nothing here signals or restarts a session.
# Exit: 0 done (also: not enabled) · 1 something could not be done · 2 refused (config) · 22 bad argument.
set -uo pipefail
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CFG="${DREAMTEAM_CONFIG:-$ROOT/config.json}"
UDIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
PROC="${DREAMTEAM_PROC:-/proc}"
CGROOT="${DREAMTEAM_CGROUP_ROOT:-/sys/fs/cgroup}"
MARK="# written by dreamteam lane-slice.sh; edit config.json .lanes and run install again"
SLICE=lanes

USAGE="usage: lane-slice.sh install|attach [--hook]|status|uninstall"
HOOK=0
case "$#:${1:-}:${2:-}" in
  1:install:|1:attach:|1:status:|1:uninstall:) ;;
  2:attach:--hook) HOOK=1 ;;
  *) echo "$USAGE" >&2; exit 22 ;;
esac
MODE=$1
# The hook form time-boxes ITSELF (hooks.json keeps the plain `bash <script>` form every hook uses): the whole run
# once more under `timeout`, SIGKILL one second after an ignored SIGTERM, and this outer call always exits 0. A
# session start is never held or failed by this.
if [ "$HOOK" -eq 1 ] && [ -z "${LANE_SLICE_HOOK_INNER:-}" ]; then
  LANE_SLICE_HOOK_INNER=1 timeout --kill-after=1 "${LANE_SLICE_HOOK_SECS:-6}" bash "${BASH_SOURCE[0]}" attach --hook > /dev/null 2>&1
  exit 0
fi
if [ "$HOOK" -eq 1 ]; then exec >/dev/null 2>&1; trap 'exit 0' EXIT; fi
# ONE LOCK over discovery AND mutation (xreview #288 r1): install, attach (the timer's, the SessionStart hook's, a
# person's) and uninstall each read the sessions and cgroups and then move processes and set properties. Two of
# them at once could act on each other's half-done state. Every mutating verb runs once more under `flock -o`
# (the lock is held by flock itself, so nothing this script starts inherits it) and waits its turn; `status`
# changes nothing and takes no lock. Exit 75 when the lock stays held for the whole wait: nothing was done.
LOCK="${LANE_SLICE_LOCK:-${XDG_RUNTIME_DIR:-/tmp}/dreamteam-lane-slice.lock}"
if [ "$MODE" != status ] && [ -z "${LANE_SLICE_LOCKED:-}" ]; then
  w="${LANE_SLICE_LOCK_WAIT:-30}"; [[ "$w" =~ ^[0-9]{1,3}$ ]] || w=30
  command -v flock >/dev/null 2>&1 || { echo "lane-slice: flock is needed" >&2; exit 1; }
  LANE_SLICE_LOCKED=1 flock -o -E 75 -w "$w" "$LOCK" bash "${BASH_SOURCE[0]}" "$@"; lrc=$?
  [ "$lrc" -ne 75 ] || echo "lane-slice: another lane-slice run holds $LOCK (waited $w s): nothing done" >&2
  exit "$lrc"
fi
command -v jq >/dev/null 2>&1 || { echo "lane-slice: jq is needed" >&2; exit 1; }
uc() { systemctl --user "$@"; }
ours() { [ -f "$1" ] && [ ! -L "$1" ] && head -n 1 "$1" 2>/dev/null | grep -qxF "$MARK"; }
cg() { local l; l=$(tail -n 1 "$PROC/$1/cgroup" 2>/dev/null) && printf '%s' "${l#*::}"; }
safe() { printf '%s' "$1" | tr -c 'A-Za-z0-9_-' '_'; }
# unit_for <lane|out> <raw session name> → <prefix>-<safe name>-<8 hex of sha256(RAW name)>.scope. safe() folds
# every other character to "_", so "a.b" and "a_b" would share a unit; the hash of the raw name keeps them apart.
unit_for() { printf '%s-%s-%s.scope' "$1" "$(safe "$2" | cut -c1-80)" "$(printf '%s' "$2" | sha256sum | cut -c1-8)"; }
OURSCOPE='^(lane|out)-[A-Za-z0-9_-]{1,90}\.scope$'
LANERE='^lane-[A-Za-z0-9_-]{1,90}\.scope$'
FLEETRE='^dreamteam-[A-Za-z0-9_.-]{1,80}\.scope$'
MYUID="${LANE_SLICE_UID:-$(id -u)}"; [[ "$MYUID" =~ ^[0-9]{1,9}$ ]] || MYUID=$(id -u)       # LANE_SLICE_UID: the fixture tree's uid (tests)
MINE="/user.slice/user-$MYUID.slice/user@$MYUID.service/"
# OWNERSHIP IS A RECORD, NEVER A NAME (xreview #288 r2). A unit called lane-x.scope or dreamteam-y.scope is not
# ours because of what it is called. What this tool did is written down when it does it, as the InvocationID of
# that START of the unit (systemd gives every start a new one):
#   $STATE/scope.<unit>    a lane-* or out-* scope this tool CREATED
#   $STATE/weight.<unit>   a fleet scope this tool set the lanes' weights on
# and read back before anything is done to the unit again. No record, or a record of an earlier start: not ours,
# nothing is moved into it, set on it, reset on it or stopped. The directory is in the runtime dir: it is gone at
# reboot, as are the scopes and the runtime properties it speaks of.
STATE="${LANE_SLICE_STATE:-${XDG_RUNTIME_DIR:-$HOME/.local/state}/dreamteam-lane-slice}"
state_ok() { mkdir -p -m 700 "$STATE" 2>/dev/null; [ -d "$STATE" ] && [ ! -L "$STATE" ] && [ -O "$STATE" ]; }
inv() { local i; i=$(uc show "$1" -p InvocationID --value 2>/dev/null) && [[ "$i" =~ ^[0-9a-f]{32}$ ]] && printf '%s' "$i"; }
rec_put() { state_ok && [[ "$3" =~ ^[0-9a-f]{32}$ ]] && printf '%s\n' "$3" > "$STATE/$1.$2.tmp.$$" && mv -f "$STATE/$1.$2.tmp.$$" "$STATE/$1.$2"; }   # rec_put <kind> <unit> <invocation id>
rec_write() { local i; i=$(inv "$2") && rec_put "$1" "$2" "$i"; }
rec_is() { local f="$STATE/$1.$2" i; state_ok && [ -f "$f" ] && [ ! -L "$f" ] && i=$(inv "$2") && [ "$(head -n 1 "$f" 2>/dev/null)" = "$i" ]; }
rec_drop() { rm -f -- "$STATE/$1.$2"; }
in_mine() { local c; c=$(uc show "$1" -p ControlGroup --value 2>/dev/null); case "$c" in "$MINE"?*) return 0 ;; esac; return 1; }
# move <unit.scope> <slice or ""> <pid>...: make the scope if it is not there (delegated: the manager refuses to
# move processes into a scope that is not), then move the processes with AttachProcessesToUnit.
# A unit of that name that is ALREADY RUNNING is used only when it is ours by record; otherwise it is refused,
# never reused. A new one is started with a random token in its Description, and is recorded only when the unit
# that came up carries that token: a unit of the same name started by someone else in the same moment does not.
move() {
  local unit=$1 slice=$2 tok both d id; shift 2
  [ "$#" -gt 0 ] || return 0
  [[ "$unit" =~ $OURSCOPE ]] || { echo "lane-slice: '$unit' is not a unit name this tool makes: refused" >&2; return 1; }
  if uc is-active --quiet "$unit" 2>/dev/null; then
    rec_is scope "$unit" || { echo "lane-slice: $unit is running and was NOT created by this tool (no record of this start of it): refused, never reused" >&2; return 1; }
  else
    tok="dreamteam lane-slice $(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
    systemd-run --user --quiet --scope --unit="${unit%.scope}" ${slice:+--slice="$slice"} -p Delegate=yes --description="$tok" sleep infinity > /dev/null 2>&1 &
    disown 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do uc is-active --quiet "$unit" 2>/dev/null && break; sleep 0.2; done
    # ONE call for both properties (lead ruling on #288): the token and the id that gets recorded are of the same
    # unit at the same moment. Read apart, a unit replaced between the two reads would be recorded as ours.
    both=$(uc show "$unit" -p Description -p InvocationID 2>/dev/null)
    d=$(sed -n 's/^Description=//p' <<< "$both" | head -n 1); id=$(sed -n 's/^InvocationID=//p' <<< "$both" | head -n 1)
    [ -n "$d" ] && [ "$d" = "$tok" ] || { echo "lane-slice: $unit did not come up as the scope this run started (another unit of that name, or none): refused" >&2; return 1; }
    rec_put scope "$unit" "$id" || { echo "lane-slice: could not record $unit as ours; nothing moved into it" >&2; return 1; }
    # and the unit about to be acted on is still that start
    rec_is scope "$unit" || { echo "lane-slice: $unit was replaced after this run started it (another start of that name now): refused, nothing moved into it" >&2; return 1; }
  fi
  busctl call --user org.freedesktop.systemd1 /org/freedesktop/systemd1 org.freedesktop.systemd1.Manager \
    AttachProcessesToUnit "ssau" "$unit" "/" "$#" "$@" > /dev/null 2>&1
}
lane_units() { uc list-units 'lane-*.scope' --no-legend --plain 2>/dev/null | awk '{print $1}'; }
unit_pids() { local c; c=$(uc show "$1" -p ControlGroup --value 2>/dev/null); [ -n "$c" ] && cat "$CGROOT$c/cgroup.procs" 2>/dev/null; }

# ── uninstall: the rollback. Before the config is read, so a broken config cannot keep the slice in place. ────
if [ "$MODE" = uninstall ]; then
  rc=0
  uc disable --now dreamteam-lane-slice.timer > /dev/null 2>&1 && echo "disabled dreamteam-lane-slice.timer" || echo "note: dreamteam-lane-slice.timer was not enabled here"
  if command -v busctl >/dev/null 2>&1 && command -v systemd-run >/dev/null 2>&1; then
    while read -r u; do
      [ -n "$u" ] || continue
      [[ "$u" =~ $LANERE ]] || { echo "note: '$u' is not a lane unit name: left alone"; continue; }
      rec_is scope "$u" || { echo "note: $u was not created by this tool (no record of this start of it): left alone, nothing moved, not stopped"; continue; }
      s=${u#lane-}; s=${s%.scope}
      mapfile -t pids < <(unit_pids "$u" | while read -r p; do [ "$(cat "$PROC/$p/comm" 2>/dev/null)" = sleep ] && [ "$(tr '\0' ' ' < "$PROC/$p/cmdline" 2>/dev/null)" = "sleep infinity " ] || echo "$p"; done)
      if [ "${#pids[@]}" -gt 0 ]; then
        if move "out-$s.scope" "" "${pids[@]}"; then echo "moved ${#pids[@]} process(es) of $u out of the slice (out-$s.scope)"; else echo "lane-slice: could not move $u's processes out" >&2; rc=1; continue; fi
      fi
      uc stop "$u" 2>/dev/null && echo "stopped $u" && rec_drop scope "$u"
    done < <(lane_units)
  fi
  # the fleet scopes: ONLY those this tool weighted, each by its record. Nothing is listed from the manager: a
  # dreamteam-*.scope we never weighted (the lead's own fleet, somebody else's) is not looked at, let alone set.
  if state_ok; then
    for f in "$STATE"/weight.*; do
      [ -e "$f" ] || [ -L "$f" ] || continue            # (whether the record is believed is rec_is's question, below)
      u=${f##*/weight.}
      case "$u" in *.tmp.*) continue ;; esac
      [[ "$u" =~ $FLEETRE ]] || { echo "note: a weight record named '$u' is not a plain fleet-scope name: nothing set"; continue; }
      if ! rec_is weight "$u"; then echo "note: $u is not the scope this tool weighted any more (gone, or started again since): nothing set, the record dropped"; rec_drop weight "$u"; continue; fi
      in_mine "$u" || { echo "note: $u is not inside this user's manager: nothing set"; continue; }
      if uc set-property --runtime "$u" CPUWeight= IOWeight= 2>/dev/null; then echo "weights reset on $u"; rec_drop weight "$u"; else echo "lane-slice: could not reset the weights on $u" >&2; rc=1; fi
    done
  fi
  for f in "$UDIR/$SLICE.slice" "$UDIR"/*.d/20-lanes-slice.conf; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    if ours "$f"; then rm -f -- "$f" && echo "removed $f" || rc=1; rmdir --ignore-fail-on-non-empty "$(dirname "$f")" 2>/dev/null || true
    else echo "lane-slice: $f is not ours; left alone" >&2; rc=1; fi
  done
  uc daemon-reload || rc=1
  exit "$rc"
fi

MERGED="$(python3 -I "$ROOT/scripts/lib/config_merge.py" "$CFG" 2>/dev/null)" || { echo "lane-slice: the config or this host's overlay is not valid; nothing done" >&2; exit 2; }
get() { printf '%s' "$MERGED" | jq -r "$1" 2>/dev/null; }
if [ "$(get 'if .lanes.enabled == true then "true" else "false" end')" != true ]; then
  [ "$MODE" = status ] && echo "lanes: not enabled on this host (config .lanes.enabled)"
  exit 0
fi
[ "$(get '.lanes | has("exclude")')" = true ] && [ "$(get '.lanes.exclude | type')" = array ] \
  || { echo "lane-slice: .lanes.exclude is required when enabled (a list, may be empty): name the sessions that are not lanes" >&2; exit 2; }
[ "$(get '.lanes.lead // [] | type')" = array ] || { echo "lane-slice: .lanes.lead must be a list of tmux session names" >&2; exit 2; }
mapfile -t EXCLUDE < <(get '(.lanes.exclude + (.lanes.lead // [])) | .[] | strings')
CPUW=$(get '.lanes.cpuWeight // 50'); IOW=$(get '.lanes.ioWeight // 25')
MHIGH=$(get '.lanes.memoryHigh // ""'); MSWAP=$(get '.lanes.memorySwapMax // ""')
PLHIGH=$(get '.lanes.perLane.memoryHigh // ""'); PLSWAP=$(get '.lanes.perLane.memorySwapMax // ""')
mapfile -t UNITS < <(get '.lanes.units // [] | .[] | strings')
weight() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 10000 ]; }
size() { [[ "$1" =~ ^([0-9]{1,6}[KMGT]?|[0-9]{1,3}%|infinity)$ ]]; }
weight "$CPUW" && weight "$IOW" || { echo "lane-slice: cpuWeight and ioWeight must be 1-10000" >&2; exit 2; }
for v in "$MHIGH" "$MSWAP" "$PLHIGH" "$PLSWAP"; do [ -z "$v" ] || size "$v" || { echo "lane-slice: a memory setting must look like 12G, 800M, 40% or infinity (got '$v')" >&2; exit 2; }; done
for u in "${UNITS[@]}"; do [[ "$u" =~ ^[A-Za-z0-9][A-Za-z0-9@_.:-]{0,120}\.(service|scope)$ ]] || { echo "lane-slice: '$u' in .lanes.units is not a plain unit name" >&2; exit 2; }; done
excluded() { local e; for e in "${EXCLUDE[@]}"; do [ "$e" = "$1" ] && return 0; done; return 1; }

put() {   # put <path> <content>: write a file of ours; refuse to replace one that is not
  if [ -e "$1" ] || [ -L "$1" ]; then ours "$1" || { echo "lane-slice: $1 exists and is not ours; refusing" >&2; return 1; }; fi
  mkdir -p "$(dirname "$1")" && printf '%s\n' "$2" > "$1.tmp.$$" && mv -f "$1.tmp.$$" "$1"
}

if [ "$MODE" = install ]; then
  rc=0
  body="$MARK
[Unit]
Description=dreamteam lanes: every lane session on this host (scripts/lane-slice.sh)

[Slice]
CPUWeight=$CPUW
IOWeight=$IOW"
  [ -n "$MHIGH" ] && body="$body
MemoryHigh=$MHIGH"
  [ -n "$MSWAP" ] && body="$body
MemorySwapMax=$MSWAP"
  put "$UDIR/$SLICE.slice" "$body" && echo "wrote $UDIR/$SLICE.slice" || rc=1
  for u in "${UNITS[@]}"; do
    sec=Service; [ "${u##*.}" = scope ] && sec=Scope
    put "$UDIR/$u.d/20-lanes-slice.conf" "$MARK
[$sec]
Slice=$SLICE.slice" && echo "wrote $UDIR/$u.d/20-lanes-slice.conf (effective at the unit's next start)" || rc=1
  done
  # reconcile: a drop-in of ours for a unit that is no longer listed is removed
  for f in "$UDIR"/*.d/20-lanes-slice.conf; do
    [ -e "$f" ] || continue
    u=$(basename "$(dirname "$f")"); u=${u%.d}; keep=0
    for w in "${UNITS[@]}"; do [ "$w" = "$u" ] && keep=1; done
    [ "$keep" -eq 1 ] && continue
    if ours "$f"; then rm -f -- "$f" && echo "removed $f ($u is no longer in .lanes.units)"; rmdir --ignore-fail-on-non-empty "$(dirname "$f")" 2>/dev/null || true
    else echo "lane-slice: $f is not ours; left alone" >&2; rc=1; fi
  done
  uc daemon-reload || { echo "lane-slice: daemon-reload failed" >&2; rc=1; }
  exit "$rc"
fi

# ── attach and status both need the sessions ─────────────────────────────────────────────────────────────
command -v tmux >/dev/null 2>&1 || { echo "lane-slice: no tmux here; nothing to place"; exit 0; }
mapfile -t SESSIONS < <(tmux list-sessions -F '#{session_name}' 2>/dev/null)
declare -A KIDS=()
while read -r p pp; do [ -n "${p:-}" ] && KIDS[$pp]="${KIDS[$pp]:-} $p"; done < <(ps -eo pid=,ppid= 2>/dev/null)
tree() {   # tree <pid>...: the pids and all their descendants, sorted
  local q=("$@") out=() p c
  while [ "${#q[@]}" -gt 0 ]; do
    p=${q[0]}; q=("${q[@]:1}"); out+=("$p")
    for c in ${KIDS[$p]:-}; do q+=("$c"); done
  done
  printf '%s\n' "${out[@]}" | sort -n
}
session_pids() { tree $(tmux list-panes -s -t "=$1" -F '#{pane_pid}' 2>/dev/null); }

if [ "$MODE" = status ]; then
  echo "slice $SLICE.slice: CPUWeight=$(uc show "$SLICE.slice" -p CPUWeight --value 2>/dev/null) IOWeight=$(uc show "$SLICE.slice" -p IOWeight --value 2>/dev/null) MemoryHigh=$(uc show "$SLICE.slice" -p MemoryHigh --value 2>/dev/null); per lane: MemoryHigh=${PLHIGH:-not set} MemorySwapMax=${PLSWAP:-not set}"
  mine="$CGROOT/user.slice/user-$(id -u).slice/user@$(id -u).service"
  if grep -qw io "$mine/cgroup.controllers" 2>/dev/null && grep -qw io "$mine/cgroup.subtree_control" 2>/dev/null; then echo "io controller: in use by the user manager"
  elif grep -qw io "$mine/cgroup.controllers" 2>/dev/null; then echo "io controller: delegated, NOT yet used by the running user manager (IOWeight waits for the next boot)"
  else echo "io controller: NOT delegated to the user manager (IOWeight does nothing here; delegating it is root's, not this tool's)"; fi
  if grep -q 'enable=1' "$CGROOT/io.cost.qos" 2>/dev/null; then echo "io.cost: on ($(grep -c 'enable=1' "$CGROOT/io.cost.qos") device(s))"; else echo "io.cost: off (no I/O weight is in force on this host; turning io.cost on is root's, not this tool's)"; fi
  for s in "${SESSIONS[@]}"; do
    n=0; in=0; fleet=0
    while read -r p; do [ -n "$p" ] || continue; c=$(cg "$p") || continue; [ -n "$c" ] || continue; n=$((n + 1))
      case "$c" in */"$SLICE.slice"/*) in=$((in + 1)) ;; */dreamteam-*.scope*) fleet=$((fleet + 1)) ;; esac
    done < <(session_pids "$s")
    if excluded "$s"; then
      if [ "$in" -gt 0 ]; then echo "session $s: NOT a lane, but $in of $n processes are in $SLICE.slice (the next attach moves them out)"; else echo "session $s: not a lane, outside the slice ($n processes)"; fi
    else
      f=""; [ "$fleet" -gt 0 ] && f=", $fleet in a fleet scope (weights only)"
      echo "session $s: $in of $n processes in $SLICE.slice$f"
    fi
  done
  exit 0
fi

# ── attach ───────────────────────────────────────────────────────────────────────────────────────────────
command -v busctl >/dev/null 2>&1 && command -v systemd-run >/dev/null 2>&1 || { echo "lane-slice: busctl and systemd-run are needed" >&2; exit 1; }
rc=0
declare -A LIVE=() FLEET=() LEADFLEET=()
# fleet_unit <cgroup path> → the dreamteam-*.scope name in it, ONLY when the path is inside this user's own
# manager; nothing otherwise. The NAME comes from a cgroup path, so it is validated against the fleet-scope shape
# at the one place it is handed to systemctl (the weights loop below), never trusted before.
fleet_unit() {
  local c=$1 f
  case "$c" in "$MINE"*) ;; *) return 1 ;; esac
  f=${c##*/dreamteam-}; printf '%s' "dreamteam-${f%%/*}"
}
for s in "${SESSIONS[@]}"; do
  if excluded "$s"; then
    # never a lane: anything of it found inside the slice is moved OUT
    out=()
    while read -r p; do [ -n "$p" ] || continue; c=$(cg "$p") || continue
      case "$c" in
        */"$SLICE.slice"/*) out+=("$p") ;;
        */dreamteam-*.scope*) fu=$(fleet_unit "$c") && LEADFLEET[$fu]=1 ;;      # a fleet scope the lead (or an excluded session) lives in
      esac
    done < <(session_pids "$s")
    if [ "${#out[@]}" -gt 0 ]; then
      ou=$(unit_for out "$s")
      if move "$ou" "" "${out[@]}"; then echo "session $s is not a lane: ${#out[@]} process(es) moved OUT of $SLICE.slice ($ou)"
      else echo "lane-slice: session $s is not a lane but its processes could not be moved out of $SLICE.slice" >&2; rc=1; fi
    fi
    continue
  fi
  unit=$(unit_for lane "$s"); LIVE[$unit]=1
  pend=()
  while read -r p; do
    [ -n "$p" ] || continue
    c=$(cg "$p") || continue
    [ -n "$c" ] || continue                              # gone already
    case "$c" in
      /system.slice/*|/system.slice) echo "note: pid $p of session $s is under system.slice ($c): never moved, never weighted"; continue ;;
      */lead-*.scope|*/lead-*.scope/*) echo "note: pid $p of session $s is in a lead scope ($c): never moved out of it"; continue ;;
      */"$SLICE.slice"/*) continue ;;
      */dreamteam-*.scope*)
        if fu=$(fleet_unit "$c"); then FLEET[$fu]=1; else echo "note: pid $p of session $s is in '$c': not a fleet scope of this user by its path or name, left alone"; fi
        continue ;;
    esac
    pend+=("$p")
  done < <(session_pids "$s")
  if [ "${#pend[@]}" -gt 0 ]; then
    if move "$unit" "$SLICE.slice" "${pend[@]}"; then echo "session $s: ${#pend[@]} process(es) → $unit"
    else echo "lane-slice: could not move session $s into $unit" >&2; rc=1; continue; fi
  fi
  # the lane's own budget, set on its scope every time (a changed config reaches a running lane)
  # (only on a scope that is ours by record: a running unit of that name that we did not create gets nothing)
  if { [ -n "$PLHIGH" ] || [ -n "$PLSWAP" ]; } && uc is-active --quiet "$unit" 2>/dev/null && rec_is scope "$unit"; then
    uc set-property --runtime "$unit" ${PLHIGH:+MemoryHigh=$PLHIGH} ${PLSWAP:+MemorySwapMax=$PLSWAP} 2>/dev/null || { echo "lane-slice: could not set the budget on $unit" >&2; rc=1; }
  fi
done
# a fleet scope that holds lane processes is not moved; it gets the lanes' weights
for u in "${!FLEET[@]}"; do
  [[ "$u" =~ $FLEETRE ]] || { echo "note: '$u' (from a cgroup path) is not a plain fleet-scope name: nothing is set on it"; continue; }
  if [ -n "${LEADFLEET[$u]:-}" ]; then
    echo "fleet scope $u also holds the lead's (or an excluded session's) processes: NOT given the lanes' weights"
    # weights WE set on it earlier, before the lead was in it, are taken back now; one we never weighted is not touched
    if rec_is weight "$u"; then uc set-property --runtime "$u" CPUWeight= IOWeight= 2>/dev/null && echo "fleet scope $u: the weights this tool had set are taken back" && rec_drop weight "$u" || rc=1; fi
    continue
  fi
  # The record is PER SCOPE and follows each successful set-property (lead ruling on #288). A set-property that
  # fails changes no record: a scope we weighted in an earlier run keeps its record (the rollback can still take
  # those weights back), and a scope we never managed to weight has none (it is not ours, the rollback leaves it).
  # A weighting that succeeded but could not be recorded is taken back at once, unless an earlier record covers it.
  had=0; rec_is weight "$u" && had=1
  if uc set-property --runtime "$u" "CPUWeight=$CPUW" "IOWeight=$IOW" 2>/dev/null; then
    if rec_write weight "$u"; then echo "fleet scope $u: CPUWeight=$CPUW IOWeight=$IOW (its memory stays under its own cap)"
    else [ "$had" -eq 1 ] || uc set-property --runtime "$u" CPUWeight= IOWeight= 2>/dev/null; echo "lane-slice: could not record $u as weighted; its weights were taken back" >&2; rc=1; fi
  else
    if [ "$had" -eq 1 ]; then echo "lane-slice: could not set weights on $u; the record of the earlier weighting is kept" >&2; else echo "lane-slice: could not set weights on $u; it is not recorded as weighted" >&2; fi
    rc=1
  fi
done
# a lane scope whose session is gone and that holds only its anchor
while read -r u; do
  [ -n "$u" ] || continue
  [ -n "${LIVE[$u]:-}" ] && continue
  [[ "$u" =~ $LANERE ]] && rec_is scope "$u" || continue          # a lane-*.scope this tool did not create is not ours to stop
  [ "$(uc show "$u" -p TasksCurrent --value 2>/dev/null)" = 1 ] || continue
  uc stop "$u" 2>/dev/null && echo "stopped $u (its session is gone)" && rec_drop scope "$u"
done < <(lane_units)
exit "$rc"
