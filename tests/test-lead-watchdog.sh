#!/bin/bash
# tests/test-lead-watchdog.sh — the lead watchdog against a throwaway tmux server (-L), a stub `claude` and a stub mailer.
# 2026-11-22 cases (13-22): session gone → recreated (through a scope when no server runs), pane gone → new window,
# pane dead or not at a prompt → respawned; no id, a bad id, the kill-switch and the loop guard each still stop it.
# Cases: alive → ok, no relaunch · dead with hint → relaunch typed, stub claude started, ok line · dead without hint → fail,
# no relaunch · kill-switch → warn · loop protection → fail after 3 · recent keypress → warn.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
WD="$here/scripts/lead-watchdog.sh"
T=$(mktemp -d "${TMPDIR:-/var/tmp}/lead-wd.XXXXXX"); trap 'tmux -L lwtest kill-server 2>/dev/null; rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/state" "$T/checks"
cat > "$T/bin/claude" <<'EOF'
#!/bin/bash
echo "stub claude $*" > "${STUB_OUT:?}/claude.args"; sleep 30
EOF
chmod +x "$T/bin/claude"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/true-mail"; chmod +x "$T/bin/true-mail"
: > "$T/env.sh"
export STUB_OUT="$T" PATH="$T/bin:$PATH" LEAD_PANE="lwtest:0.0" LEAD_WATCHDOG_STATE="$T/state" CHECKS_DIR="$T/checks" \
       LEAD_LAUNCH_ENV="$T/env.sh" LEAD_WATCHDOG_MAIL="$T/bin/true-mail" LEAD_TMUX_SOCKET=lwtest LEAD_WATCHDOG_WAIT=5
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "ok   $1"; }
bad() { fail=$((fail+1)); echo "FAIL $1"; }
run() { bash "$WD" 2>&1; }
fresh() {  # a pane at a bash prompt; $1 = text to print first (the resume hint or not)
    tmux -L lwtest kill-server 2>/dev/null
    # kill-server returns before the old server has gone; a new-session in that instant talks to the dying one and
    # the session is lost (seen as "no tmux session" in a full run, 2026-11-18). Start, then WAIT until it is there.
    for _try in 1 2 3 4 5 6 7 8 9 10; do
        tmux -L lwtest new-session -d -s lwtest -x 120 -y 30 "bash --norc --noprofile" 2>/dev/null
        sleep 0.4
        tmux -L lwtest has-session -t =lwtest 2>/dev/null && break
    done
    sleep 0.3
    [ -n "${1:-}" ] && { tmux -L lwtest send-keys -t lwtest:0.0 -l "printf '%s\n' \"$1\""; tmux -L lwtest send-keys -t lwtest:0.0 Enter; sleep 0.5; }
    rm -f "$T/claude.args" "$T/state/lead-watchdog.relaunches" "$T/state/lead-watchdog.off"
}
HINT="Resume this session with: claude --resume 3f2afe4b-df91-402b-8792-e19b2a007cf6"

# 1. alive: a child runs in the pane
fresh ""; tmux -L lwtest send-keys -t lwtest:0.0 -l "sleep 15"; tmux -L lwtest send-keys -t lwtest:0.0 Enter; sleep 0.5
out=$(run); grep -q '^CHECK lead-liveness ok · pane lwtest:0.0 has a running child' <<<"$out" && [ ! -e "$T/claude.args" ] && ok "alive → ok, no relaunch" || bad "alive: $out"

# 2. dead with the hint → relaunch
fresh "$HINT"; sleep 1.2   # client_activity: no client is attached on -L, so the keypress rule does not fire
out=$(run)
if grep -q '^CHECK lead-liveness ok · relaunched 3f2afe4b' <<<"$out" && grep -q -- '--resume 3f2afe4b-df91-402b-8792-e19b2a007cf6 --permission-mode bypassPermissions' "$T/claude.args" 2>/dev/null; then ok "dead with hint → relaunched with the pane's id"; else bad "dead with hint: $out / $(cat "$T/claude.args" 2>/dev/null)"; fi
[ "$(wc -l < "$T/state/lead-watchdog.relaunches")" = 1 ] && ok "relaunch recorded once" || bad "relaunch history: $(cat "$T/state/lead-watchdog.relaunches")"

