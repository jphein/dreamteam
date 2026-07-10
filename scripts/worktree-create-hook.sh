#!/usr/bin/env bash
# dreamteam — worktree-create-hook.sh: SYNC WorktreeCreate hook adapter (#26).
#
# THE #26 FIX. WorktreeCreate was wired ONLY to team-events.sh — an async event
# logger that returns nothing — so the runtime never got a path and failed with
#   "WorktreeCreate hook failed: hook succeeded but returned no worktree path"
# (hit twice: an OTA build spike + the Model-A build). The agent then couldn't
# isolate. This is the SYNC handler the runtime actually consumes: it provisions
# the worktree via scripts/worktree-provision.sh and prints its ABSOLUTE path —
# and ONLY the path — on stdout. That is exactly the WorktreeCreate command-hook
# contract (docs code.claude.com/docs/en/hooks: "Command hook prints path on
# stdout"; HTTP hooks use hookSpecificOutput.worktreePath — not our case).
#
# #66 — THIS IS NOW THE SOLE WorktreeCreate HOOK. #26 also wired team-events.sh into
# the SAME WorktreeCreate matcher as an async logger, on the assumption that "it writes
# nothing to stdout so the two never compete for the path." That assumption was wrong:
# the runtime consumes exactly ONE WorktreeCreate hook, and with two present it ran/read
# the async logger (which returns no path) instead of this path-producer — so every
# Agent-tool `isolation:worktree` spawn (fork AND normal) failed "hook succeeded but
# returned no worktree path", and no worktree was ever created (verified: zero dream/*
# branches; the sync hook standalone always worked). Fix: team-events.sh is removed from
# the WorktreeCreate matcher in hooks.json — this hook is the only one. To keep the
# WorktreeCreate signal in state/events.log (fleet/crash forensics rely on it), this hook
# now appends that event line itself, best-effort, below.
#
# Contract:
#   stdin  : WorktreeCreate payload JSON. Uses .name (the requested worktree name;
#            confirmed present in captured payloads) and .cwd (a path inside the
#            target repo — worktree-provision resolves the repo toplevel from it,
#            so a subdir cwd is fine). Robust fallbacks for both.
#   stdout : the absolute worktree path, and nothing else (git chatter → stderr).
#   exit   : 0 on success; NON-ZERO fails creation cleanly — a real error the
#            runtime surfaces, instead of the confusing "succeeded but no path".
#
# The worktree is branched off HEAD (default git-worktree semantics; #26's builds
# branch off HEAD) and worktree-provision copies any opt-in git-ignored build
# inputs (its .claude/worktree-copy marker) so the tree compiles out of the box.
set -uo pipefail
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PROV="${DREAMTEAM_PROVISION:-$ROOT/scripts/worktree-provision.sh}"

IN="$(cat 2>/dev/null || true)"
jf() { printf '%s' "$IN" | jq -r "$1 // empty" 2>/dev/null || true; }

# Requested worktree name → sanitize to ONE safe path segment (predictable dir).
NAME="$(jf '.name')"
[ -n "$NAME" ] || NAME="$(jf '.agent_id')"
[ -n "$NAME" ] || NAME="$(jf '.agent_type')"
[ -n "$NAME" ] || NAME="dream-worktree"
# Keep only [A-Za-z0-9_-]: a safe single dir segment AND a valid git ref component
# (drops '.', '/', spaces, etc. — e.g. no "..", which git refuses in branch names).
SAFE="$(printf '%s' "$NAME" | tr -c 'A-Za-z0-9_-' '-' | tr -s '-')"
SAFE="${SAFE#-}"; SAFE="${SAFE%-}"
[ -n "$SAFE" ] || SAFE="dream-worktree"

# Repo location: .cwd from the payload (may be a subdir — provision resolves the
# toplevel), else the hook's own PWD.
REPODIR="$(jf '.cwd')"
[ -n "$REPODIR" ] || REPODIR="$PWD"

BRANCH="dream/$SAFE"

# Preserve the WorktreeCreate signal in the event log (team-events.sh no longer shares
# this matcher — see the #66 note above). Best-effort: must never fail the hook or touch
# stdout (stdout is reserved for the path). Matches team-events' JSONL shape closely
# enough for the fleet/crash forensics that read it.
EVLOG="${DREAMTEAM_EVENTS_LOG:-$ROOT/state/events.log}"
{ mkdir -p "$(dirname "$EVLOG")" 2>/dev/null \
  && printf '{"ts":"%s","event":"WorktreeCreate","who":"%s","path":"%s","via":"worktree-create-hook"}\n' \
       "$(date +%Y-%m-%dT%H:%M:%S 2>/dev/null || echo '?')" "$SAFE" "$REPODIR" >> "$EVLOG"
} 2>/dev/null || true

# Provision off HEAD, naming the dir exactly <SAFE> via the WORKTREE_NAME seam.
# worktree-provision prints the absolute path on stdout (git chatter → stderr) and
# exits non-zero on failure — both propagate here as this is the final command.
exec env WORKTREE_NAME="$SAFE" bash "$PROV" "$SAFE" "$BRANCH" HEAD "$REPODIR"
