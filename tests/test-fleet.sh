#!/usr/bin/env bash
# dreamteam tests — fleet.sh (issue #18: cross-scope, cross-socket observer).
# Hermetic: fake cgroup tree, fake /proc, stubbed tmux/ps/pgrep, HOME redirect.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FLEET="$ROOT/scripts/fleet.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

bash -n "$FLEET" && ok "bash -n fleet.sh" || bad "bash -n"

# ── the observer must be structurally unable to kill (reap-safety law) ───────
grep -qE '\bkill\b|\bpkill\b|shutdown' "$FLEET" \
  && bad "fleet.sh contains a kill/reap path — forbidden by #18" \
  || ok "no kill/pkill/shutdown path exists in fleet.sh"

# ── fixture world ─────────────────────────────────────────────────────────────
# projects: alpha (caller's), beta (someone else's, agent in a worktree)
mkdir -p "$TMP/home/Projects/alpha" "$TMP/home/Projects/beta/.claude/worktrees/luna-w1/src"

# cgroups: shared scope (pid 101 + anchor 99), per-project scope with a NESTED
# sub-cgroup (pid 102) — exercises the recursive cgroup.procs collection.
CG="$TMP/cg/app.slice"
mkdir -p "$CG/dreamteam-agents.scope" "$CG/dreamteam-beta.scope/nested"
printf '99\n101\n' > "$CG/dreamteam-agents.scope/cgroup.procs"
echo $((512 * 1048576)) > "$CG/dreamteam-agents.scope/memory.current"
: > "$CG/dreamteam-beta.scope/cgroup.procs"
printf '102\n' > "$CG/dreamteam-beta.scope/nested/cgroup.procs"
echo $((256 * 1048576)) > "$CG/dreamteam-beta.scope/memory.current"

# /proc: 101 (alpha, --agent-id, PPid chain 101→60→50 where 50 is a pane pid),
#        102 (beta worktree, no --agent-id, no pane in chain — and stale-shaped),
#        103 (alpha, pane-root child, fresh — not stale)
mkproc() { # pid ppid cwd cmdline
  mkdir -p "$TMP/proc/$1"
  printf 'Name:\tclaude\nPPid:\t%s\n' "$2" > "$TMP/proc/$1/status"
  ln -sfn "$3" "$TMP/proc/$1/cwd"
  printf '%s' "$4" | tr ' ' '\0' > "$TMP/proc/$1/cmdline"
}
mkproc 101 60 "$TMP/home/Projects/alpha" "claude --agent-id lucid-x@t1"
mkproc 60  50 "$TMP/home/Projects/alpha" "bash"
mkproc 102 61 "$TMP/home/Projects/beta/.claude/worktrees/luna-w1/src" "claude"
mkproc 61  1  "$TMP/home/Projects/beta" "bash"
mkproc 103 50 "$TMP/home/Projects/alpha" "claude"

# tmux: one socket file, pane 50 at sess "dream" window 2 pane 1
mkdir -p "$TMP/tmux" "$TMP/bin"
: > "$TMP/tmux/default"
cat > "$TMP/bin/tmux" <<EOF
#!/bin/bash
echo "dream:2.1 50"
EOF
# ps: etimes/cputimes/rss per pid — 102 is old+idle (stale-shaped)
cat > "$TMP/bin/ps" <<'EOF'
#!/bin/bash
pid="${@: -1}"
case "$pid" in
  101) echo "  500  40 409600" ;;
  102) echo " 9999   1 204800" ;;
  103) echo "  120  30 102400" ;;
esac
EOF
cat > "$TMP/bin/pgrep" <<'EOF'
#!/bin/bash
printf '101\n102\n103\n'
EOF
chmod +x "$TMP/bin/"*

# Liveness stamps (#20): 101 stamped fresh-working; 102 stamped idle LONG ago
# (pane-less + old stamp ⇒ stale); 103 unstamped (heuristic path). Plus one
# ancient orphan stamp the age-GC must prune.
mkdir -p "$TMP/fleetstate"
printf 'working %s\n' "$(date +%s)" > "$TMP/fleetstate/alpha__lucid-x"
printf 'idle %s\n' "$(( $(date +%s) - 99999 ))" > "$TMP/fleetstate/beta__luna-w1"
touch -d '3 days ago' "$TMP/fleetstate/ghost__gone"

run() { HOME="$TMP/home" DREAMTEAM_CGROUP_ROOT="$TMP/cg" DREAMTEAM_TMUX_DIR="$TMP/tmux" \
        DREAMTEAM_PROC="$TMP/proc" DREAMTEAM_CALLER_CWD="$TMP/home/Projects/alpha" \
        DREAMTEAM_FLEET_STATE="$TMP/fleetstate" \
        DREAMTEAM_CONFIG="$ROOT/config.json" CLAUDE_PLUGIN_ROOT="$ROOT" \
        PATH="$TMP/bin:$PATH" bash "$FLEET" "$@"; }

