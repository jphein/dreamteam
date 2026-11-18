#!/bin/bash
# tests/test-lead-watchdog.sh — the lead watchdog against a throwaway tmux server (-L), a stub `claude` and a stub mailer.
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
    tmux -L lwtest new-session -d -s lwtest -x 120 -y 30 "bash --norc --noprofile"
    sleep 0.5
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

echo "lead-watchdog: $pass ok, $fail failed"; [ "$fail" = 0 ]
