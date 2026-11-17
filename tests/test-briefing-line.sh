#!/usr/bin/env bash
# dreamteam tests — the morning briefing's CHECK line (scripts/morning-briefing.sh; docs/CHECKS.md dreamteam-briefing).
# Real script, temp HOME/state/checks, stub gh (no PRs) and notify-send (no toast), --quiet (no voice).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT INT TERM
# The script runs from a PRIVATE fixture root (its own scripts/ copy): if a mutant lost the DREAMTEAM_STATE override,
# its fallback ($ROOT/state) would be this fixture, never the checkout's real state/.
FX="$TMP/fixture-root"; mkdir -p "$FX/scripts/lib"
cp "$ROOT/scripts/morning-briefing.sh" "$ROOT/scripts/overnight-guarded.sh" "$FX/scripts/"; cp "$ROOT/scripts/lib/check-line.sh" "$FX/scripts/lib/"
MB="$FX/scripts/morning-briefing.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
mkdir -p "$TMP/bin"
printf '%s\n' '#!/bin/bash' 'echo "[]"' > "$TMP/bin/gh"
printf '%s\n' '#!/bin/bash' 'exit 0' > "$TMP/bin/notify-send"
printf '%s\n' '#!/bin/bash' 'echo "$*" >> "$SYSCTL_LOG"' '[ "${FAKE_TIMER_ENABLED:-0}" = 1 ]' > "$TMP/bin/systemctl"; chmod +x "$TMP/bin/systemctl"
# journalctl stub: the oomd journal is a fixture (FAKE_OOM=1 → one kill line), never the host's real journal
printf '%s\n' '#!/bin/bash' '[ "${FAKE_OOM:-0}" = fail ] && { echo "Failed to open journal" >&2; exit 1; }' '[ "${FAKE_OOM:-0}" = hint ] && { echo "Hint: You are currently not seeing messages from other users and the system." >&2; exit 0; }' '[ "${FAKE_OOM:-0}" = 1 ] && echo "Nov 17 03:12:00 familiar systemd-oomd[811]: Killed /user.slice/user-1000.slice/x.scope due to memory pressure for /user.slice being 91% > 80%"' 'exit 0' > "$TMP/bin/journalctl"; chmod +x "$TMP/bin/journalctl"
chmod +x "$TMP/bin/gh" "$TMP/bin/notify-send"
DATE=$(date +%F)
brief() {  # brief <case> [args…]  → state in $TMP/<case>/state, line(s) in $TMP/<case>/checks
  local c="$TMP/$1"; shift; mkdir -p "$c/state" "$c/home" "$c/checks"
  HOME="$c/home" PATH="$TMP/bin:$PATH" DREAMTEAM_STATE="$c/state" DREAMTEAM_CHECKS_DIR="$c/checks" \
    DREAMTEAM_CHECK_HOST="${HOSTNAME_FOR_TEST:-familiar}" DREAMTEAM_RECONCILE_NIGHTLY="${RECON:-0}" SYSCTL_LOG="$TMP/sysctl.log" CLAUDE_PLUGIN_ROOT="$FX" \
    bash "$MB" --quiet --repo "$c" "$@" > "$c/out" 2>&1; echo $? > "$c/rc"
}
line() { cat "$TMP/$1/checks/${2:-dreamteam-briefing}.line" 2>/dev/null; }
guard() {  # guard <case> <decision> <reason>  → a fresh guard record
  mkdir -p "$TMP/$1/state"
  jq -n --arg at "$(date -Iseconds)" --arg d "$2" --arg r "$3" '{at:$at, decision:$d, reason:$r, issues:0, repos:[]}' > "$TMP/$1/state/overnight-guard.json"
}
SHAPE='^CHECK dreamteam-briefing(-katana)? (ok|warn|fail) · [^·]+ · next 07:03, owner Sen$'
running_line() { mkdir -p "$TMP/$1/checks"; echo "CHECK nightly-guarded ok · night x: running until 06:30 · next 23:30, owner Sen" > "$TMP/$1/checks/nightly-guarded.line"; }

bash -n "$MB" && ok "bash -n morning-briefing.sh" || bad "bash -n"

# 1. a run with a fresh nightly record → ok, names the file and the nightly decision
guard nw no-work "nothing"; brief nw
L=$(line nw)
[[ "$L" =~ $SHAPE ]] && ok "run: line shape" || bad "run shape: '$L'"
[[ "$L" == "CHECK dreamteam-briefing ok · briefing-$DATE.md written "*", nightly sweep: nothing queued (no open dream issues) · "* ]] \
  && ok "run + nightly record → ok, names file and decision" || bad "run ok: '$L'"