# 2b. a half-typed command sitting at the prompt is discarded, never run by our Enter
fresh "$HINT"; tmux -L lwtest send-keys -t lwtest:0.0 -l "touch $T/UNINTENDED #"; sleep 1.2
out=$(run); sleep 0.5
[ ! -e "$T/UNINTENDED" ] && grep -q -- '--resume 3f2afe4b-df91-402b-8792-e19b2a007cf6' "$T/claude.args" 2>/dev/null && ok "pending text at the prompt is discarded (Ctrl-U); only the relaunch runs" || bad "pending input ran: $(ls "$T" | tr '\n' ' ') / $out"

# 2c. the same with the cursor moved to the START of the pending text (Ctrl-U alone clears nothing there)
fresh "$HINT"; tmux -L lwtest send-keys -t lwtest:0.0 -l "; touch $T/UNINTENDED2 #"; tmux -L lwtest send-keys -t lwtest:0.0 C-a; sleep 1.2
out=$(run); sleep 0.5
[ ! -e "$T/UNINTENDED2" ] && grep -q -- '--resume 3f2afe4b-df91-402b-8792-e19b2a007cf6' "$T/claude.args" 2>/dev/null && ok "pending text with the cursor at its start is discarded too (Ctrl-E, then Ctrl-U)" || bad "pending suffix ran: $(ls "$T" | tr '\n' ' ') / $out"

# 3. dead without the hint → fail, no relaunch
fresh "no hint here"; out=$(run)
grep -q '^CHECK lead-liveness fail · pane lwtest:0.0 is at a shell with no' <<<"$out" && [ ! -e "$T/claude.args" ] && ok "dead without hint → fail, no relaunch" || bad "no hint: $out"

# 4. kill-switch
fresh "$HINT"; touch "$T/state/lead-watchdog.off"; out=$(run)
grep -q '^CHECK lead-liveness warn · watchdog off' <<<"$out" && [ ! -e "$T/claude.args" ] && ok "kill-switch → warn, no relaunch" || bad "kill-switch: $out"

# 5. loop protection: 3 relaunches in the last hour → fail
fresh "$HINT"; now=$(date +%s); printf '%s\n%s\n%s\n' "$((now-100))" "$((now-200))" "$((now-300))" > "$T/state/lead-watchdog.relaunches"; out=$(run)
grep -q '^CHECK lead-liveness fail · .*3 relaunches already' <<<"$out" && [ ! -e "$T/claude.args" ] && ok "loop protection → fail after 3/hour" || bad "loop: $out"

# 6. no tmux session → fail
tmux -L lwtest kill-server 2>/dev/null; out=$(run)
grep -q "^CHECK lead-liveness fail · no tmux session 'lwtest'" <<<"$out" && ok "no session → fail" || bad "no session: $out"

# 7. (2026-11-19) dead, NO hint in the pane, but lead.session names this pane and an id → relaunched from the file
SID2=11111111-2222-3333-4444-555555555555
fresh "no hint here"
printf 'session=%s\npane=lwtest:0.0\nlaunch=. %s; claude --resume %s --permission-mode bypassPermissions\n' "$SID2" "$T/env.sh" "$SID2" > "$T/state/lead.session"
out=$(run)
if grep -q '^CHECK lead-liveness ok · relaunched 11111111 .* from lead.session' <<<"$out" && grep -q -- "--resume $SID2 --permission-mode bypassPermissions" "$T/claude.args" 2>/dev/null; then ok "dead, no hint, lead.session → relaunched with the recorded id"; else bad "lead.session relaunch: $out / $(cat "$T/claude.args" 2>/dev/null)"; fi

