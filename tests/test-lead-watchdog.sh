#!/bin/bash
# tests/test-lead-watchdog.sh — the lead watchdog against a throwaway tmux server (-L lwtest), a stub `claude`, a
# stub mailer and a stub scope runner; one group at the end uses the REAL user systemd where there is one.
#
# What the watchdog must hold (xreview #281 round 1, Sen 2026-11-23):
#   • lead.session is the ONLY identity: text in a pane is never an id;
#   • the place is restored as recorded: session, window index, working directory;
#   • never two leads: a lead alive anywhere on the host stops everything, also one that starts BETWEEN the
#     check and the act (a hook the script calls before each gate starts one at a chosen moment);
#   • one lock for the whole look-and-act, not leaked to a tmux server it starts;
#   • the lead runs in its own named scope, with the oomd preference set when the scope is created.
# Round 2 (xreview 7125502061), final:
#   • "alive" is ANY process on the host whose command line contains the recorded id (any name, any argument form);
#   • not one key reaches the pane before the last gate; after it one tmux call types the launcher's line, and the
#     launcher (scripts/lead-launch.sh) makes the launch-time check under the launch lock: a lead that starts
#     AFTER the watchdog's last gate is refused there (the `send` hook starts one at exactly that moment);
#   • no program the watchdog or the launcher starts holds a lock descriptor (PATH wrappers look at their own fds);
#   • the record is complete and unambiguous or nothing is looked at, made or typed: no default pane, no default
#     directory; a running child in a pane does not make a missing record ok;
#   • no scope runner, a runner that fails, a directory that cannot be entered, no env file: no lead is started.
# The only session id used here is a made-up one: the suite also runs on the host where the real lead lives.
set -u
umask 077                        # as the real writer: a record others can write is no record
here=$(cd "$(dirname "$0")/.." && pwd)
WD="$here/scripts/lead-watchdog.sh"
LA="$here/scripts/lead-launch.sh"
T=$(mktemp -d "${TMPDIR:-/var/tmp}/lead-wd.XXXXXX")
reap_stubs() {  # end stub claudes of THIS run only: a pidfd first, then the command line must name our temp dir
    python3 -I - "$T" <<'PY' 2>/dev/null || true
import os, signal, sys
for n in os.listdir("/proc"):
    if not n.isdigit(): continue
    try: fd = os.pidfd_open(int(n))
    except OSError: continue
    try:
        if (sys.argv[1] + "/bin/claude").encode() in open(f"/proc/{n}/cmdline", "rb").read():
            signal.pidfd_send_signal(fd, signal.SIGKILL)
    except OSError: pass
    finally: os.close(fd)
PY
}
trap 'tmux -L lwtest kill-server 2>/dev/null; reap_stubs; rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/state" "$T/checks" "$T/leadcwd"
cat > "$T/bin/claude" <<'EOF'
#!/bin/bash
echo "stub claude $*" > "${STUB_OUT:?}/claude.args"; pwd -P > "$STUB_OUT/claude.cwd"; ls -l /proc/$$/fd > "$STUB_OUT/claude.fds" 2>&1; echo $$ > "$STUB_OUT/claude.pid"; echo x >> "$STUB_OUT/claude.starts"
got=""; IFS= read -r -t 3 got; printf '%s' "$got" > "$STUB_OUT/claude.stdin"; sleep 40
EOF
chmod +x "$T/bin/claude"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/true-mail"; chmod +x "$T/bin/true-mail"
# the stub scope runner: logs its whole call, drops the runner's own options, runs the command in place
cat > "$T/bin/scope-run" <<EOF
#!/bin/bash
echo "\$*" >> "$T/scope-run.log"
while [ "\$#" -gt 0 ]; do case "\$1" in -p) shift 2 ;; -*) shift ;; *) break ;; esac; done
exec "\$@"
EOF
chmod +x "$T/bin/scope-run"
printf '#!/bin/bash\necho "$*" >> "%s/scope-fail.log"\nexit 1\n' "$T" > "$T/bin/scope-fail"; chmod +x "$T/bin/scope-fail"
# a process that is NOT named claude and carries the id in another argument form (reaped with the stubs: its path
# starts like theirs)
printf '#!/bin/bash\nsleep 40\n' > "$T/bin/claude-wrap"; chmod +x "$T/bin/claude-wrap"
: > "$T/env.sh"
CWDR=$(cd "$T/leadcwd" && pwd -P)
export STUB_OUT="$T" PATH="$T/bin:$PATH" LEAD_WATCHDOG_STATE="$T/state" CHECKS_DIR="$T/checks" \
       LEAD_LAUNCH_ENV="$T/env.sh" LEAD_WATCHDOG_MAIL="$T/bin/true-mail" LEAD_TMUX_SOCKET=lwtest LEAD_WATCHDOG_WAIT=5 \
       LEAD_SHELL_CMD="bash --norc --noprofile" LEAD_SCOPE_RUN="$T/bin/scope-run" LEAD_SCOPE_UNIT="lead-lwtest$$"
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "ok   $1"; }
bad() { fail=$((fail+1)); echo "FAIL $1"; }
run() { bash "$WD" 2>&1; }
SID=11111111-2222-3333-4444-555555555555
OTHER=99999999-8888-7777-6666-555555555555
reset() { reap_stubs; rm -f "$T/claude.args" "$T/claude.cwd" "$T/claude.pid" "$T/state/lead-watchdog.relaunches" "$T/state/lead-watchdog.off" "$T/scope-run.log" "$T/scope-fail.log" "$T/hook.count" "$T/hook.at" "$T/hook.send" "$T/hook.send-pane" "$T/hook.respawn" "$T/elsewhere.out" "$T/claude.fds" "$T/claude.stdin" "$T/claude.starts" "$T/state/lead-launch.last"; }
sess_file() { printf 'session=%s\npane=%s\ncwd=%s\n' "$SID" "${1:-lwtest:0.0}" "${2:-$CWDR}" > "$T/state/lead.session"; }
fresh() {  # a server with one session `lwtest`, one pane at a bash prompt; $1 = text to print first
    tmux -L lwtest kill-server 2>/dev/null; reset
    # kill-server returns before the old server has gone; start, then WAIT until the session is there
    for _try in 1 2 3 4 5 6 7 8 9 10; do
        tmux -L lwtest new-session -d -s lwtest -x 160 -y 30 "bash --norc --noprofile" 2>/dev/null
        sleep 0.4
        tmux -L lwtest has-session -t =lwtest 2>/dev/null && break
    done
    sleep 0.3
    [ -n "${1:-}" ] && { tmux -L lwtest send-keys -t lwtest:0.0 -l "printf '%s\n' \"$1\""; tmux -L lwtest send-keys -t lwtest:0.0 Enter; sleep 0.5; }
    rm -f "$T/state/lead.session"
}
resumed() { grep -q -- "--resume $SID --permission-mode bypassPermissions" "$T/claude.args" 2>/dev/null; }
typed_nothing() { [ ! -e "$T/claude.args" ] && [ ! -s "$T/state/lead-watchdog.relaunches" ]; }
panes() { tmux -L lwtest list-panes -a -F '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null | sort | tr '\n' ' '; }

# ── alive, and the plain relaunch ───────────────────────────────────────────────────────────────────────────
fresh ""; sess_file; tmux -L lwtest send-keys -t lwtest:0.0 -l "sleep 15"; tmux -L lwtest send-keys -t lwtest:0.0 Enter; sleep 0.5
out=$(run); grep -q '^CHECK lead-liveness ok · pane lwtest:0.0 has a running child' <<<"$out" && typed_nothing && ok "alive → ok, nothing typed" || bad "alive: $out"

fresh ""; sess_file; sleep 1.2
out=$(run)
grep -q "^CHECK lead-liveness ok · relaunched 11111111 in lwtest:0.0 .* from lead.session in scope lead-lwtest$$.scope" <<<"$out" && resumed && ok "dead at a prompt + lead.session → the lead is resumed from the file" || bad "relaunch: $out $(cat "$T/claude.args" 2>&1)"
[ "$(wc -l < "$T/state/lead-watchdog.relaunches")" = 1 ] && ok "relaunch recorded once" || bad "relaunch history"
grep -qx -- "--unit=lead-lwtest$$ -p ManagedOOMPreference=avoid claude --resume $SID --permission-mode bypassPermissions" "$T/scope-run.log" 2>/dev/null \
  && ok "the lead is launched through the scope runner: its own named unit, the oomd preference set at creation" || bad "scope call: $(cat "$T/scope-run.log" 2>&1)"
[ "$(cat "$T/claude.cwd" 2>/dev/null)" = "$CWDR" ] && ok "…in the RECORDED working directory, though the pane stood elsewhere" || bad "cwd: $(cat "$T/claude.cwd" 2>&1) want $CWDR"

# ── identity: lead.session only ─────────────────────────────────────────────────────────────────────────────
fresh "Resume this session with: claude --resume $OTHER"; sleep 1.0; out=$(run)
grep -q '^CHECK lead-liveness fail · no valid lead.session (there is no lead.session)' <<<"$out" && typed_nothing \
  && ok "a resume hint in the pane's history and NO lead.session: fail, nothing typed (history is never an id)" || bad "history used as id: $out"
fresh "Resume this session with: claude --resume $OTHER"; sess_file; sleep 1.0; out=$(run)
resumed && ! grep -q "$OTHER" "$T/claude.args" && ok "history names another id, the file names the lead: the FILE's id is resumed" || bad "history overrode the file: $(cat "$T/claude.args" 2>&1)"
fresh ""; printf 'session=not-a-uuid; rm -rf x\npane=lwtest:0.0\n' > "$T/state/lead.session"; out=$(run)
grep -q 'no valid lead.session' <<<"$out" && typed_nothing && ok "a bad id in lead.session → fail, nothing typed" || bad "bad id: $out"
fresh ""; sess_file; mv "$T/state/lead.session" "$T/real.session"; ln -s "$T/real.session" "$T/state/lead.session"; out=$(run)
grep -q 'no valid lead.session' <<<"$out" && typed_nothing && ok "a symlinked lead.session is not read" || bad "symlinked file: $out"
rm -f "$T/state/lead.session"
fresh ""; printf 'session=%s\npane=lwtest:0.0\ncwd=%s\nlaunch=touch %s/PWNED; claude --resume %s\n' "$SID" "$CWDR" "$T" "$SID" > "$T/state/lead.session"; out=$(run); sleep 0.4
[ ! -e "$T/PWNED" ] && resumed && ok "a tampered launch= line is never typed; the command is built by the watchdog" || bad "tampered launch: $out"
fresh ""; printf 'touch %s/SOURCED\n' "$T" > "$T/evil-env.sh"
printf 'session=%s\npane=lwtest:0.0\ncwd=%s\nlaunch=. %s/evil-env.sh; claude --resume %s --permission-mode bypassPermissions\n' "$SID" "$CWDR" "$T" "$SID" > "$T/state/lead.session"; out=$(run); sleep 0.4
[ ! -e "$T/SOURCED" ] && resumed && ok "a right-shaped launch= naming another env file is not typed either" || bad "evil env: $out"
# the launcher must be there before anything is typed: a copy of the watchdog with no launcher beside it
mkdir -p "$T/nolaunch/lib"; cp "$WD" "$T/nolaunch/"; cp "$here/scripts/lib/lead-record.sh" "$T/nolaunch/lib/"
fresh ""; sess_file; sleep 1.0; out=$(bash "$T/nolaunch/lead-watchdog.sh" 2>&1); sleep 0.4
grep -q "^CHECK lead-liveness fail · the launcher (.*/nolaunch/lead-launch.sh) is missing" <<<"$out" && typed_nothing && ! tmux -L lwtest capture-pane -p -t lwtest:0.0 | grep -q 'lead-launch' \
  && ok "no launcher beside the watchdog: fail, nothing typed (not a command that cannot run)" || bad "missing launcher: $out"
fresh ""; sess_file; out=$(LEAD_LAUNCH_ENV='/x; touch /nope' run)
grep -q 'not in a plain form' <<<"$out" && typed_nothing && ok "a launch-env setting that is not a plain path: nothing typed" || bad "launch env: $out"
fresh ""; printf 'session=%s\npane=lwtest:0.0\ncwd=/x; touch /nope\n' "$SID" > "$T/state/lead.session"; out=$(run); sleep 0.3
grep -q '^CHECK lead-liveness fail · no valid lead.session (its cwd= line is not a plain absolute path)' <<<"$out" && typed_nothing && ok "a cwd line that is not a plain path: fail, nothing typed (NO fallback to home)" || bad "bad cwd: $out $(cat "$T/claude.cwd" 2>&1)"
# the record is COMPLETE and UNAMBIGUOUS or it is no record (xreview r2 finding 5)
badrec() {  # <name> <expected reason, a grep pattern> <record text>
    fresh ""; printf '%b' "$3" > "$T/state/lead.session"; sleep 0.6; out=$(run); sleep 0.3
    grep -q "^CHECK lead-liveness fail · no valid lead.session ($2" <<<"$out" && typed_nothing && [ -z "$(pgrep -P "$(tmux -L lwtest display -p -t lwtest:0.0 '#{pane_pid}')")" ] \
      && ok "record: $1 → fail, nothing typed" || bad "record: $1: $out"
}
badrec "no cwd line (no default directory)" "session, pane and cwd must each be there exactly once" "session=$SID\npane=lwtest:0.0\n"
badrec "no pane line (no default pane)" "session, pane and cwd must each be there exactly once" "session=$SID\ncwd=$CWDR\n"
badrec "a pane line that is not a pane" "its pane= line is not session:window.pane" "session=$SID\npane=lwtest\ncwd=$CWDR\n"
badrec "two session lines, both valid" "session, pane and cwd must each be there exactly once" "session=$SID\nsession=$OTHER\npane=lwtest:0.0\ncwd=$CWDR\n"
badrec "a valid session line, then a corrupt one" "its session= line is not a session id" "session=$SID\npane=lwtest:0.0\ncwd=$CWDR\nsession=zzz\n"
badrec "two cwd lines" "session, pane and cwd must each be there exactly once" "session=$SID\npane=lwtest:0.0\ncwd=$CWDR\ncwd=$T\n"
badrec "two pane lines" "session, pane and cwd must each be there exactly once" "session=$SID\npane=lwtest:0.0\npane=lwtest:0.0\ncwd=$CWDR\n"
badrec "a line of an unknown kind" "it has a line that is none of session, pane, cwd, launch" "session=$SID\npane=lwtest:0.0\ncwd=$CWDR\nextra=1\n"
badrec "a working directory that does not exist" "its working directory does not exist" "session=$SID\npane=lwtest:0.0\ncwd=$T/nowhere\n"
fresh ""; sess_file; chmod 666 "$T/state/lead.session"; sleep 0.6; out=$(run)
grep -q 'no valid lead.session (lead.session can be written by others' <<<"$out" && typed_nothing && ok "record: a file others can write → fail, nothing typed" || bad "writable record: $out"
rm -f "$T/state/lead.session"
# a running child in the default-looking pane does NOT make a missing or corrupt record ok
fresh ""; tmux -L lwtest send-keys -t lwtest:0.0 -l "sleep 15"; tmux -L lwtest send-keys -t lwtest:0.0 Enter; sleep 0.5; out=$(run)
grep -q '^CHECK lead-liveness fail · no valid lead.session (there is no lead.session)' <<<"$out" && ! grep -q ' ok · ' <<<"$out" && ok "something runs in a pane but there is NO record: fail, never ok" || bad "ok without a record: $out"
printf 'session=%s\npane=lwtest:0.0\ncwd=/x; touch /nope\n' "$SID" > "$T/state/lead.session"; out=$(run)
grep -q '^CHECK lead-liveness fail · no valid lead.session' <<<"$out" && ! grep -q ' ok · ' <<<"$out" && ok "something runs in the recorded pane but the record is corrupt: fail, never ok" || bad "ok with a corrupt record: $out"

# ── the prompt: pending text, continuation prompts, dead panes, live panes ──────────────────────────────────
fresh ""; sess_file; tmux -L lwtest send-keys -t lwtest:0.0 -l "touch $T/UNINTENDED #"; sleep 1.2; out=$(run); sleep 0.5
[ ! -e "$T/UNINTENDED" ] && resumed && ok "pending text at the prompt is discarded (Ctrl-U); only the relaunch runs" || bad "pending input ran: $out"
fresh ""; sess_file; tmux -L lwtest send-keys -t lwtest:0.0 -l "; touch $T/UNINTENDED2 #"; tmux -L lwtest send-keys -t lwtest:0.0 C-a; sleep 1.2; out=$(run); sleep 0.5
[ ! -e "$T/UNINTENDED2" ] && resumed && ok "pending text with the cursor at its start is discarded too (Ctrl-E, then Ctrl-U)" || bad "pending suffix ran: $out"
fresh ""; sess_file; tmux -L lwtest send-keys -t lwtest:0.0 -l "if true; then touch $T/PS2RAN"; tmux -L lwtest send-keys -t lwtest:0.0 Enter; sleep 1.2; out=$(run); sleep 0.5
grep -q 'pane respawned' <<<"$out" && [ ! -e "$T/PS2RAN" ] && resumed && ok "a pane at a continuation prompt is respawned and the lead resumed; the unfinished command never runs" || bad "not-a-prompt: $out"
[ "$(cat "$T/claude.cwd" 2>/dev/null)" = "$CWDR" ] && ok "…the respawned pane is in the recorded directory" || bad "respawn cwd: $(cat "$T/claude.cwd" 2>&1)"
fresh ""; sess_file; tmux -L lwtest set-option -t lwtest remain-on-exit on; tmux -L lwtest send-keys -t lwtest:0.0 -l "exit"; tmux -L lwtest send-keys -t lwtest:0.0 Enter; sleep 0.8
[ "$(tmux -L lwtest display -p -t lwtest:0.0 '#{pane_dead}')" = 1 ] && ok "fixture: the pane is dead and kept" || bad "fixture: pane not dead"
out=$(run); grep -q 'from lead.session, pane respawned' <<<"$out" && resumed && ok "a dead pane (remain-on-exit) is respawned and the lead resumed" || bad "dead pane: $out"
fresh ""; sess_file; tmux -L lwtest send-keys -t lwtest:0.0 -l "sleep 20; echo not-a-prompt-line"; tmux -L lwtest send-keys -t lwtest:0.0 Enter; sleep 0.6
pid_before=$(tmux -L lwtest display -p -t lwtest:0.0 '#{pane_pid}'); out=$(run)
grep -q 'has a running child' <<<"$out" && [ "$(tmux -L lwtest display -p -t lwtest:0.0 '#{pane_pid}')" = "$pid_before" ] && typed_nothing && ok "a pane with something running is left alone (no respawn, nothing typed)" || bad "live pane touched: $out"

# ── guards ──────────────────────────────────────────────────────────────────────────────────────────────────
fresh ""; sess_file; touch "$T/state/lead-watchdog.off"; out=$(run)
grep -q '^CHECK lead-liveness warn · watchdog off' <<<"$out" && [ ! -e "$T/claude.args" ] && ok "kill-switch → warn, nothing typed" || bad "kill-switch: $out"
fresh ""; sess_file; now=$(date +%s); printf '%s\n%s\n%s\n' "$((now-100))" "$((now-200))" "$((now-300))" > "$T/state/lead-watchdog.relaunches"; out=$(run)
grep -q '^CHECK lead-liveness fail · .*3 relaunches already' <<<"$out" && [ ! -e "$T/claude.args" ] && ok "loop guard → fail after 3 in an hour" || bad "loop: $out"
fresh ""; sess_file; ( exec 8>"$T/state/lead.lock"; flock 8; sleep 4 ) & holder=$!; sleep 0.4; out=$(run); wait "$holder" 2>/dev/null
grep -q '^CHECK lead-liveness warn · the lead lock is held (a launch of the lead, or another lead-watchdog run): nothing done this tick' <<<"$out" && typed_nothing \
  && ok "THE lead lock is held (another run, or a launch in progress: it is one lock): nothing done this tick" || bad "lock: $out"
grep -q 'exec 9>"\$LOCK"' "$WD" && grep -q '^LOCK="\$STATE/lead.lock"' "$WD" && grep -q 'exec 8>"\$STATE/lead.lock"' "$LA" && ! grep -q 'lead-launch.lock\|lead-watchdog.lock' "$WD" "$LA" \
  && ok "the watchdog and the launcher name the SAME lock file, <state>/lead.lock, and no other" || bad "lock path"

# ── the place is restored as recorded ───────────────────────────────────────────────────────────────────────
tmux -L lwtest kill-server 2>/dev/null; sleep 0.5; reset; sess_file lwtest:3.0
out=$(run)
grep -q '^CHECK lead-liveness ok · relaunched 11111111 in lwtest:3.0 .* from lead.session, session recreated' <<<"$out" && resumed && ok "no tmux server: the session is recreated and the lead resumed in the RECORDED window (lwtest:3.0)" || bad "recreate, no server: $out panes=$(panes)"
[ "$(cat "$T/claude.cwd" 2>/dev/null)" = "$CWDR" ] && ok "…in the recorded working directory" || bad "recreate cwd: $(cat "$T/claude.cwd" 2>&1)"
grep -q -- '--unit=tmux-lwtest.* tmux -L lwtest new-session -d -s lwtest' "$T/scope-run.log" 2>/dev/null && ok "a tmux server the watchdog starts goes through the scope runner (never a child of the unit)" || bad "server scope: $(cat "$T/scope-run.log" 2>&1)"
[ "$(wc -l < "$T/state/lead-watchdog.relaunches")" = 1 ] && ok "a recreation counts as one relaunch" || bad "recreate history"
reset; sess_file lwtest:3.0; out=$(run)
! grep -q 'holds the lock' <<<"$out" && grep -q 'has a running child\|relaunched' <<<"$out" && ok "the lock is not leaked to the tmux server the watchdog started (the next tick runs)" || bad "lock leaked: $out"

tmux -L lwtest kill-server 2>/dev/null; sleep 0.5
for _try in 1 2 3 4 5; do tmux -L lwtest new-session -d -s other "bash --norc --noprofile" 2>/dev/null; sleep 0.4; tmux -L lwtest has-session -t =other 2>/dev/null && break; done
reset; sess_file lwtest:3.0; out=$(run)
grep -q 'relaunched 11111111 in lwtest:3.0 .* session recreated' <<<"$out" && ! grep -q 'new-session' "$T/scope-run.log" && tmux -L lwtest has-session -t =other 2>/dev/null \
  && ok "server alive, session gone: recreated by the running server at the recorded window; the other session untouched" || bad "recreate, server alive: $out $(cat "$T/scope-run.log" 2>&1)"

# windows 0 and 5 exist; the lead is recorded in window 3, which is gone. The lowest free index is 1, so a
# window made "anywhere" would not be 3.
fresh ""; tmux -L lwtest new-window -d -t lwtest:5 "bash --norc --noprofile"; sleep 0.4; sess_file lwtest:3.0
out=$(run)
grep -q 'relaunched 11111111 in lwtest:3.0 .* window 3 recreated' <<<"$out" && resumed && ok "window gone, session alive: the window is made again AT ITS RECORDED INDEX (3, not the lowest free) and the lead resumed there" || bad "window recreate: $out panes=$(panes)"
[ -z "$(pgrep -P "$(tmux -L lwtest display -p -t lwtest:5.0 '#{pane_pid}')")" ] && [ -z "$(pgrep -P "$(tmux -L lwtest display -p -t lwtest:0.0 '#{pane_pid}')")" ] && ok "…the session's other windows were not typed into" || bad "another window was touched"
fresh ""; tmux -L lwtest split-window -d -t lwtest:0 "bash --norc --noprofile"; sleep 0.4; tmux -L lwtest kill-pane -t lwtest:0.1; sleep 0.4; sess_file lwtest:0.1
out=$(run)
grep -q 'relaunched 11111111 in lwtest:0.1 .* pane recreated in window 0' <<<"$out" && resumed && [ -z "$(pgrep -P "$(tmux -L lwtest display -p -t lwtest:0.0 '#{pane_pid}')")" ] \
  && ok "pane gone from a window that still has another pane: a pane is made in that window; the other pane is not typed into" || bad "pane recreate: $out panes=$(panes)"

for why in "no id" "bad id" "kill-switch" "loop guard"; do
  tmux -L lwtest kill-session -t =lwtest 2>/dev/null; tmux -L lwtest has-session -t =other 2>/dev/null || tmux -L lwtest new-session -d -s other "bash --norc --noprofile"; reset; sess_file lwtest:3.0
  case "$why" in
    "no id") rm -f "$T/state/lead.session" ;;
    "bad id") printf 'session=zzz; touch %s/BADID\npane=lwtest:3.0\n' "$T" > "$T/state/lead.session" ;;
    "kill-switch") touch "$T/state/lead-watchdog.off" ;;
    "loop guard") now=$(date +%s); printf '%s\n%s\n%s\n' "$((now-100))" "$((now-200))" "$((now-300))" > "$T/state/lead-watchdog.relaunches" ;;
  esac
  out=$(run)
  ! tmux -L lwtest has-session -t =lwtest 2>/dev/null && [ ! -e "$T/claude.args" ] && [ ! -e "$T/BADID" ] && ! grep -q '· ok ·\| ok · relaunched' <<<"$out" \
    && ok "session gone, $why: nothing is made" || bad "session gone, $why: $out"
