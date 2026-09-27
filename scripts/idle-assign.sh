#!/usr/bin/env bash
# dreamteam — idle-assign: the moment an agent goes idle or finishes, hand the lead
# that agent's HELD CONTEXT and the open work that best matches it, so the agent is
# reused instead of a new one being spawned.
#
# JP, 2026-09-26: "reuse your idle ones instead of spawning new ones … make a hook
# that anytime an agent goes idle or finished you assign it work that matches the
# context it holds." idle-agent-roster.sh (~/.claude/hooks) already blocks spawns and
# reminds on the NEXT user prompt; this fires at the idle EVENT itself, with a ranked
# match, so the assignment happens now, not a turn later.
#
# Modes (hooks/hooks.json wires the first two):
#   context   PostToolUse[Agent|SendMessage]  record what the agent was given — the spawn
#                                             prompt or the last SendMessage — as its held
#                                             context (state: ~/.claude/state/agent-context.json)
#   idle      TeammateIdle | SubagentStop     emit a systemMessage: "<name> is free. Holds:
#                                             <context>. Best-fit open work: …" ranked by
#                                             keyword/cwd affinity against the backlog.
#                                             Deduped: once per agent per idle stretch (a
#                                             new `context` record re-arms it).
#   backlog   add "<text>" | list | done N    maintain the open-work list the ranker reads.
#
# Backlog file: $CLAUDE_PROJECT_DIR/scratch/dreamteam/backlog.md when that dir exists,
# else ~/.claude/state/dreamteam-backlog.md. One item per line, "- [project] text".
# An empty backlog still emits the free-agent line (the lead has its own list) —
# the message is the mechanism; the ranking is the convenience.
set -u
mode=${1:-idle}
state_dir="$HOME/.claude/state"; mkdir -p "$state_dir"
ctx_file="$state_dir/agent-context.json"; [ -s "$ctx_file" ] || echo '{}' > "$ctx_file"
proj="${CLAUDE_PROJECT_DIR:-$PWD}"
if [ -d "$proj/scratch/dreamteam" ]; then backlog="$proj/scratch/dreamteam/backlog.md"
else backlog="$state_dir/dreamteam-backlog.md"; fi
touch "$backlog"

case "$mode" in
  backlog)
    sub=${2:-list}
    case "$sub" in
      add)  shift 2; printf -- '- %s\n' "$*" >> "$backlog"; echo "added → $backlog";;
      done) n=${3:?line number}; sed -i "${n}s/^- /- [done $(date +%F)] /" "$backlog"; echo "marked line $n done";;
      *)    echo "backlog: $backlog"; grep -nE '^- ' "$backlog" | grep -v '\[done ' || echo "  (empty)";;
    esac
    exit 0;;
  context|idle) ;;
  *) echo "usage: idle-assign.sh context|idle|backlog [add|list|done]" >&2; exit 22;;
esac

input=$(cat 2>/dev/null || true)
python3 - "$mode" "$ctx_file" "$backlog" "$input" <<'PY'
import json, sys, time, re, fcntl
mode, ctx_path, backlog_path, raw = sys.argv[1:5]
try: ev = json.loads(raw) if raw.strip() else {}
except Exception: ev = {}
now = time.time()