# 8. the pane comes from lead.session when LEAD_PANE is not set (the lead is not always in spire:0.0)
fresh "no hint here"; tmux -L lwtest new-window -d -t lwtest "bash --norc --noprofile"; sleep 0.5
printf 'session=%s\npane=lwtest:1.0\nlaunch=. %s; claude --resume %s --permission-mode bypassPermissions\n' "$SID2" "$T/env.sh" "$SID2" > "$T/state/lead.session"
out=$(env -u LEAD_PANE bash "$WD" 2>&1)
grep -q '^CHECK lead-liveness ok · relaunched 11111111 in lwtest:1.0' <<<"$out" && ok "the watched pane is the one lead.session names" || bad "pane from file: $out"

# 9. a launch line that is not the writer's exact form is never typed; the canonical line is used instead
fresh "no hint here"
printf 'session=%s\npane=lwtest:0.0\nlaunch=touch %s/PWNED; claude --resume %s\n' "$SID2" "$T" "$SID2" > "$T/state/lead.session"
out=$(run)
[ ! -e "$T/PWNED" ] && grep -q -- "--resume $SID2 --permission-mode bypassPermissions" "$T/claude.args" 2>/dev/null && ok "a tampered launch line is ignored (never typed); the canonical line runs" || bad "tampered launch: $out $(ls "$T" | tr '\n' ' ')"

# 9b. a launch line of exactly the writer's SHAPE but naming another file to source is never typed either
fresh "no hint here"; printf 'touch %s/SOURCED\n' "$T" > "$T/evil-env.sh"
printf 'session=%s\npane=lwtest:0.0\nlaunch=. %s/evil-env.sh; claude --resume %s --permission-mode bypassPermissions\n' "$SID2" "$T" "$SID2" > "$T/state/lead.session"
out=$(run); sleep 0.5
[ ! -e "$T/SOURCED" ] && grep -q -- "--resume $SID2 --permission-mode bypassPermissions" "$T/claude.args" 2>/dev/null && ok "a right-shaped launch line naming another env file is not typed: the watchdog's own env path is used" || bad "alternate env sourced: $(ls "$T" | tr '\n' ' ')"
fresh "no hint here"; printf 'session=%s\npane=lwtest:0.0\n' "$SID2" > "$T/state/lead.session"
out=$(LEAD_LAUNCH_ENV='/x; touch /nope' run); grep -q '^CHECK lead-liveness fail · the launch-env path or the session id is not in a plain form' <<<"$out" && [ ! -e "$T/claude.args" ] && ok "a launch-env setting that is not a plain path: nothing is typed" || bad "odd launch env: $out"

# 10. a lead.session with a bad id, or one that is a symlink, is not used
fresh "no hint here"; printf 'session=not-a-uuid; rm -rf x\npane=lwtest:0.0\n' > "$T/state/lead.session"; out=$(run)
grep -q '^CHECK lead-liveness fail · pane lwtest:0.0 is at a shell with no' <<<"$out" && [ ! -e "$T/claude.args" ] && ok "a bad id in lead.session → fail, no relaunch" || bad "bad id: $out"
fresh "no hint here"; printf 'session=%s\npane=lwtest:0.0\n' "$SID2" > "$T/real.session"; rm -f "$T/state/lead.session"; ln -s "$T/real.session" "$T/state/lead.session"; out=$(run)
grep -q '^CHECK lead-liveness fail · ' <<<"$out" && [ ! -e "$T/claude.args" ] && ok "a symlinked lead.session is not read" || bad "symlinked file: $out"
rm -f "$T/state/lead.session"