done
fresh ""; tmux -L lwtest new-window -d -t lwtest:5 "bash --norc --noprofile"; sleep 0.3; tmux -L lwtest kill-pane -t lwtest:0.0; sleep 0.3
sess_file lwtest:0.0; now=$(date +%s); printf '%s\n%s\n%s\n' "$((now-100))" "$((now-200))" "$((now-300))" > "$T/state/lead-watchdog.relaunches"
nw=$(tmux -L lwtest list-windows -t =lwtest | wc -l); out=$(run)
grep -q '3 relaunches already' <<<"$out" && [ "$(tmux -L lwtest list-windows -t =lwtest | wc -l)" = "$nw" ] && ok "window gone, loop guard: no window made" || bad "loop, window: $out"
rm -f "$T/state/lead.session" "$T/state/lead-watchdog.relaunches"; out=$(run)
grep -q 'fail · no valid lead.session (there is no lead.session)' <<<"$out" && [ "$(tmux -L lwtest list-windows -t =lwtest | wc -l)" = "$nw" ] && ok "window gone, no id: no window made" || bad "no id, window: $out"

# ── NEVER TWO LEADS ─────────────────────────────────────────────────────────────────────────────────────────
elsewhere() { ( cd "$T" && setsid "$T/bin/claude" --resume "${1:-$SID}" > /dev/null 2>&1 < /dev/null & ) 2>/dev/null; for _i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$T/claude.pid" ] && break; sleep 0.2; done; rm -f "$T/claude.args"; }
tmux -L lwtest kill-server 2>/dev/null; sleep 0.4; reset; sess_file lwtest:3.0; elsewhere
out=$(run)
grep -q "^CHECK lead-liveness warn · the lead's id 11111111 is in the command line of $(cat "$T/claude.pid")(claude), outside lwtest:3.0: nothing made, nothing typed" <<<"$out" \
  && ! tmux -L lwtest has-session -t =lwtest 2>/dev/null && typed_nothing && ok "session gone but the lead is ALIVE elsewhere on the host: no session made, nothing typed" || bad "lead elsewhere, session gone: $out"
fresh ""; sess_file; elsewhere; sleep 0.8; out=$(run)
grep -q "the lead's id 11111111 is in the command line of" <<<"$out" && typed_nothing && [ -z "$(pgrep -P "$(tmux -L lwtest display -p -t lwtest:0.0 '#{pane_pid}')")" ] \
  && ok "the lead's pane sits at a prompt but the lead is alive in another place: nothing typed" || bad "lead elsewhere, pane at prompt: $out"
fresh ""; sess_file; elsewhere "$OTHER"; sleep 0.8; out=$(run)
resumed && ok "a claude resuming ANOTHER id is not the lead: the relaunch goes ahead" || bad "other id blocked the relaunch: $out"
# host-wide means ANY process whose command line holds the id: not named claude, the id in another argument form
fresh ""; sess_file; ( cd "$T" && setsid "$T/bin/claude-wrap" "--session=$SID" > /dev/null 2>&1 < /dev/null & ); sleep 0.8; out=$(run)
grep -q "the lead's id 11111111 is in the command line of [0-9]*(claude-wrap), outside lwtest:0.0: nothing made, nothing typed" <<<"$out" && typed_nothing \
  && ok "a process NOT named claude carrying the id as --session=<id>: it is the lead, nothing typed" || bad "another name / argument form: $out"
fresh ""; sess_file; ( cd "$T" && setsid "$T/bin/claude-wrap" "prefix${SID}suffix" > /dev/null 2>&1 < /dev/null & ); sleep 0.8; out=$(run)
grep -q "the lead's id 11111111 is in the command line of" <<<"$out" && typed_nothing && ok "…the id anywhere inside an argument counts too" || bad "id inside an argument: $out"
# host-wide is not uid-wide: needs a second user, so only where sudo works without a password
if sudo -n true 2>/dev/null; then
  fresh ""; sess_file; sudo -n -u nobody setsid bash -c 'sleep 25; :' lw-other "--resume=$SID" > /dev/null 2>&1 < /dev/null &
  sleep 1.2; out=$(run)
  grep -q "the lead's id 11111111 is in the command line of" <<<"$out" && typed_nothing && ok "a process of ANOTHER USER carrying the id counts: nothing typed" || bad "another user's process: $out"
  sudo -n pkill -u nobody -f -- "lw-other --resume=$SID" 2>/dev/null; sleep 0.3
  fresh ""; sess_file; chmod 644 "$T/state/lead.session"; sudo -n chown nobody "$T/state/lead.session"; sleep 0.6; out=$(run)
  grep -q 'no valid lead.session (lead.session is not owned by this user)' <<<"$out" && typed_nothing && ok "record: a file owned by another user → fail, nothing typed" || bad "foreign-owned record: $out"
  rm -f "$T/state/lead.session"
else
  echo "skip the two second-user cases: no passwordless sudo here"
fi
# a lead that starts BETWEEN the first check and the act: the hook runs before every gate and starts one on call N
cat > "$T/bin/hook" <<EOF
#!/bin/bash
start() { ( cd "$T" && setsid "$T/bin/claude" --resume $SID > /dev/null 2>&1 < /dev/null & ); for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$T/claude.pid" ] && break; sleep 0.2; done; rm -f "$T/claude.args"; }
case "\$1" in
  gate) n=\$(( \$(cat "$T/hook.count" 2>/dev/null || echo 0) + 1 )); echo "\$n" > "$T/hook.count"; [ "\$n" = "\$(cat "$T/hook.at" 2>/dev/null)" ] && start ;;
  send) echo sent >> "$T/hook.count"
        [ -e "$T/hook.send" ] && start
        # a LAUNCH typed into the lead's own pane at this very moment (a person, or another tool, using the launcher)
        [ -e "$T/hook.send-pane" ] && { tmux -L lwtest send-keys -t "\$(cat "$T/hook.send-pane")" -l "bash $LA"; tmux -L lwtest send-keys -t "\$(cat "$T/hook.send-pane")" Enter; sleep 1; } ;;
  respawn) echo respawn >> "$T/hook.count"
        # a launch started ELSEWHERE between the gate and respawn-pane: it must wait for the lock
        [ -e "$T/hook.respawn" ] && { ( cd "$T" && setsid bash "$LA" > "$T/elsewhere.out" 2>&1 < /dev/null & ); sleep 1; } ;;