with open(ctx_path, "r+") as f:
    fcntl.flock(f, fcntl.LOCK_EX)
    try: ctx = json.load(f)
    except Exception: ctx = {}
    # A valid-JSON state file of the wrong shape ([], "x", {"w1": "str"}) used to crash every
    # Agent/SendMessage call (AttributeError). Treat anything but a dict of dicts as empty.
    if not isinstance(ctx, dict): ctx = {}
    ctx = {k: v for k, v in ctx.items() if isinstance(v, dict) and isinstance(v.get("ts", 0), (int, float)) and now - v.get("ts", 0) < 24 * 3600}

    if mode == "context":
        tool = ev.get("tool_name") or ""
        ti = ev.get("tool_input") or {}
        if tool == "Agent":
            name = ti.get("name") or ""
            text = ti.get("prompt") or ""
            kind = "spawn"
        else:  # SendMessage
            name = (ti.get("to") or "").split("@")[0]
            msg = ti.get("message")
            text = msg if isinstance(msg, str) else ""
            kind = "assignment"
        if name and text and name != "main":
            summary = ti.get("summary") or ti.get("description") or ""
            # drop the gate preamble so the held context is the task, not the excuse
            text = re.sub(r"^(IDLE-CHECKED|FRESH-SPAWN):[^\n]*\n?", "", text, flags=re.M).strip()
            ctx[name] = {"ts": now, "kind": kind, "summary": summary[:120],
                         "text": text[:600], "cwd": ti.get("cwd") or "", "armed": True}
        f.seek(0); f.truncate(); json.dump(ctx, f)
        sys.exit(0)

    # mode == idle
    # Only a TEAMMATE can be reused. A one-shot subagent's SubagentStop carries no teammate name
    # (only agent_id/agent_type), and a stopped one-shot is gone, so announcing it as "free" was
    # a false reuse cue.
    name = ev.get("teammate_name") or ""
    if not name and ev.get("agent_id") and "@" in str(ev["agent_id"]):
        cand = str(ev["agent_id"]).split("@")[0]
        # accept only if some team config lists it (read-only)
        import glob, os
        for cfg in glob.glob(os.path.expanduser("~/.claude/teams/*/config.json")):
            try:
                if cand in {m.get("name") for m in json.load(open(cfg)).get("members", []) if isinstance(m, dict)}:
                    name = cand; break
            except Exception:
                pass
    if not name or name == "team-lead":
        sys.exit(0)
    held = ctx.get(name)
    if held and not held.get("armed", True):
        f.seek(0); f.truncate(); json.dump(ctx, f); sys.exit(0)   # already announced this stretch
    if held: held["armed"] = False
    f.seek(0); f.truncate(); json.dump(ctx, f)

STOP = set("the and for with that this from into your then them they have will were been are was its our you not but all any can may per each one two via".split())
def toks(s): return {w for w in re.findall(r"[a-z0-9_./#-]{3,}", (s or "").lower()) if w not in STOP}

ctx_text = ""
if held:
    ctx_text = (held.get("summary") or "") + " " + (held.get("text") or "")
held_toks = toks(ctx_text) | toks(name.replace("-", " "))

items = []
try:
    for i, line in enumerate(open(backlog_path), 1):
        if line.startswith("- ") and "[done " not in line[:12]:
            items.append((i, line[2:].strip()))
except Exception:
    pass
ranked = []
for i, text in items:
    shared = held_toks & toks(text)
    score = min(len(shared) * 5, 60)
    m = re.match(r"\[([^\]]+)\]", text)
    if m and held and m.group(1).lower() in ctx_text.lower(): score += 40
    ranked.append((score, i, text, sorted(shared)[:5]))
ranked.sort(key=lambda r: (-r[0], r[1]))

what = ev.get("hook_event_name") or "idle"
lines = [f"🟢 IDLE-ASSIGN: {name} is free ({what}). Reuse it — do not spawn."]
if held:
    when = int((now - held["ts"]) / 60)
    lines.append(f"   holds: [{held['kind']} {when} min ago] {held.get('summary') or held.get('text','')[:140]}")
else:
    lines.append("   holds: (no recorded context — check ~/.claude/teams/*/config.json or its last report)")
if ranked:
    lines.append("   best-fit open work (backlog %s):" % backlog_path)
    for score, i, text, shared in ranked[:3]:
        tag = f"score {score}" + (f", kw {','.join(shared)}" if shared else "")
        lines.append(f"     {i}. {text[:140]}  [{tag}]")
    lines.append("   → SendMessage the top match now, or say in one line why none fits.")
else:
    lines.append(f"   backlog empty ({backlog_path}) — assign from your own list now, or `idle-assign.sh backlog add \"[project] task\"`.")
print(json.dumps({"systemMessage": "\n".join(lines)}))
PY