[ "$(cat "$TMP/nw/rc")" = 0 ] && ok "run: exit 0" || bad "run rc $(cat "$TMP/nw/rc")"

# 2. a run with NO nightly record → warn (the briefing exists, the nightly said nothing)
brief norec
[[ "$(line norec)" == "CHECK dreamteam-briefing warn · "*"nightly sweep: no record in the last 12 h · "* ]] && ok "no nightly record → warn" || bad "norec: '$(line norec)'"

# 3. --check-only: no briefing today → fail; nothing is written into state
brief none --check-only
[[ "$(line none)" == "CHECK dreamteam-briefing fail · no briefing-$DATE.md"* ]] && [ -z "$(ls -A "$TMP/none/state")" ] \
  && ok "--check-only, no briefing → fail, state untouched" || bad "none: '$(line none)' state=$(ls -A "$TMP/none/state")"

# 3b. --check-only with NO state dir at all: fail, and the state dir is not created
c="$TMP/nostate"; mkdir -p "$c/home" "$c/checks"
HOME="$c/home" PATH="$TMP/bin:$PATH" DREAMTEAM_STATE="$c/state-absent" DREAMTEAM_CHECKS_DIR="$c/checks" DREAMTEAM_CHECK_HOST=familiar \
  DREAMTEAM_RECONCILE_NIGHTLY=0 SYSCTL_LOG="$TMP/sysctl.log" CLAUDE_PLUGIN_ROOT="$FX" bash "$MB" --quiet --repo "$c" --check-only > "$c/out" 2>&1
[[ "$(cat "$c/checks/dreamteam-briefing.line" 2>/dev/null)" == "CHECK dreamteam-briefing fail · no briefing-$DATE.md"* ]] && [ ! -e "$c/state-absent" ] \
  && ok "--check-only with no state dir → fail, and the state dir is NOT created" || bad "nostate: '$(cat "$c/checks/dreamteam-briefing.line" 2>/dev/null)' created=$([ -e "$c/state-absent" ] && echo yes)"

# 4. --check-only on an existing briefing: ok, and the file is byte-identical and keeps its mtime
mkdir -p "$TMP/keep/state"
printf '%s\n' "# Dreamteam briefing — $DATE" "" "- **PRs**: 1 merged" "- **Nightly sweep**: started nightly-x: 2 dream issue(s)" > "$TMP/keep/state/briefing-$DATE.md"
touch -d '07:03' "$TMP/keep/state/briefing-$DATE.md"; before=$(stat -c '%Y %s' "$TMP/keep/state/briefing-$DATE.md"); h1=$(sha256sum < "$TMP/keep/state/briefing-$DATE.md")
brief keep --check-only
[[ "$(line keep)" == "CHECK dreamteam-briefing ok · briefing-$DATE.md written 07:03, 3 lines, nightly sweep: started nightly-x: 2 dream issue(s) · "* ]] \
  && [ "$before" = "$(stat -c '%Y %s' "$TMP/keep/state/briefing-$DATE.md")" ] && [ "$h1" = "$(sha256sum < "$TMP/keep/state/briefing-$DATE.md")" ] \
  && ok "--check-only on today's briefing → ok, file unchanged (bytes and mtime)" || bad "keep: '$(line keep)'"

# 5. an OOM kill in the briefing → warn
mkdir -p "$TMP/oom/state"
printf '%s\n' "# b" "- **Memory**: ⚠ OOM kill overnight: x" "- **Nightly sweep**: nothing queued" > "$TMP/oom/state/briefing-$DATE.md"
brief oom --check-only
[[ "$(line oom)" == "CHECK dreamteam-briefing warn · "*"OOM kill overnight · "* ]] && ok "OOM kill → warn" || bad "oom: '$(line oom)'"

# 5b. a REAL run on a quiet night (no events, no handoff, a fresh no-work record) with an OOM kill → the briefing says so
#     and the line warns (the quiet-night exit used to skip the OOM measurement)
guard oomrun no-work "nothing"; FAKE_OOM=1 brief oomrun
grep -q "OOM kill overnight" "$TMP/oomrun/state/briefing-$DATE.md" && [[ "$(line oomrun)" == "CHECK dreamteam-briefing warn · "*"OOM kill overnight · "* ]] \
  && ok "real quiet-night run with an OOM kill → briefing names it, line warns" || bad "oomrun: '$(line oomrun)' brief=$(cat "$TMP/oomrun/state/briefing-$DATE.md" 2>/dev/null | tr '\n' '|')"