esac
exit 0
EOF
chmod +x "$T/bin/hook"
# …at the LAST gate, with text waiting on the pane's input line: not one key may reach the pane (a Ctrl-U sent
# before the gate would erase the text, so the text still being there is the proof)
fresh ""; sess_file; tmux -L lwtest send-keys -t lwtest:0.0 -l 'PENDINGTEXT $'; echo 2 > "$T/hook.at"; sleep 1.0; out=$(LEAD_WATCHDOG_TEST_HOOK="$T/bin/hook" run)
grep -q "the lead's id 11111111 is in the command line of .* nothing typed (it started while the pane was being prepared)" <<<"$out" && typed_nothing \
  && ! tmux -L lwtest capture-pane -p -t lwtest:0.0 | grep -q 'lead-launch' && ok "RACE: a lead starts after the first check, before the keys: the last gate sees it, nothing is typed" || bad "race before typing: $out"
tmux -L lwtest capture-pane -p -t lwtest:0.0 | grep -q 'PENDINGTEXT' && ! grep -q sent "$T/hook.count" && ok "…and NOT ONE key reached the pane before that gate: the text on its input line is still there" || bad "keys before the last gate: $(tmux -L lwtest capture-pane -p -t lwtest:0.0 | tail -3)"
# AFTER the last gate (the window no repeated check can close): the launcher's own look refuses the second lead
holders() { pgrep -f -- "$SID" | wc -l; }   # pgrep leaves itself out
fresh ""; sess_file; touch "$T/hook.send"; sleep 1.0; out=$(LEAD_WATCHDOG_TEST_HOOK="$T/bin/hook" run); sleep 0.5
grep -q "^CHECK lead-liveness warn · the lead's id 11111111 is in the command line of .*: the launcher refused to start a second lead (a lead is already there" <<<"$out" \
  && [ ! -e "$T/claude.args" ] && [ "$(holders)" = 1 ] && [ -z "$(pgrep -P "$(tmux -L lwtest display -p -t lwtest:0.0 '#{pane_pid}')")" ] \
  && ok "RACE: a lead starts AFTER the last gate, before the keys land: the launcher refuses; exactly ONE lead on the host" || bad "race after the last gate: holders=$(holders) $out"
