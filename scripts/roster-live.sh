#!/usr/bin/env bash
# dreamteam — roster-live.sh: the UNIFIED REALTIME agent roster (issue #41).
#
# WHAT / WHY
#   JP's directive: make the roster "really good and realtime" — names, panes, and
#   status accurate and LIVE. The trap it replaces: fleet.sh's LIVE column shows
#   STALE latched hook-stamps (an agent that has long gone idle still reads
#   "working@1488m"), because it trusts a push-stamp instead of the screen. This view
#   trusts the LIVE PANE, always.
#
#   It COMBINES three layers, one responsibility each (Oracle #41 — the three
#   overlapping pane-resolvers are collapsed onto pid-ancestry):
#     • NAME + liveness            ← the harness team config (via agent-activity.sh)
#     • PANE  (pid-ancestry)       ← agent-activity.sh's unified resolver (pane-peek #32
#                                     technique: all-sockets, PPid walk, closest-wins —
#                                     NOT the collision-prone @handle name-match)
#     • STATUS (pane-trusted)      ← agent-activity.sh's verdict:
#                                     ACTIVE / IDLE / queued / stale-isActive / no-pane / dead
#     • ASSIGNMENT overlay         ← scratch/<team>/roster.md (issue / branch / task)
#
#   agent-activity.sh is the single status+pane ENGINE; this script adds the human
#   assignment overlay and the presentation. No pane-resolution logic is duplicated
#   here — it reads the engine's JSON.
#
# --team requirement is MODE-DEPENDENT. A bare call FIRST resolves THIS session's own
#   team from CLAUDE_CODE_SESSION_ID (dreamteam_current_team, lib.sh) — deterministic, so
#   it's the correct answer, not a guess. Only when that is unresolvable (no session env /
#   no matching config) does the fallback fire — and the fallback is the "smol-team bug":
#   the most-recently-modified team config, usually the WRONG team on a multi-team host.
#   The split at that point:
#     • --json + unresolvable → ERROR on stderr + EXIT 22. A machine consumer (Nyx kills,
#       dashboards, gm peek) never sees a stderr warning, so fail-closed rather than
#       silently feed wrong-team data (the R4 footgun; personas #43 mandate --team). NOTE:
#       an in-session --json call now SUCCEEDS via the session-team resolve — the 22 is
#       reserved for the genuinely-unidentifiable case.
#     • human + unresolvable → warn loudly on stderr, then PROCEED against the newest
#       team. The operator SEES the warning, so keep the interactive convenience.
#
# Usage: roster-live.sh [--team NAME] [--json] [--roster-md PATH] [--no-overlay]
#   --team NAME      team config to resolve against (defaults to THIS session's own team;
#                    REQUIRED with --json only when the session team can't be resolved).
#   --json           machine output (contract for manager roles / dashboards).
#   --roster-md PATH explicit assignment-overlay file (else auto-discovered by team).
#   --no-overlay     skip the roster.md overlay entirely (pane-truth only).
# Seams (tests): DREAMTEAM_AGENT_ACTIVITY (status engine), DREAMTEAM_ROSTER_MD
#   (overlay path), DREAMTEAM_PROJECTS_DIR (overlay auto-discovery root). The engine's
#   own seams (DREAMTEAM_TEAMS_DIR / _TMUX_DIR / _PROC) are inherited from the env.
set -uo pipefail
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
ENGINE="${DREAMTEAM_AGENT_ACTIVITY:-$ROOT/scripts/agent-activity.sh}"
PROJECTS_DIR="${DREAMTEAM_PROJECTS_DIR:-$HOME/.claude/projects}"

TEAM=""; FMT="human"; ROSTER_MD="${DREAMTEAM_ROSTER_MD:-}"; OVERLAY=1
while [ $# -gt 0 ]; do
  case "$1" in
    --team)       TEAM="${2:-}"; shift 2;;
    --json)       FMT="json"; shift;;
    --roster-md)  ROSTER_MD="${2:-}"; shift 2;;
    --no-overlay) OVERLAY=0; shift;;
    -h|--help)    sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *)            shift;;
  esac
done

if [ -z "$TEAM" ]; then
  # First, prefer THIS session's OWN team — deterministic via CLAUDE_CODE_SESSION_ID, so
  # it's the correct answer, not the newest-mtime guess. Resolved ⇒ use it SILENTLY (no
  # warning: there's nothing wrong to warn about). The mode-split below only fires when
  # the session team is genuinely unidentifiable (no session env / no matching config).
  # shellcheck source=/dev/null
  . "$ROOT/scripts/lib.sh" 2>/dev/null || true
  if declare -F dreamteam_current_team >/dev/null 2>&1; then
    TEAM="$(dreamteam_current_team 2>/dev/null || true)"
  fi