guard oomnone no-work "nothing"; FAKE_OOM=0 brief oomnone
[[ "$(line oomnone)" == "CHECK dreamteam-briefing ok · "* ]] && grep -q "no OOM kills overnight" "$TMP/oomnone/state/briefing-$DATE.md" \
  && ok "real quiet-night run, no OOM → ok, briefing says no OOM" || bad "oomnone: '$(line oomnone)'"

guard oomfail no-work "nothing"; FAKE_OOM=fail brief oomfail
grep -q "OOM unmeasured" "$TMP/oomfail/state/briefing-$DATE.md" && [[ "$(line oomfail)" == "CHECK dreamteam-briefing warn · "*"OOM unmeasured (journal unreadable) · "* ]] \
  && ok "journal unreadable → 'OOM unmeasured' in the briefing and a warn line (never 'no OOM')" || bad "oomfail: '$(line oomfail)'"

# an ACTIVE (non-quiet) night whose journal is unreadable: the spoken sentence must not claim "no memory incidents"
mkdir -p "$TMP/actfail/state"; touch "$TMP/actfail/state/HANDOFF-auto.md"; guard actfail no-work "nothing"
printf '%s\n' '#!/bin/bash' 'printf "%s\n" "$1" >> "$SPEECH_LOG"' > "$FX/scripts/speak.sh"
( c="$TMP/actfail"; HOME="$c/home" PATH="$TMP/bin:$PATH" DREAMTEAM_STATE="$c/state" DREAMTEAM_CHECKS_DIR="$c/checks" DREAMTEAM_CHECK_HOST=familiar \
  DREAMTEAM_RECONCILE_NIGHTLY=0 SYSCTL_LOG="$TMP/sysctl.log" SPEECH_LOG="$c/speech" FAKE_OOM=fail CLAUDE_PLUGIN_ROOT="$FX" \
  bash "$MB" --repo "$c" > "$c/out" 2>&1 )
rm -f "$FX/scripts/speak.sh"
grep -q "could not be measured" "$TMP/actfail/speech" 2>/dev/null && ! grep -q "No memory incidents" "$TMP/actfail/speech" \
  && [[ "$(line actfail)" == "CHECK dreamteam-briefing warn · "*"OOM unmeasured"* ]] \
  && ok "active night, unreadable journal → spoken 'could not be measured', line warns" || bad "actfail speech: '$(cat "$TMP/actfail/speech" 2>/dev/null)' line='$(line actfail)'"

guard oomhint no-work "nothing"; FAKE_OOM=hint brief oomhint
[[ "$(line oomhint)" == "CHECK dreamteam-briefing warn · "*"OOM unmeasured"* ]] && grep -q "no system journal access" "$TMP/oomhint/state/briefing-$DATE.md" \
  && ok "journal exits 0 but hides system messages (access hint) → unmeasured, warn" || bad "oomhint: '$(line oomhint)'"
# reconciliation with the guard record MISSING on the timer's host: a stale ok becomes fail ("no readable guard record")
mkdir -p "$TMP/norec2/state"; running_line norec2
[[ "$(cat "$TMP/norec2/checks/nightly-guarded.line" 2>/dev/null)" == "CHECK nightly-guarded ok · night x: running until 06:30"* ]] \
  && ok "norec2 seed: a stale 'running' ok line is in place before the run" || bad "norec2 seed missing"
RECON=1 brief norec2
[[ "$(cat "$TMP/norec2/checks/nightly-guarded.line")" == "CHECK nightly-guarded fail · no readable guard record"* ]] \
  && ok "record missing on the timer's host → the stale nightly ok becomes fail" || bad "norec2: '$(cat "$TMP/norec2/checks/nightly-guarded.line")'"

# 6. on katana the name carries the host
HOSTNAME_FOR_TEST=katana brief kat --check-only
[ -f "$TMP/kat/checks/dreamteam-briefing-katana.line" ] && [ ! -e "$TMP/kat/checks/dreamteam-briefing.line" ] \
  && ok "katana writes dreamteam-briefing-katana.line" || bad "katana name: $(ls "$TMP/kat/checks")"

# 7. a run whose briefing is NOT written (state dir unwritable after start) → fail, never ok
mkdir -p "$TMP/ro/state"; chmod 500 "$TMP/ro/state"
brief ro
[[ "$(line ro)" == "CHECK dreamteam-briefing fail · "* ]] && ok "briefing not written → fail" || bad "ro: '$(line ro)'"
chmod 700 "$TMP/ro/state"