grep -q sent "$T/hook.count" && tmux -L lwtest capture-pane -p -t lwtest:0.0 | grep -q 'lead-launch: refused: a lead is already there' && ok "…the hook ran between the gate and the keys, and the pane shows the launcher's refusal" || bad "after-gate fixture: $(cat "$T/hook.count" 2>&1)"

# ── THE RULING'S RACE (PR comment 7128795764): a launch appears BETWEEN the gate and the act ─────────────────
# (a) …in the lead's OWN pane, between the last gate and the keys. Someone runs the launcher there. It cannot start
#     a lead while the watchdog holds the lock: it waits. The watchdog's keys then land in a pane where that
#     launcher is waiting; when the lock is free the launcher starts the lead and must have DISCARDED those keys.
#     Exactly one lead, started once, and not one character of the watchdog's line reached it.
reap_stubs; fresh ""; sess_file; echo lwtest:0.0 > "$T/hook.send-pane"; sleep 1.0; out=$(LEAD_WATCHDOG_TEST_HOOK="$T/bin/hook" run); sleep 4.5
[ "$(holders)" = 1 ] && [ "$(wc -l < "$T/claude.starts" 2>/dev/null)" = 1 ] && ok "RACE in the pane, between the gate and the keys: exactly ONE lead, started once" || bad "race in the pane: holders=$(holders) starts=$(cat "$T/claude.starts" 2>/dev/null | wc -l) $out"
[ -e "$T/claude.stdin" ] && [ ! -s "$T/claude.stdin" ] && ok "…and NOTHING was typed into it: the lead read no input (the launcher discarded the watchdog's line)" || bad "typed into the lead: '$(cat "$T/claude.stdin" 2>&1)'"
grep -q "^CHECK lead-liveness ok · relaunched 11111111 in lwtest:0.0" <<<"$out" && ok "…the line reports the one lead in the pane" || bad "race in the pane, line: $out"
! tmux -L lwtest capture-pane -p -t lwtest:0.0 | grep -q 'refused' && ok "…no second launch ran in that pane afterwards (the typed line was not left for a shell either)" || bad "a second launch ran: $(tmux -L lwtest capture-pane -p -t lwtest:0.0 | tail -3)"
# (b) …elsewhere, between the gate and respawn-pane. The pane is at a continuation prompt, so it is respawned. A
#     launch started at that moment waits for the lock; afterwards two launchers want to start the lead, one after
#     the other under the lock: exactly one does.
reap_stubs; fresh ""; sess_file; tmux -L lwtest send-keys -t lwtest:0.0 -l "if true; then echo x"; tmux -L lwtest send-keys -t lwtest:0.0 Enter; sleep 1.0
touch "$T/hook.respawn"; out=$(LEAD_WATCHDOG_TEST_HOOK="$T/bin/hook" run); sleep 3
grep -q respawn "$T/hook.count" && [ "$(holders)" = 1 ] && [ "$(wc -l < "$T/claude.starts" 2>/dev/null)" = 1 ] && ok "RACE before the respawn: a launch started between the gate and respawn-pane waited; exactly ONE lead, started once" || bad "race before respawn: holders=$(holders) starts=$(cat "$T/claude.starts" 2>/dev/null | wc -l) $out"
grep -q 'refused: a lead is already there' "$T/elsewhere.out" 2>/dev/null || tmux -L lwtest capture-pane -p -t lwtest:0.0 | grep -q 'refused: a lead is already there' \
  && ok "…the other launcher was refused by name (a lead is already there)" || bad "no refusal seen: $(cat "$T/elsewhere.out" 2>&1 | head -2)"
