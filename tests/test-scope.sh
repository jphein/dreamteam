#!/usr/bin/env bash
# dreamteam tests — scope-attach.sh (automatic containment).
# Hermetic: systemd-run/busctl/systemctl/pgrep are PATH-stubbed and record
# their invocations; /proc reads are steered via fake pid dirs? No — pids come
# from the stubbed pgrep and point at REAL /proc entries we control:
# we use our own shell's children so /proc/<pid>/cmdline and cgroup exist.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SA="$ROOT/scripts/scope-attach.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; kill $AGENT_PID $PLAIN_PID 2>/dev/null' EXIT INT TERM

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# Two real child procs: one whose cmdline carries --agent-id (an "agent"),
# one without (a "main session"). The extra args ride as bash positional
# params so they stay visible in /proc/<pid>/cmdline (an exec would drop them).
# (compound command — a lone `sleep` gets exec-optimized and the argv vanishes)
bash -c 'sleep 60 && true' claude-versions-fake --agent-id fake@test &
AGENT_PID=$!
bash -c 'sleep 60 && true' claude-versions-fake &
PLAIN_PID=$!
sleep 0.2

# Stubs: record every call; systemctl says scope is NOT active first call,
# active afterwards (simulates creation); busctl records and succeeds.
mkdir -p "$TMP/bin" "$TMP/state"
CALLS="$TMP/calls.log"
cat > "$TMP/bin/systemctl" <<EOF
#!/bin/bash
echo "systemctl \$*" >> "$CALLS"
[ -f "$TMP/scope-up" ] && exit 0 || exit 3
EOF
cat > "$TMP/bin/systemd-run" <<EOF
#!/bin/bash
echo "systemd-run \$*" >> "$CALLS"
touch "$TMP/scope-up"
exit 0
EOF
cat > "$TMP/bin/busctl" <<EOF
#!/bin/bash
echo "busctl \$*" >> "$CALLS"
exit 0
EOF
cat > "$TMP/bin/pgrep" <<EOF
#!/bin/bash
echo "$AGENT_PID"
echo "$PLAIN_PID"
EOF
chmod +x "$TMP/bin/"*
# DREAMTEAM_SCOPE_NAME: fake scope so fixtures that INHERIT the real
# dreamteam-agents.scope cgroup (this test may run inside a contained teammate
# session) never trip the idempotency skip — lucid root-caused this 2026-07-01.
run() { PATH="$TMP/bin:$PATH" DREAMTEAM_SCOPE_NAME="dreamteam-testscope-$$" DREAMTEAM_STATE="$TMP/state" DREAMTEAM_CONFIG="${1:-$ROOT/config.json}" CLAUDE_PLUGIN_ROOT="$ROOT" bash "$SA"; }

bash -n "$SA" && ok "bash -n scope-attach.sh" || bad "bash -n scope-attach.sh"

# 1. Full run: creates the scope with config caps, attaches ONLY the agent pid
: > "$CALLS"; rm -f "$TMP/scope-up"
run; RC=$?
[ "$RC" -eq 0 ] && ok "exits 0" || bad "exit $RC"
grep -q "systemd-run --user --scope --unit=dreamteam-testscope-$$" "$CALLS" && ok "creates capped scope when absent" || bad "scope creation"
grep -q 'MemoryMax=24G' "$CALLS" && ok "scope uses config MemoryMax" || bad "config caps"
grep -q 'Delegate=yes' "$CALLS" && ok "scope created with Delegate=yes (AttachProcessesToUnit requires it)" || bad "Delegate=yes missing — attach will fail on non-delegated units"
grep -q "AttachProcessesToUnit ssau dreamteam-testscope-$$.scope / 1 $AGENT_PID" "$CALLS" && ok "attaches the --agent-id proc" || bad "agent attach"
grep -q "1 $PLAIN_PID" "$CALLS" && bad "must NOT attach non-agent proc" || ok "main-session proc left outside (orchestrator survives)"
grep -q 'scope-attach: 1 agent' "$TMP/state/dreamteam.log" && ok "attach logged" || bad "attach log"

# 2. Scope already active: no re-creation, attach still runs
: > "$CALLS"
run
grep -q 'systemd-run' "$CALLS" && bad "no re-creation when scope active" || ok "no re-creation when scope active"
grep -q 'AttachProcessesToUnit' "$CALLS" && ok "attach still attempted when scope active" || bad "attach when active"