# ── 2026-11-22: the session or the pane is GONE, or the pane is not at a prompt (Flow row 8c258c8b) ─────────────
# oomd killed the lead's pane scope at 04:26; the session went with its only pane and the watchdog said "relaunch
# by hand" every 2 minutes for 37 hours. In these cases the panes it makes run a plain bash (LEAD_SHELL_CMD), and a
# tmux server it has to start goes through a stub scope runner that logs its call (LEAD_SCOPE_RUN).
export LEAD_SHELL_CMD="bash --norc --noprofile"
printf '#!/bin/bash\necho "$*" >> "%s/scope-run.log"\nexec "$@"\n' "$T" > "$T/bin/scope-run"; chmod +x "$T/bin/scope-run"
export LEAD_SCOPE_RUN="$T/bin/scope-run"
sess_file() { printf 'session=%s\npane=%s\n' "$SID2" "${1:-lwtest:0.0}" > "$T/state/lead.session"; }
reset() { rm -f "$T/claude.args" "$T/state/lead-watchdog.relaunches" "$T/state/lead-watchdog.off" "$T/scope-run.log"; }

# 13. no tmux SERVER at all, lead.session has the id → the session is recreated in a scope of its own, the lead resumed
tmux -L lwtest kill-server 2>/dev/null; sleep 0.5; reset; sess_file
out=$(env -u LEAD_PANE bash "$WD" 2>&1)
if grep -q '^CHECK lead-liveness ok · relaunched 11111111 in lwtest:[0-9]*\.[0-9]* .* from lead.session, session recreated' <<<"$out" \
   && grep -q -- "--resume $SID2 --permission-mode bypassPermissions" "$T/claude.args" 2>/dev/null && tmux -L lwtest has-session -t =lwtest 2>/dev/null; then
  ok "no server: the session is recreated and the lead resumed from lead.session"; else bad "recreate, no server: $out"; fi
grep -q 'new-session -d -s lwtest' "$T/scope-run.log" 2>/dev/null && ok "a tmux server started by the watchdog goes through the scope runner (never a child of the unit)" || bad "scope runner not used: $(cat "$T/scope-run.log" 2>&1)"
[ "$(wc -l < "$T/state/lead-watchdog.relaunches")" = 1 ] && ok "a recreation counts as one relaunch" || bad "recreate history"

# 14. the server is alive (another session), only the lead's session is gone → recreated WITHOUT the scope runner
tmux -L lwtest kill-server 2>/dev/null; sleep 0.5
for _try in 1 2 3 4 5; do tmux -L lwtest new-session -d -s other "bash --norc --noprofile" 2>/dev/null; sleep 0.4; tmux -L lwtest has-session -t =other 2>/dev/null && break; done
reset; sess_file; out=$(env -u LEAD_PANE bash "$WD" 2>&1)
if grep -q '^CHECK lead-liveness ok · relaunched 11111111 .* session recreated' <<<"$out" && [ ! -e "$T/scope-run.log" ] && tmux -L lwtest has-session -t =other 2>/dev/null; then
  ok "server alive, session gone: recreated by the running server; the other session is untouched"; else bad "recreate, server alive: $out $(cat "$T/scope-run.log" 2>&1)"; fi

# 15. session gone and NO id anywhere → fail, nothing made, nothing guessed
tmux -L lwtest kill-session -t =lwtest 2>/dev/null; reset; rm -f "$T/state/lead.session"; out=$(run)
grep -q "^CHECK lead-liveness fail · no tmux session 'lwtest' and no lead.session id" <<<"$out" && ! tmux -L lwtest has-session -t =lwtest 2>/dev/null && [ ! -e "$T/claude.args" ] \
  && ok "session gone, no id: fail, no session made" || bad "no id: $out"

# 16. session gone, a BAD id in lead.session → the same refusal
reset; printf 'session=zzz; touch %s/BADID\npane=lwtest:0.0\n' "$T" > "$T/state/lead.session"; out=$(run)
grep -q "no lead.session id" <<<"$out" && ! tmux -L lwtest has-session -t =lwtest 2>/dev/null && [ ! -e "$T/BADID" ] && ok "session gone, bad id: nothing made, nothing run" || bad "bad id recreate: $out"

# 17. session gone, kill-switch → warn, nothing made
reset; sess_file; touch "$T/state/lead-watchdog.off"; out=$(run)
grep -q '^CHECK lead-liveness warn · watchdog off' <<<"$out" && ! tmux -L lwtest has-session -t =lwtest 2>/dev/null && ok "kill-switch holds for a recreation too" || bad "kill-switch recreate: $out"