reap_stubs
fresh ""; sess_file; tmux -L lwtest send-keys -t lwtest:0.0 -l "if true; then echo x"; tmux -L lwtest send-keys -t lwtest:0.0 Enter; sleep 1.0
pid_before=$(tmux -L lwtest display -p -t lwtest:0.0 '#{pane_pid}'); echo 2 > "$T/hook.at"; out=$(LEAD_WATCHDOG_TEST_HOOK="$T/bin/hook" run)
grep -q 'nothing typed (before the respawn)' <<<"$out" && [ "$(tmux -L lwtest display -p -t lwtest:0.0 '#{pane_pid}')" = "$pid_before" ] && typed_nothing \
  && ok "RACE: a lead starts before the respawn: the pane is NOT respawned" || bad "race before respawn: $out"
tmux -L lwtest kill-server 2>/dev/null; sleep 0.4; reset; sess_file lwtest:3.0; echo 2 > "$T/hook.at"
out=$(LEAD_WATCHDOG_TEST_HOOK="$T/bin/hook" run)
grep -q "the lead's id 11111111 is in the command line of" <<<"$out" && ! tmux -L lwtest has-session -t =lwtest 2>/dev/null && typed_nothing \
  && ok "RACE: a lead starts before the session is recreated: no session is made" || bad "race before recreation: $out"
reap_stubs; fresh ""; sess_file; sleep 1.0; out=$(run)
! grep -q 'holds the lock' <<<"$out" && resumed && ok "a process started while the lock was held does not keep it: the next tick runs (found by this suite)" || bad "lock kept by a child: $out"