# 3. autoAttach=false → complete no-op
echo '{"scope":{"autoAttach":false}}' > "$TMP/off.json"
: > "$CALLS"
run "$TMP/off.json"
[ -s "$CALLS" ] && bad "autoAttach=false must be a no-op ($(cat "$CALLS"))" || ok "autoAttach=false is a no-op"

# 4. busctl failure tolerated (exit 0, nothing logged as attached)
cat > "$TMP/bin/busctl" <<'EOF'
#!/bin/bash
exit 1
EOF
: > "$TMP/state/dreamteam.log"
run; RC=$?
[ "$RC" -eq 0 ] && ok "busctl failure: still exits 0" || bad "busctl failure exit $RC"
grep -q 'scope-attach' "$TMP/state/dreamteam.log" && bad "failed attach must not log success" || ok "failed attach not logged as success"

# ── #19: per-project scopes ───────────────────────────────────────────────────
# 5. Project filter — an agent proc whose cwd is a DIFFERENT project must never
#    be attached (the near-miss rail: foreign fleets are not ours to contain).
mkdir -p "$TMP/otherproj"
( cd "$TMP/otherproj" && exec bash -c 'sleep 60 && true' claude-versions-fake --agent-id foreign@other ) &
FOREIGN_PID=$!
trap 'rm -rf "$TMP"; kill $AGENT_PID $PLAIN_PID $FOREIGN_PID 2>/dev/null' EXIT INT TERM
sleep 0.2
cat > "$TMP/bin/busctl" <<EOF
#!/bin/bash
echo "busctl \$*" >> "$CALLS"
exit 0
EOF
cat > "$TMP/bin/pgrep" <<EOF
#!/bin/bash
echo "$AGENT_PID"
echo "$FOREIGN_PID"
EOF
chmod +x "$TMP/bin/"*
: > "$CALLS"
run
grep -q "1 $AGENT_PID" "$CALLS" && ok "own-project agent still attached" || bad "own-project attach broken"
grep -q "1 $FOREIGN_PID" "$CALLS" && bad "FOREIGN project's agent was attached — cross-project containment forbidden" \
  || ok "foreign-project agent left alone (#19 filter)"

# 6. Scope-name derivation (lib.sh) — env wins > config .scope.name > derived > fallback
. "$ROOT/scripts/lib.sh"
N1=$(DREAMTEAM_SCOPE_NAME="dreamteam-pinned" DREAMTEAM_CONFIG="$ROOT/config.json" dreamteam_scope_name)
[ "$N1" = "dreamteam-pinned" ] && ok "derivation: env seam wins" || bad "env seam: $N1"
echo '{"scope":{"name":"dreamteam-cfg"}}' > "$TMP/named.json"
N2=$(DREAMTEAM_SCOPE_NAME= DREAMTEAM_CONFIG="$TMP/named.json" dreamteam_scope_name)
[ "$N2" = "dreamteam-cfg" ] && ok "derivation: config .scope.name honored" || bad "config name: $N2"
mkdir -p "$TMP/My_Cool.Repo/.claude/worktrees/luna-w1"
N3=$(DREAMTEAM_SCOPE_NAME= DREAMTEAM_CONFIG="$ROOT/config.json" DREAMTEAM_PROJECT_DIR="$TMP/My_Cool.Repo/.claude/worktrees/luna-w1" dreamteam_scope_name)
[ "$N3" = "dreamteam-my-cool-repo" ] && ok "derivation: worktree-strip + sanitize (My_Cool.Repo → my-cool-repo)" || bad "derived: $N3"
N4=$(DREAMTEAM_SCOPE_NAME= DREAMTEAM_CONFIG="$ROOT/config.json" DREAMTEAM_PROJECT_DIR="$TMP/My_Cool.Repo" dreamteam_project_root)
[ "$N4" = "$(readlink -f "$TMP")/My_Cool.Repo" ] && ok "project root resolves real path" || bad "root: $N4"

echo "────────────────────────────────────────"
echo "SUMMARY: $PASS passed, $FAIL failed, $((PASS+FAIL)) total"
[ "$FAIL" -eq 0 ]