# 18. session gone, 3 relaunches in the last hour → fail, nothing made
reset; sess_file; now=$(date +%s); printf '%s\n%s\n%s\n' "$((now-100))" "$((now-200))" "$((now-300))" > "$T/state/lead-watchdog.relaunches"; out=$(run)
grep -q "^CHECK lead-liveness fail · no tmux session 'lwtest'; 3 relaunches already" <<<"$out" && ! tmux -L lwtest has-session -t =lwtest 2>/dev/null && [ ! -e "$T/claude.args" ] \
  && ok "the loop guard holds for a recreation too" || bad "loop recreate: $out"

# 19. the session lives (two windows) but the lead's PANE is gone → a new window for it, the lead resumed there
fresh "no hint here"; tmux -L lwtest new-window -d -t lwtest "bash --norc --noprofile"; sleep 0.4
tmux -L lwtest kill-pane -t lwtest:0.0; sleep 0.4; reset; sess_file lwtest:0.0
out=$(env -u LEAD_PANE bash "$WD" 2>&1)
if grep -q '^CHECK lead-liveness ok · relaunched 11111111 in lwtest:[0-9]*\.0 .* window recreated' <<<"$out" && grep -q -- "--resume $SID2" "$T/claude.args" 2>/dev/null; then
  ok "pane gone, session alive: a new window is made and the lead resumed in it"; else bad "window recreate: $out"; fi
tmux -L lwtest display -p -t lwtest:1.0 '#{pane_pid}' > /dev/null 2>&1 && [ -z "$(pgrep -P "$(tmux -L lwtest display -p -t lwtest:1.0 '#{pane_pid}')")" ] && ok "…and the session's other window was not typed into" || bad "the other window was touched"

# 20. the pane's shell sits at a continuation prompt (an unfinished `if`): the first version warned forever. Now the
#     pane is respawned and the lead resumed; the unfinished command NEVER runs.
fresh "$HINT"; tmux -L lwtest send-keys -t lwtest:0.0 -l "if true; then touch $T/PS2RAN"; tmux -L lwtest send-keys -t lwtest:0.0 Enter; sleep 1.2; reset
out=$(run); sleep 0.5
if grep -q '^CHECK lead-liveness ok · relaunched 3f2afe4b .* pane respawned' <<<"$out" && [ ! -e "$T/PS2RAN" ] && grep -q -- '--resume 3f2afe4b-df91-402b-8792-e19b2a007cf6' "$T/claude.args" 2>/dev/null; then
  ok "a pane not at a prompt is respawned and the lead resumed; the unfinished command never runs"; else bad "not-a-prompt: $out ran=$(ls "$T/PS2RAN" 2>&1)"; fi

# 21. a DEAD pane kept by remain-on-exit (what a killed pane looks like there) → respawned, resumed from lead.session
fresh "no hint here"; tmux -L lwtest set-option -t lwtest remain-on-exit on; tmux -L lwtest send-keys -t lwtest:0.0 -l "exit"; tmux -L lwtest send-keys -t lwtest:0.0 Enter; sleep 0.8
[ "$(tmux -L lwtest display -p -t lwtest:0.0 '#{pane_dead}')" = 1 ] && ok "fixture: the pane is dead and kept" || bad "fixture: pane_dead=$(tmux -L lwtest display -p -t lwtest:0.0 '#{pane_dead}' 2>&1)"
reset; sess_file; out=$(run)
if grep -q '^CHECK lead-liveness ok · relaunched 11111111 in lwtest:0.0 .* from lead.session, pane respawned' <<<"$out" && grep -q -- "--resume $SID2" "$T/claude.args" 2>/dev/null; then
  ok "a dead pane is respawned and the lead resumed"; else bad "dead pane: $out"; fi