# 8. a VALID briefing already on disk, then this run's write fails → fail (not ok from the old file)
mkdir -p "$TMP/wfail/state"
printf '%s\n' "# b" "- **Nightly sweep**: nothing queued" > "$TMP/wfail/state/briefing-$DATE.md"
guard wfail no-work "x"; chmod 500 "$TMP/wfail/state"
brief wfail
chmod 700 "$TMP/wfail/state"
[[ "$(line wfail)" == "CHECK dreamteam-briefing fail · this run did not write briefing-$DATE.md"* ]] && ok "write fails with a valid old briefing on disk → fail" || bad "wfail: '$(line wfail)'"

# 9. post-cap reconciliation: a dead night (started, cap passed, repos unfinished) turns the nightly line to fail
#    from the briefing alone (no --check-line by hand); with reconciliation off it is left alone
deadnight() {  # deadnight <case>
  mkdir -p "$TMP/$1/state/overnight-runs/nightly-t"
  jq -n --arg at "$(date -Iseconds -d '-8 hours')" '{at:$at, decision:"started", reason:"guard passed", issues:5, repos:["a/x","a/y"], run_id:"nightly-t", runs:[{repo:"a/x",status:"started"}]}' > "$TMP/$1/state/overnight-guard.json"
  jq -n --argjson dl "$(( $(date +%s) - 1800 ))" '{deadline_epoch:$dl, repos:[{repo:"a/x"},{repo:"a/y"}]}' > "$TMP/$1/state/overnight-runs/nightly-t/plan.json"
}
deadnight recon; RECON=1 brief recon
[[ "$(cat "$TMP/recon/checks/nightly-guarded.line" 2>/dev/null)" == "CHECK nightly-guarded fail · "*"never finished (runner gone)"* ]] \
  && ok "briefing reconciles a dead night: nightly-guarded → fail" || bad "recon: '$(cat "$TMP/recon/checks/nightly-guarded.line" 2>/dev/null)'"
deadnight norecon; RECON=0 brief norecon
[ ! -e "$TMP/norecon/checks/nightly-guarded.line" ] && ok "reconciliation off → the nightly line is not touched" || bad "norecon wrote a nightly line"

# 10. the PRODUCTION path (auto): it asks systemd whether THIS host runs the guarded timer
deadnight autoon; running_line autoon; : > "$TMP/sysctl.log"
RECON=auto FAKE_TIMER_ENABLED=1 brief autoon
[[ "$(cat "$TMP/autoon/checks/nightly-guarded.line")" == "CHECK nightly-guarded fail · "*"never finished (runner gone)"* ]] \
  && grep -qx -- "--user is-enabled --quiet dreamteam-nightly-guarded.timer" "$TMP/sysctl.log" \
  && ok "auto + guarded timer enabled here → asks for dreamteam-nightly-guarded.timer, the 'running' ok becomes fail" || bad "autoon: '$(cat "$TMP/autoon/checks/nightly-guarded.line")' log=$(cat "$TMP/sysctl.log")"
deadnight autooff; running_line autooff; h0=$(sha256sum < "$TMP/autooff/checks/nightly-guarded.line")
RECON=auto FAKE_TIMER_ENABLED=0 brief autooff
[ "$h0" = "$(sha256sum < "$TMP/autooff/checks/nightly-guarded.line")" ] && ok "auto + timer not enabled here (katana) → the nightly line is byte-identical" || bad "autooff changed the line"
# 11. --check-only changes nothing but its own line, even with a dead night and reconciliation forced on
deadnight conly; mkdir -p "$TMP/conly/state"; printf '%s\n' "# b" "- **Nightly sweep**: x" > "$TMP/conly/state/briefing-$DATE.md"
RECON=1 brief conly --check-only
[ ! -e "$TMP/conly/checks/nightly-guarded.line" ] && [ ! -e "$TMP/conly/state/.nightly-line.lock" ] && [ -f "$TMP/conly/checks/dreamteam-briefing.line" ] \
  && ok "--check-only: no reconciliation, no lock file, only its own line" || bad "conly touched: $(ls -A "$TMP/conly/checks" "$TMP/conly/state")"

echo "─────────────────────────────────────────"
echo "SUMMARY: $PASS passed, $FAIL failed, $((PASS+FAIL)) total"
[ "$FAIL" -eq 0 ]