# ── the lock's descriptor reaches NO program the watchdog starts (xreview r2 finding 4) ──────────────────────
# Every program it calls is wrapped: the wrapper looks at ITS OWN descriptors (what the real program would have
# inherited), notes its name, and notes a leak when one of them is a lock file.
mkdir -p "$T/fdbin"
for prog in tmux systemctl date awk sleep tee grep mv touch wc seq tail head pgrep stat cat rm; do
  real=$(command -v "$prog") || continue
  printf '#!/bin/bash\necho %s >> "%s/fd.seen"\nfor f in /proc/$$/fd/*; do case "$(readlink "$f" 2>/dev/null)" in *lead.lock) echo "%s $f" >> "%s/fd.leak" ;; esac; done\nexec %s "$@"\n' "$prog" "$T" "$prog" "$T" "$real" > "$T/fdbin/$prog"
  chmod +x "$T/fdbin/$prog"
done
reap_stubs; fresh ""; sess_file; sleep 1.0; rm -f "$T/fd.seen" "$T/fd.leak"; out=$(PATH="$T/fdbin:$PATH" run)
resumed && [ ! -s "$T/fd.leak" ] && ok "a whole relaunch: no program the watchdog started had the lock's descriptor" || bad "lock descriptor leaked to: $(sort -u "$T/fd.leak" 2>/dev/null | head -5 | tr '\n' ' ') $out"
seen=$(sort -u "$T/fd.seen" 2>/dev/null | tr '\n' ' ')
for prog in tmux systemctl date awk sleep tee grep pgrep; do case " $seen " in *" $prog "*) : ;; *) bad "fd fixture: $prog was never called through its wrapper (seen: $seen)" ;; esac; done
ok "fd fixture: the wrappers were really called (tmux systemctl date awk sleep tee grep pgrep among: $seen)"
! grep -q 'lead.lock' "$T/claude.fds" 2>/dev/null && [ -s "$T/claude.fds" ] && ok "the lead itself does not hold the lock (it ends at the launcher's exec)" || bad "the lead holds the lock: $(grep lock "$T/claude.fds" 2>&1)"
flock -n "$T/state/lead.lock" true && ok "…and the lock is free while the lead runs (the watchdog let go of it right after the keys)" || bad "the lead lock is still held while the lead runs"

# ── the launcher alone: every refusal starts nothing ────────────────────────────────────────────────────────
la() { ( cd "$T" && timeout 10 bash "$LA" ) 2>&1; }
reap_stubs; fresh ""; reset; rm -f "$T/state/lead.session"; out=$(la); rc=$?
[ "$rc" = 3 ] && grep -q 'refused: no valid lead.session: there is no lead.session' <<<"$out" && [ ! -e "$T/claude.args" ] && ok "launcher: no record → exit 3, nothing started" || bad "launcher no record: rc=$rc $out"
sess_file; elsewhere; out=$(la); rc=$?
[ "$rc" = 4 ] && grep -q "refused: a lead is already there: the session id is in the command line of $(cat "$T/claude.pid")(claude)" <<<"$out" && [ ! -e "$T/claude.args" ] && [ "$(holders)" = 1 ] && ok "launcher: a lead is alive → exit 4, no second lead" || bad "launcher with a live lead: rc=$rc $out"
reap_stubs; reset; sess_file; ( exec 7>"$T/state/lead.lock"; flock 7; sleep 4 ) & lh=$!; sleep 0.4; out=$(LEAD_LAUNCH_LOCK_WAIT=1 la); rc=$?
[ "$rc" = 75 ] && [ ! -e "$T/claude.args" ] && grep -q 'the lead lock is still held after 1 s' <<<"$out" && ok "launcher: the lead lock stays held past its wait → exit 75, nothing started" || bad "launcher lock: rc=$rc $out"
wait "$lh" 2>/dev/null
# …and while the lock is held it WAITS: it starts nothing before the holder lets go, and starts the lead after
reap_stubs; reset; sess_file; ( exec 7>"$T/state/lead.lock"; flock 7; sleep 3 ) & lh=$!; sleep 0.4
( cd "$T" && LEAD_LAUNCH_LOCK_WAIT=20 setsid bash "$LA" > /dev/null 2>&1 < /dev/null & ); sleep 1.5
[ ! -e "$T/claude.args" ] && ok "launcher: while the lock is held (the watchdog between a gate and its act) it has started NOTHING" || bad "launcher did not wait for the lock"
wait "$lh" 2>/dev/null; for _i in 1 2 3 4 5 6 7 8 9 10 11 12; do [ -s "$T/claude.args" ] && break; sleep 0.3; done
resumed && ok "…and once the lock is free it starts the lead" || bad "launcher after the lock: $(cat "$T/claude.args" 2>&1)"
reap_stubs; reset; sess_file
( exec 7>"$T/state/lead.lock"; flock 7; sleep 3 ) & lh=$!; sleep 0.4; rm -f "$T/fd.seen" "$T/fd.leak"; out=$(LEAD_LAUNCH_LOCK_WAIT=1 PATH="$T/fdbin:$PATH" la); rc=$?; wait "$lh" 2>/dev/null
[ "$rc" = 75 ] && [ ! -s "$T/fd.leak" ] && grep -qx date "$T/fd.seen" && ok "…and nothing that refusal started (its date) had the launch lock's descriptor" || bad "launcher refusal leaked the lock: rc=$rc $(cat "$T/fd.leak" 2>&1) seen=$(sort -u "$T/fd.seen" 2>/dev/null | tr '\n' ' ')"
reset; sess_file; out=$(LEAD_SCOPE_RUN= la); rc=$?
[ "$rc" = 5 ] && grep -q 'no systemd-run here: the lead is never started outside its named scope' <<<"$out" && [ ! -e "$T/claude.args" ] && ok "launcher: no scope runner → exit 5, the lead is NOT started outside a scope" || bad "launcher no runner: rc=$rc $out"
reset; sess_file; out=$(LEAD_SCOPE_RUN="$T/bin/scope-fail" la); rc=$?
[ "$rc" != 0 ] && [ -s "$T/scope-fail.log" ] && [ ! -e "$T/claude.args" ] && [ "$(holders)" = 0 ] && ok "launcher: the scope runner FAILS (scope not created) → no claude ran (exit $rc)" || bad "launcher failing runner: rc=$rc $out"
reset; mkdir -p "$T/locked"; sess_file lwtest:0.0 "$(cd "$T/locked" && pwd -P)"; chmod 000 "$T/locked"; out=$(la); rc=$?; chmod 755 "$T/locked"
[ "$rc" = 6 ] && grep -q 'refused: cannot enter the recorded directory' <<<"$out" && [ ! -e "$T/claude.args" ] && [ ! -e "$T/scope-run.log" ] && ok "launcher: the recorded directory cannot be entered → exit 6, nothing started (no launch from another directory)" || bad "launcher cd: rc=$rc $out"
reset; sess_file; out=$(LEAD_LAUNCH_ENV="$T/no-such-env.sh" la); rc=$?
[ "$rc" = 6 ] && grep -q 'refused: the launch-env file is not readable' <<<"$out" && [ ! -e "$T/claude.args" ] && ok "launcher: no launch-env file → exit 6, nothing started" || bad "launcher env: rc=$rc $out"
reset; sess_file; printf 'export FROM_ENV=1\nfalse\n' > "$T/env-false.sh"; ( cd "$T" && LEAD_LAUNCH_ENV="$T/env-false.sh" setsid bash "$LA" > /dev/null 2>&1 < /dev/null & ); for _i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$T/claude.args" ] && break; sleep 0.2; done
resumed && [ "$(cat "$T/claude.cwd")" = "$CWDR" ] && ok "launcher: a good record → the lead starts in the recorded directory (an env file whose last command is false is still an env file)" || bad "launcher success: $(cat "$T/claude.args" 2>&1)"
out=$(la); rc=$?; [ "$rc" = 4 ] && [ "$(holders)" = 1 ] && ok "launcher: run a second time while that lead lives → refused, still one" || bad "second launch: rc=$rc holders=$(holders)"
reap_stubs