# ── JSON contract ─────────────────────────────────────────────────────────────
J="$(run --json)"
echo "$J" | jq -e . >/dev/null 2>&1 && ok "--json emits valid JSON" || { bad "--json invalid: $J"; exit 1; }
[ "$(echo "$J" | jq -r '.caller')" = "alpha" ] && ok "caller project resolved (alpha)" || bad "caller: $(echo "$J" | jq -r .caller)"
[ "$(echo "$J" | jq -r '.agents | length')" = "3" ] && ok "all 3 agents enumerated" || bad "agent count"
[ "$(echo "$J" | jq -r '.scopes | length')" = "2" ] && ok "both scopes discovered (find, not glob)" || bad "scope count"
[ "$(echo "$J" | jq -r '.scopes[] | select(.name=="dreamteam-agents.scope") | .memMB')" = "512" ] \
  && ok "scope memory.current read (512 MiB)" || bad "scope mem"

A101='.agents[] | select(.pid==101)'
[ "$(echo "$J" | jq -r "$A101 | .agent")" = "lucid-x" ] && ok "--agent-id beats cwd for agent name" || bad "agent-id name"
[ "$(echo "$J" | jq -r "$A101 | .pane")" = "default@dream:2.1" ] && ok "pane matched via PPid chain (101→60→50)" || bad "pane: $(echo "$J" | jq -r "$A101|.pane")"
[ "$(echo "$J" | jq -r "$A101 | .scope")" = "dreamteam-agents.scope" ] && ok "scope attribution (direct member)" || bad "101 scope"
[ "$(echo "$J" | jq -r "$A101 | .yours")" = "true" ] && ok "caller's own agent marked yours" || bad "101 yours"
[ "$(echo "$J" | jq -r "$A101 | .stale")" = "false" ] && ok "agent with pane never stale" || bad "101 stale"

A102='.agents[] | select(.pid==102)'
[ "$(echo "$J" | jq -r "$A102 | .project")" = "beta" ] && ok "worktree cwd maps to owning project (beta)" || bad "102 project"
[ "$(echo "$J" | jq -r "$A102 | .agent")" = "luna-w1" ] && ok "worktree dir doubles as agent name" || bad "102 agent"
[ "$(echo "$J" | jq -r "$A102 | .scope")" = "dreamteam-beta.scope" ] && ok "NESTED cgroup member attributed to its scope" || bad "102 scope"
[ "$(echo "$J" | jq -r "$A102 | .yours")" = "false" ] && ok "other project's agent yours=false" || bad "102 yours"
[ "$(echo "$J" | jq -r "$A102 | .stale")" = "true" ] && ok "pane-less + old + idle ⇒ stale candidate" || bad "102 stale"

# ── liveness stamps (#20) ─────────────────────────────────────────────────────
[ "$(echo "$J" | jq -r "$A101 | .live")" = "working" ] && ok "fresh stamp read (live=working)" || bad "101 live: $(echo "$J" | jq -r "$A101|.live")"
[ "$(echo "$J" | jq -r "$A101 | .liveAgeSec < 60")" = "true" ] && ok "stamp age computed" || bad "101 liveAge"
[ "$(echo "$J" | jq -r "$A102 | .live")" = "idle" ] && ok "old idle stamp read on 102" || bad "102 live"
[ "$(echo "$J" | jq -r '.agents[] | select(.pid==103) | .live')" = "null" ] && ok "unstamped agent falls back to heuristic (live=null)" || bad "103 live"
[ -f "$TMP/fleetstate/ghost__gone" ] && bad "ancient stamp survived age-GC" || ok "age-GC pruned the 3-day-old orphan stamp"
[ -f "$TMP/fleetstate/alpha__lucid-x" ] && ok "fresh stamps survive GC" || bad "GC ate a fresh stamp"

# ── filters ───────────────────────────────────────────────────────────────────
[ "$(run --json --project beta | jq -r '.agents | length')" = "1" ] && ok "--project filters" || bad "--project"
[ "$(run --json --stale | jq -r '.agents[0].pid')" = "102" ] && ok "--stale isolates the candidate" || bad "--stale"

# ── human table ───────────────────────────────────────────────────────────────
T="$(run)"
echo "$T" | grep -q "NOT-YOURS" && ok "table labels foreign agents NOT-YOURS" || bad "NOT-YOURS missing"
echo "$T" | grep -qi "NEVER" && ok "table carries the never-auto-reap warning" || bad "reap warning missing"
echo "$T" | grep -q "stale candidate" && ok "stale footer prompts human inspection" || bad "stale footer"

echo "────────────────────────────────────────"
echo "SUMMARY: $PASS passed, $FAIL failed, $((PASS+FAIL)) total"
[ "$FAIL" -eq 0 ]