fi
if [ -z "$TEAM" ]; then
  if [ "$FMT" = "json" ]; then
    # machine consumers never see a stderr warning → fail-closed (the R4 footgun)
    echo "roster-live: --team <session> is REQUIRED with --json — this session's team could not be" >&2
    echo "             resolved and bare selection = newest-mtime = the smol-team bug. Refusing to feed wrong-team data." >&2
    exit 22                                        # client error: do NOT proceed
  fi
  # human/interactive: the operator SEES this, so warn loudly but proceed for convenience
  echo "roster-live: ⚠ no --team and this session's team is unresolvable — using the newest team" >&2
  echo "             config, often the WRONG team in a multi-team session (the smol-team bug). Pass --team NAME." >&2
fi

ACT_JSON="$(bash "$ENGINE" ${TEAM:+--team "$TEAM"} --json 2>/dev/null || true)"
[ -n "$ACT_JSON" ] || ACT_JSON='[]'
[ "$OVERLAY" = "1" ] || ROSTER_MD="__NONE__"     # sentinel: overlay explicitly disabled

ACT_JSON="$ACT_JSON" ROSTER_MD="$ROSTER_MD" PROJECTS_DIR="$PROJECTS_DIR" \
TEAM="$TEAM" FMT="$FMT" python3 <<'PY'
import json, os, sys, glob, re

act = json.loads(os.environ.get("ACT_JSON") or "[]")
team_arg = os.environ.get("TEAM") or ""
fmt = os.environ.get("FMT") or "human"
roster_md = os.environ.get("ROSTER_MD") or ""
projects_dir = os.environ.get("PROJECTS_DIR") or ""

# --json requires --team (the bash guard exits 22 there); in human mode a bare call
# proceeds against the newest team, whose name we recover from the engine rows here.
team = team_arg or (act[0].get("team") if act else "") or ""

def normkey(s):
    return re.sub(r"\s+", " ", (s or "").strip().lower())

# ── locate the assignment overlay (roster.md) ────────────────────────────────
overlay_path = None
if roster_md == "__NONE__":
    overlay_path = None                                    # --no-overlay
elif roster_md:
    overlay_path = roster_md if os.path.exists(roster_md) else None
elif team and projects_dir:
    # scratch/<team>/roster.md lives under the OWNING project's mangled projects dir;
    # the team name (session-xxxx) is unique, so a cross-project glob is safe. Newest wins.
    cand = glob.glob(os.path.join(projects_dir, "*", "scratch", team, "roster.md"))
    cand = [c for c in cand if os.path.exists(c)]
    if cand:
        overlay_path = max(cand, key=os.path.getmtime)

# ── parse the FIRST markdown table in the overlay → name/dream → {issue,branch,task} ──
def parse_overlay(path):
    idx = {}
    try:
        raw = open(path, encoding="utf-8").read().splitlines()
    except Exception:
        return idx, None
    # find a header row followed by a |---|---| separator
    rows = []
    header = None
    updated = None
    for i, ln in enumerate(raw):
        s = ln.strip()
        if updated is None and s.lower().startswith("updated:"):
            updated = s.split(":", 1)[1].strip()
        if header is None:
            if s.startswith("|") and i + 1 < len(raw):
                sep = raw[i + 1].strip()
                if sep.startswith("|") and set(sep) <= set("|-: "):
                    header = [c.strip() for c in s.strip("|").split("|")]
            continue
        # collecting data rows until the table ends
        if s.startswith("|"):
            if set(s) <= set("|-: "):                      # a stray separator inside — skip
                continue
            rows.append([c.strip() for c in s.strip("|").split("|")])
        elif s == "":
            continue
        else:
            break
    if not header:
        return idx, updated

    # roster.md is human-maintained and its columns VARY between sessions (seen in the
    # wild: "Agent ID|Dream Name|Role|Issue/PR|Worktree|Status|Notes",
    # "Agent|Role|Unit|Worktree / Branch|Status|Notes" where Role holds the DREAM name,
    # and "Agent|Dream Name|Task|Output|Status"). So the parse is deliberately TOLERANT
    # best-effort: it locates columns by header keyword and issue by a #NNN scan. The
    # roster's core truth (name/pane/status) never depends on it — this only enriches.
    def find(*needles, exclude=()):
        for j, h in enumerate(header):
            hl = h.lower()
            if any(x in hl for x in exclude):
                continue
            if any(n in hl for n in needles):
                return j
        return None

    c_name  = find("agent id", "agent")
    if c_name is None:
        c_name = 0
    c_dream  = find("dream", exclude=("agent",))          # (explicit None checks: a valid
    if c_dream is None:                                   #  column index of 0 is falsy)
        c_dream = find("name", exclude=("agent",))
    c_issue  = find("issue", "pr")
    c_branch = find("branch", "worktree")
    c_unit   = find("unit"); c_task = find("task"); c_assign = find("assignment")
    c_role   = find("role"); c_notes = find("note"); c_status = find("status")

    # task columns, in priority order. "Role" is ambiguous: when there is NO dedicated
    # dream/name column but there IS a unit/task column, "Role" actually holds the DREAM
    # name (format 2) → use it for dream, NOT task. Otherwise "Role" is a real role and a
    # reasonable task descriptor (format 1).
    task_cols = [c for c in (c_unit, c_task, c_assign) if c is not None]
    if c_dream is None and c_role is not None and (c_unit is not None or c_task is not None):
        c_dream = c_role
    elif c_role is not None:
        task_cols.append(c_role)

    def cell(r, j):
        if j is None or j >= len(r): return ""
        return r[j].strip().strip("`").strip()

    def first_nonempty(r, cols):
        for j in cols:
            v = cell(r, j)
            if v and v not in ("-", "—"): return v
        return ""

    for r in rows:
        name = cell(r, c_name)
        if not name:
            continue
        issue = cell(r, c_issue)
        if not re.search(r"#\d+", issue):                  # no explicit issue column value →
            found = []                                     # scan notes/unit/status for #NNN
            for cc in (cell(r, c_issue), cell(r, c_unit), cell(r, c_notes), cell(r, c_status)):
                for tok in re.findall(r"#\d+", cc):
                    if tok not in found: found.append(tok)
            issue = ",".join(found[:2])
        entry = {
            "issue":  issue,
            "branch": cell(r, c_branch),
            "task":   first_nonempty(r, task_cols),
            "dream":  cell(r, c_dream),
        }
        idx.setdefault(normkey(name), entry)
        dk = normkey(entry["dream"])
        if dk:
            idx.setdefault(dk, entry)
    return idx, updated