# 22. a pane with something RUNNING is never respawned, whatever its last line looks like
fresh ""; tmux -L lwtest send-keys -t lwtest:0.0 -l "sleep 20; echo not-a-prompt-line"; tmux -L lwtest send-keys -t lwtest:0.0 Enter; sleep 0.6
pid_before=$(tmux -L lwtest display -p -t lwtest:0.0 '#{pane_pid}'); reset; sess_file; out=$(run)
grep -q '^CHECK lead-liveness ok · pane lwtest:0.0 has a running child' <<<"$out" && [ "$(tmux -L lwtest display -p -t lwtest:0.0 '#{pane_pid}')" = "$pid_before" ] && [ ! -e "$T/claude.args" ] \
  && ok "a live pane is left alone (no respawn, nothing typed)" || bad "live pane touched: $out"
rm -f "$T/state/lead.session"; unset LEAD_SHELL_CMD LEAD_SCOPE_RUN

# 11. the writer hook: only the lead's session (tmux session name + cwd = HOME) writes the file
WR="$here/scripts/lead-session-write.sh"
fresh ""; pane_id=$(tmux -L lwtest display -p -t lwtest:0.0 '#{pane_id}')
hook() { ( cd "$1" && printf '{"session_id":"%s"}' "$2" | HOME="$T/home" TMUX_PANE="$pane_id" DREAMTEAM_LEAD_SESSION="$3" bash "$WR" ); }
mkdir -p "$T/home/sub"
hook "$T/home" "$SID2" lwtest; rc=$?
[ "$rc" = 0 ] && grep -qx "session=$SID2" "$T/state/lead.session" && grep -qx "pane=lwtest:0.0" "$T/state/lead.session" && grep -qx "launch=. $T/env.sh; claude --resume $SID2 --permission-mode bypassPermissions" "$T/state/lead.session" \
  && [ "$(stat -c %a "$T/state/lead.session")" = 600 ] && ok "the lead's SessionStart writes lead.session (0600, three lines)" || bad "writer: rc=$rc $(cat "$T/state/lead.session" 2>&1)"
rm -f "$T/state/lead.session"; hook "$T/home/sub" "$SID2" lwtest; [ ! -e "$T/state/lead.session" ] && ok "a session in another directory writes nothing" || bad "writer wrote from a non-HOME cwd"
hook "$T/home" "$SID2" othersession; [ ! -e "$T/state/lead.session" ] && ok "a session in another tmux session writes nothing" || bad "writer wrote for a non-lead session"
hook "$T/home" "bad id" lwtest; rc=$?; [ "$rc" = 0 ] && [ ! -e "$T/state/lead.session" ] && ok "a bad session id writes nothing and still exits 0" || bad "writer with a bad id"
# round trip: what the writer wrote is what the watchdog relaunches from
hook "$T/home" "$SID2" lwtest; fresh "no hint here"; hook "$T/home" "$SID2" lwtest; out=$(env -u LEAD_PANE bash "$WD" 2>&1)
grep -q '^CHECK lead-liveness ok · relaunched 11111111 in lwtest:0.0 .* from lead.session' <<<"$out" && ok "round trip: the hook's file is enough for the watchdog to relaunch" || bad "round trip: $out"

# 12. the unit can never again be stopped by a lost exec bit: ExecStart goes through bash, and git records 100755
grep -q '^ExecStart=/usr/bin/bash %h/Projects/dreamteam/scripts/lead-watchdog.sh$' "$here/systemd/dreamteam-lead-watchdog.service" && ok "the unit starts the script through bash" || bad "unit ExecStart: $(grep ExecStart "$here/systemd/dreamteam-lead-watchdog.service")"
if git -C "$here" rev-parse --git-dir >/dev/null 2>&1; then
  m=$(git -C "$here" ls-files -s -- scripts/lead-watchdog.sh scripts/lead-session-write.sh | awk '{print $1, $4}' | tr '\n' '|')
  [ "$m" = "100755 scripts/lead-session-write.sh|100755 scripts/lead-watchdog.sh|" ] && ok "exactly these two scripts, each committed executable (100755)" || bad "git modes: $m"
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