# ── no systemd-run ──────────────────────────────────────────────────────────────────────────────────────────
tmux -L lwtest kill-server 2>/dev/null; sleep 0.4; reset; sess_file lwtest:3.0; out=$(LEAD_SCOPE_RUN= run)
grep -q "is gone from lwtest:3.0 and no systemd-run here: the lead is only ever started inside its named scope" <<<"$out" && ! tmux -L lwtest has-session -t =lwtest 2>/dev/null && typed_nothing && ok "no server and no scope runner: no tmux server is started under the unit" || bad "no runner: $out"
fresh ""; sess_file; sleep 1.0; out=$(LEAD_SCOPE_RUN= run); sleep 0.4
grep -q '^CHECK lead-liveness fail · the lead (11111111) is gone from lwtest:0.0 and no systemd-run here: the lead is only ever started inside its named scope' <<<"$out" && typed_nothing \
  && ! tmux -L lwtest capture-pane -p -t lwtest:0.0 | grep -q 'lead-launch' && ok "a live server and no scope runner: fail, NOTHING typed (the lead is never started outside its scope)" || bad "no runner, live server: $out"
fresh ""; sess_file; out=$(LEAD_SCOPE_RUN='/x; touch /nope' run); grep -q 'the scope runner is not a plain path to a program' <<<"$out" && typed_nothing && ok "a scope runner that is not a plain path: nothing typed" || bad "runner form: $out"

# ── REAL user systemd, where there is one: the cgroup the lead lands in, and survival past the unit's end ───
if systemd-run --user --scope --quiet --collect true 2>/dev/null; then
  U="lead-lwtest$$r"; STUBRUN=$LEAD_SCOPE_RUN; STUBUNIT=$LEAD_SCOPE_UNIT; unset LEAD_SCOPE_RUN; export LEAD_SCOPE_UNIT="$U"
  fresh ""; sess_file; sleep 1.0; out=$(run); sleep 0.5
  cpid=$(cat "$T/claude.pid" 2>/dev/null); cg=$(cut -d: -f3- /proc/"$cpid"/cgroup 2>/dev/null)
  case "$cg" in */"$U.scope") ok "real systemd: the lead's process is in its named scope ($U.scope)" ;; *) bad "real scope: cgroup '$cg' out: $out" ;; esac
  [ "$(systemctl --user show "$U.scope" -p ManagedOOMPreference --value 2>/dev/null)" = avoid ] \
    && [ "$(python3 -I -c 'import os,sys; print(os.getxattr(sys.argv[1],"user.oomd_avoid").decode())' "/sys/fs/cgroup$cg" 2>/dev/null)" = 1 ] \
    && ok "real systemd: the scope carries ManagedOOMPreference=avoid AND the mark oomd reads (set at creation)" || bad "real scope: no avoid mark on $cg"
  # the named scope is ACTIVE (something of the lead's still lives in it) while the pane sits at a prompt with no
  # child and no claude process exists: the scope alone must stop the relaunch
  systemctl --user stop "$U.scope" 2>/dev/null; reap_stubs; fresh ""; sess_file; sleep 1.0
  systemd-run --user --scope --quiet --collect --unit="$U" sleep 30 > /dev/null 2>&1 &
  for _i in 1 2 3 4 5 6 7 8 9 10; do systemctl --user is-active --quiet "$U.scope" && break; sleep 0.2; done
  out=$(run)
  grep -q "the lead's scope $U.scope is active: nothing made, nothing typed" <<<"$out" && typed_nothing && ok "real systemd: while the named scope is active nothing is typed, though the pane is at a prompt and no claude runs" || bad "active scope: $out"
  # the launcher on its own against that live scope: refused, and systemd would refuse a second scope of that name too
  out=$(la); rc=$?
  [ "$rc" = 4 ] && grep -q "refused: a lead is already there: its scope $U.scope is active" <<<"$out" && [ ! -e "$T/claude.args" ] && ok "real systemd: the launcher refuses while the named scope is active (exit 4), no claude ran" || bad "launcher vs live scope: rc=$rc $out"
  ( cd "$T" && systemd-run --user --scope --quiet --collect --unit="$U" "$T/bin/claude" --resume "$OTHER" ) > /dev/null 2>&1; rc=$?
  [ "$rc" != 0 ] && [ ! -e "$T/claude.args" ] && ok "real systemd: a second scope of the lead's name cannot be created while the first lives (systemd-run exits $rc, the command never runs)" || bad "systemd let a second scope of the name start: rc=$rc"
  systemctl --user stop "$U.scope" 2>/dev/null; reap_stubs
  # the watchdog as a oneshot unit with NO tmux server: what it starts must outlive the unit
  tmux -L lwtest kill-server 2>/dev/null; sleep 0.5; reset; sess_file lwtest:3.0
  systemd-run --user --quiet --wait --collect --unit="lwtest-wd-$$" -p Type=oneshot \
    -E STUB_OUT -E PATH -E LEAD_WATCHDOG_STATE -E CHECKS_DIR -E LEAD_LAUNCH_ENV -E LEAD_WATCHDOG_MAIL -E LEAD_TMUX_SOCKET -E LEAD_WATCHDOG_WAIT -E LEAD_SHELL_CMD \
    -E LEAD_SCOPE_UNIT="$U" -E HOME -E TMUX_TMPDIR="${TMUX_TMPDIR:-/tmp}" bash "$WD" > "$T/unit.out" 2>&1
  sleep 1.5
  if tmux -L lwtest has-session -t =lwtest 2>/dev/null && kill -0 "$(cat "$T/claude.pid" 2>/dev/null)" 2>/dev/null && ! systemctl --user is-active --quiet "lwtest-wd-$$.service"; then
    ok "real systemd: the unit has ended; the tmux server it started and the lead in it are still alive"
  else bad "survival past the unit: session=$(tmux -L lwtest has-session -t =lwtest 2>&1) line=$(cat "$T/checks/lead-liveness.line" 2>&1)"; fi
  case "$(cut -d: -f3- /proc/"$(cat "$T/claude.pid" 2>/dev/null)"/cgroup 2>/dev/null)" in */"$U.scope") ok "real systemd: …and that lead is in its named scope, not in the watchdog unit's cgroup" ;; *) bad "lead cgroup after unit run" ;; esac
  systemctl --user stop "$U.scope" 2>/dev/null; tmux -L lwtest kill-server 2>/dev/null
  export LEAD_SCOPE_RUN="$STUBRUN" LEAD_SCOPE_UNIT="$STUBUNIT"
else
  echo "skip real-systemd cases: no user systemd here (systemd-run --user --scope failed)"
fi
grep -q '^Type=oneshot$' "$here/systemd/dreamteam-lead-watchdog.service" && ! grep -qE '^KillMode=' "$here/systemd/dreamteam-lead-watchdog.service" && grep -q '^TimeoutStartSec=90$' "$here/systemd/dreamteam-lead-watchdog.service" \
  && ok "the unit is a plain oneshot with the default KillMode (nothing may be left in its cgroup) and a start timeout" || bad "unit file"
rm -f "$T/state/lead.session"; SID2=$SID

# 11. the writer hook: only the lead's session (tmux session name + cwd = HOME) writes the file
WR="$here/scripts/lead-session-write.sh"
fresh ""; pane_id=$(tmux -L lwtest display -p -t lwtest:0.0 '#{pane_id}')
hook() { ( cd "$1" && printf '{"session_id":"%s"}' "$2" | HOME="$T/home" TMUX_PANE="$pane_id" DREAMTEAM_LEAD_SESSION="$3" bash "$WR" ); }
mkdir -p "$T/home/sub"
hook "$T/home" "$SID2" lwtest; rc=$?
[ "$rc" = 0 ] && grep -qx "session=$SID2" "$T/state/lead.session" && grep -qx "pane=lwtest:0.0" "$T/state/lead.session" && grep -qx "cwd=$(cd "$T/home" && pwd -P)" "$T/state/lead.session" && grep -qx "launch=bash $(cd "$here/scripts" && pwd -P)/lead-launch.sh" "$T/state/lead.session" \
  && [ "$(stat -c %a "$T/state/lead.session")" = 600 ] && ok "the lead's SessionStart writes lead.session (0600: session, pane, cwd, launch)" || bad "writer: rc=$rc $(cat "$T/state/lead.session" 2>&1)"