overlay, overlay_updated = ({}, None)
if overlay_path:
    overlay, overlay_updated = parse_overlay(overlay_path)

# ── join: agent (pane-truth) ⟕ overlay (assignment) ──────────────────────────
def status_base(r):
    v = r.get("verdict") or ""
    if v.startswith("DEAD"): return "DEAD"
    if "no-pane" in v:       return "no-pane"
    ps = r.get("pane_state")
    if ps == "ACTIVE" or v.startswith("ACTIVE"): return "ACTIVE"
    if ps == "IDLE"   or v.startswith("IDLE"):   return "IDLE"
    return (v.split() or ["?"])[0]

merged = []
for r in act:
    ov = overlay.get(normkey(r.get("name"))) or {}
    flags = ""
    if "⚠" in (r.get("verdict") or ""): flags += " ⚠"
    if r.get("queued"): flags += " ⌨"
    merged.append({
        "name":   r.get("name"),
        "team":   r.get("team"),
        "status": status_base(r),
        "flags":  flags.strip(),
        "verdict": r.get("verdict"),
        "pane":   r.get("pane"),
        "pane_state": r.get("pane_state"),
        "queued": bool(r.get("queued")),
        "isActive": r.get("isActive"),
        "pid":    r.get("pid"),
        "dream":  ov.get("dream") or "",
        "issue":  ov.get("issue") or "",
        "branch": ov.get("branch") or "",
        "task":   ov.get("task") or "",
    })

if fmt == "json":
    print(json.dumps({
        "team": team or None,
        "overlay": overlay_path,
        "overlayUpdated": overlay_updated,
        "counts": {
            "active": sum(1 for m in merged if m["status"] == "ACTIVE"),
            "idle":   sum(1 for m in merged if m["status"] == "IDLE"),
            "dead":   sum(1 for m in merged if m["status"] == "DEAD"),
            "other":  sum(1 for m in merged if m["status"] not in ("ACTIVE","IDLE","DEAD")),
        },
        "agents": merged,
    }, indent=2))
    sys.exit(0)

# ── human table ──────────────────────────────────────────────────────────────
if not merged:
    print("no live team members found" + (" (team '%s')" % team if team else ""))
    sys.exit(0)

def statcell(m):
    return (m["status"] + (" " + m["flags"] if m["flags"] else "")).strip()

def clip(s, n):
    s = s or "-"
    return s if len(s) <= n else s[: n - 1] + "…"

cols = [
    ("AGENT",  lambda m: m["name"] or "?"),
    ("STATUS", statcell),
    ("PANE",   lambda m: m["pane"] or "-"),
    ("ISSUE",  lambda m: clip(m["issue"], 12)),
    ("BRANCH", lambda m: clip(m["branch"], 46)),
    ("TASK",   lambda m: clip(m["task"], 40)),
]
widths = []
for title, fn in cols:
    w = max([len(title)] + [len(fn(m)) for m in merged])
    widths.append(w)

n = len(merged)
na = sum(1 for m in merged if m["status"] == "ACTIVE")
ni = sum(1 for m in merged if m["status"] == "IDLE")
nd = sum(1 for m in merged if m["status"] == "DEAD")
src = overlay_path if overlay_path else ("(--no-overlay)" if roster_md == "__NONE__" else "none")
print("dreamteam realtime roster — team '%s'  (%d members: %d active, %d idle, %d dead)"
      % (team or "?", n, na, ni, nd))
print("  status trusts the LIVE pane · pane via pid-ancestry · overlay: %s%s"
      % (src, ("  (updated %s)" % overlay_updated) if overlay_updated else ""))

def render(vals):
    return "  " + "  ".join(v.ljust(widths[i]) for i, v in enumerate(vals))

print(render([t for t, _ in cols]))
for m in merged:
    print(render([fn(m) for _, fn in cols]))
if any(m["flags"] for m in merged):
    print("  legend: ⚠ = pane disagrees with config isActive · ⌨ = input queued")
PY