rm -f "$T/state/lead.session"; hook "$T/home/sub" "$SID2" lwtest; [ ! -e "$T/state/lead.session" ] && ok "a session in another directory writes nothing" || bad "writer wrote from a non-HOME cwd"
hook "$T/home" "$SID2" othersession; [ ! -e "$T/state/lead.session" ] && ok "a session in another tmux session writes nothing" || bad "writer wrote for a non-lead session"
hook "$T/home" "bad id" lwtest; rc=$?; [ "$rc" = 0 ] && [ ! -e "$T/state/lead.session" ] && ok "a bad session id writes nothing and still exits 0" || bad "writer with a bad id"
# round trip: what the writer wrote is what the watchdog relaunches from
hook "$T/home" "$SID2" lwtest; fresh ""; hook "$T/home" "$SID2" lwtest; sleep 1.0; out=$(run)
grep -q '^CHECK lead-liveness ok · relaunched 11111111 in lwtest:0.0 .* from lead.session' <<<"$out" && [ "$(cat "$T/claude.cwd" 2>/dev/null)" = "$(cd "$T/home" && pwd -P)" ] && ok "round trip: the hook's file is enough for the watchdog to relaunch, in the directory the hook recorded" || bad "round trip: $out"

# 12. the unit can never again be stopped by a lost exec bit: ExecStart goes through bash, and git records 100755
grep -q '^ExecStart=/usr/bin/bash %h/Projects/dreamteam/scripts/lead-watchdog.sh$' "$here/systemd/dreamteam-lead-watchdog.service" && ok "the unit starts the script through bash" || bad "unit ExecStart: $(grep ExecStart "$here/systemd/dreamteam-lead-watchdog.service")"
if git -C "$here" rev-parse --git-dir >/dev/null 2>&1; then
  m=$(git -C "$here" ls-files -s -- scripts/lead-watchdog.sh scripts/lead-session-write.sh scripts/lead-launch.sh | awk '{print $1, $4}' | tr '\n' '|')
  [ "$m" = "100755 scripts/lead-launch.sh|100755 scripts/lead-session-write.sh|100755 scripts/lead-watchdog.sh|" ] && ok "exactly these three scripts, each committed executable (100755)" || bad "git modes: $m"
else
  ok "git modes: skipped (not a git checkout)"
fi
# the hook is bounded: through the REGISTERED command line, with stdin held open and with a tmux that never answers
CMD=$(python3 -I -c "import json,sys; h=json.load(open(sys.argv[1])); e=[x for g in h['hooks']['SessionStart'] for x in g['hooks'] if 'lead-session-write.sh' in x['command']]; assert len(e)==1 and 0 < e[0]['timeout'] <= 10; print(e[0]['command'])" "$here/hooks/hooks.json") \
  && ok "the writer is registered once on SessionStart with a timeout in seconds" || bad "hooks.json registration"
case "$CMD" in "bash \"\${CLAUDE_PLUGIN_ROOT}/scripts/lead-session-write.sh\"") ok "the registered command is the plain bash form (the script time-boxes itself)" ;; *) bad "registered command: $CMD" ;; esac
grep -q 'LEAD_SESSION_WRITE_INNER=1 timeout --kill-after=1 5 bash' "$WR" && ok "the script runs itself under timeout with a kill-after, and an outer exit 0" || bad "no self time-box in the writer"
( cd "$T/home" && printf 'not json' | HOME="$T/home" TMUX_PANE="%999" DREAMTEAM_LEAD_SESSION=lwtest bash "$WR" ); [ $? = 0 ] && ok "bad input: exit 0" || bad "writer exit on bad input"
# a real crash of the inner hook (its tmux call kills it) is still exit 0 through the registered command
mkdir -p "$T/killtmux"; printf '#!/bin/sh\nkill -9 $PPID\nsleep 5\n' > "$T/killtmux/tmux"; chmod +x "$T/killtmux/tmux"
( cd "$T/home" && printf '{"session_id":"%s"}' "$SID2" | PATH="$T/killtmux:$PATH" HOME="$T/home" TMUX_PANE="%1" DREAMTEAM_LEAD_SESSION=lwtest CLAUDE_PLUGIN_ROOT="$here" timeout --kill-after=2 15 bash -c "$CMD" ); rc=$?
[ "$rc" = 0 ] && ok "the inner hook killed mid-run: the registered command still returns 0" || bad "inner crash: rc=$rc"
# a tmux that IGNORES SIGTERM cannot hold the hook past its bound (kill-after)
mkdir -p "$T/stubborn"; printf '#!/bin/bash\ntrap "" TERM\nsleep 40 & wait\nsleep 40\n' > "$T/stubborn/tmux"; chmod +x "$T/stubborn/tmux"
t0=$(date +%s); ( cd "$T/home" && printf '{"session_id":"%s"}' "$SID2" | PATH="$T/stubborn:$PATH" HOME="$T/home" TMUX_PANE="%1" DREAMTEAM_LEAD_SESSION=lwtest CLAUDE_PLUGIN_ROOT="$here" timeout --kill-after=2 15 bash -c "$CMD" ); rc=$?; t1=$(date +%s)
[ "$rc" = 0 ] && [ $((t1 - t0)) -le 7 ] && ok "a tmux that ignores SIGTERM: killed, exit 0 inside the harness's 8 s ($((t1 - t0)) s)" || bad "stubborn tmux: rc=$rc after $((t1 - t0)) s"
fresh ""; pane_id=$(tmux -L lwtest display -p -t lwtest:0.0 '#{pane_id}'); rm -f "$T/state/lead.session"
# stdin is a FIFO that a background writer keeps open and never writes to: only the HOOK is timed, not a pipeline
mkfifo "$T/held"; sleep 30 > "$T/held" & holder=$!
t0=$(date +%s); ( cd "$T/home" && HOME="$T/home" TMUX_PANE="$pane_id" DREAMTEAM_LEAD_SESSION=lwtest CLAUDE_PLUGIN_ROOT="$here" timeout --kill-after=2 15 bash -c "$CMD" < "$T/held" ); rc=$?; t1=$(date +%s)
[ "$rc" = 0 ] && [ $((t1 - t0)) -le 8 ] && ok "stdin held open: the registered hook returns 0 within its bound ($((t1 - t0)) s)" || bad "held-open stdin: rc=$rc after $((t1 - t0)) s"
mkdir -p "$T/slowtmux"; printf '#!/bin/sh\nsleep 30\n' > "$T/slowtmux/tmux"; chmod +x "$T/slowtmux/tmux"
t0=$(date +%s); ( cd "$T/home" && printf '{"session_id":"%s"}' "$SID2" | PATH="$T/slowtmux:$PATH" HOME="$T/home" TMUX_PANE="$pane_id" DREAMTEAM_LEAD_SESSION=lwtest CLAUDE_PLUGIN_ROOT="$here" timeout --kill-after=2 15 bash -c "$CMD" ); rc=$?; t1=$(date +%s)
[ "$rc" = 0 ] && [ $((t1 - t0)) -le 8 ] && [ ! -e "$T/state/lead.session" ] && ok "a tmux that never answers: returns 0 within its bound, writes nothing ($((t1 - t0)) s)" || bad "stalled tmux: rc=$rc after $((t1 - t0)) s"
t0=$(date +%s); ( cd "$T/home" && env -u TMUX_PANE HOME="$T/home" bash "$WR" < "$T/held" ); rc=$?; t1=$(date +%s)
[ "$rc" = 0 ] && [ $((t1 - t0)) -le 1 ] && ok "outside tmux the hook returns at once without reading stdin" || bad "non-tmux: rc=$rc after $((t1 - t0)) s"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null

echo "lead-watchdog: $pass ok, $fail failed"; [ "$fail" = 0 ]
