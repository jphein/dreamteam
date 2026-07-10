#!/usr/bin/env bash
# dreamteam — local-model.sh: the OPTIONAL ollama lane (issue #16).
#
# A consumer SEAM (not a hook) for offloading work that does NOT need frontier
# reasoning onto local models running on this box's ollama: mechanical bulk
# (rename/format/comment sweeps, commit-message & changelog stubs), cron
# summaries (morning-briefing.sh / self-audit.sh digests), embeddings
# (palace/dreamteam search), and pre-filter triage (which files/logs a real
# agent should read). JP's model ruling (2026-07-01) STANDS — this is NOT a third
# agent-brain tier; agent reasoning stays Fable 5 → latest Opus, never sonnet/
# haiku/local. See the skill's "Local-Model Lane" section for what belongs here
# and the oracle-before-commit verification law.
#
# CONTRACT (deliberately UNLIKE the hook scripts — those always exit 0; this one
# signals availability by EXIT CODE so a caller can fall back to the cloud):
#   local-model.sh [--model M] [--system S] [--timeout N] "prompt"   # generate → stdout
#   printf '%s' "prompt" | local-model.sh [--model M]                # prompt on stdin
#   local-model.sh --embed [--model M] "text"                        # embedding JSON array → stdout
#   local-model.sh --check                                           # human status → STDERR (stdout stays clean)
#   local-model.sh --available                                       # quiet probe (no output at all)
#
#   exit 0  → success; completion / embedding array on STDOUT
#             (or, for --check/--available, the lane is usable)
#   exit 3  → lane UNAVAILABLE: disabled, ollama daemon down, curl/jq missing,
#             model/API error, or empty completion. NOTHING on stdout. The caller
#             MUST fall back to the cloud path.
#   exit 1  → usage error (a generate/embed call with no prompt/text).
#
# The lane is DEFAULT-OFF and degrades to a clean exit-3 no-op whenever ollama is
# absent, so NOTHING in the default path ever depends on ollama being installed.
#
# Config lane (.local in config.json) + env overrides (env WINS over config):
#   enabled    (bool, DEFAULT false)  DREAMTEAM_LOCAL_ENABLED     — only literal true arms it
#   host       (url)                  DREAMTEAM_LOCAL_HOST         default http://localhost:11434
#   model      (str)                  DREAMTEAM_LOCAL_MODEL        default qwen2.5:14b-instruct-q4_K_M
#   embedModel (str)                  DREAMTEAM_LOCAL_EMBED_MODEL  default nomic-embed-text:v1.5
#   timeoutSec (int)                  DREAMTEAM_LOCAL_TIMEOUT      default 120 (per-request curl cap)
set -uo pipefail
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CFG="${DREAMTEAM_CONFIG:-$ROOT/config.json}"
RC_OK=0; RC_USAGE=1; RC_UNAVAIL=3

# ── args ─────────────────────────────────────────────────────────────────────
MODE=generate                       # generate | embed | check | available
MODEL=""; SYSTEM=""; TIMEOUT=""; PROMPT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --embed)     MODE=embed; shift;;
    --check)     MODE=check; shift;;
    --available) MODE=available; shift;;
    --model)     MODEL="${2:-}"; shift 2 2>/dev/null || shift;;
    --model=*)   MODEL="${1#--model=}"; shift;;
    --system)    SYSTEM="${2:-}"; shift 2 2>/dev/null || shift;;
    --system=*)  SYSTEM="${1#--system=}"; shift;;
    --timeout)   TIMEOUT="${2:-}"; shift 2 2>/dev/null || shift;;
    --timeout=*) TIMEOUT="${1#--timeout=}"; shift;;
    -h|--help)   sed -n '2,45p' "$0"; exit 0;;
    --)          shift; PROMPT="${*:-}"; break;;
    *)           PROMPT="$1"; shift;;
  esac
done

# Prompt may arrive on stdin — but only READ it for generate/embed and only when
# stdin is NOT a tty (so an interactive `--check` never blocks on cat).
if [ "$MODE" = generate ] || [ "$MODE" = embed ]; then
  if [ -z "$PROMPT" ] && [ ! -t 0 ]; then PROMPT="$(cat 2>/dev/null || true)"; fi
fi

# ── config / env resolution ──────────────────────────────────────────────────
# Strings/ints only — jq's // is safe for them (they're never boolean-false).
# Falls back to $2 whenever jq yields nothing usable: missing file (jq errors),
# EMPTY/invalid JSON (jq exits 0 but prints nothing — the `//` default never
# fires on zero input), or an empty/null value. More defensive than mem-budget's
# getcfg, which relies on jq erroring; an empty config file would slip past that.
getcfg() {
  local v; v="$(jq -r --arg k "$1" --arg d "$2" '.local[$k] // $d' "$CFG" 2>/dev/null)"
  [ -n "$v" ] && printf '%s' "$v" || printf '%s' "$2"
}
have() { command -v "$1" >/dev/null 2>&1; }

# enabled — env wins; else config. Deliberately AVOIDS jq's `//` (which treats
# false as null, making `.local.enabled // true` un-disableable): only a literal
# `true` arms the lane, so absent/null/false all stay OFF (the ==false-safe idiom
# speak.sh uses, mirrored for a default-OFF switch).
enabled() {
  if [ -n "${DREAMTEAM_LOCAL_ENABLED:-}" ]; then
    case "$DREAMTEAM_LOCAL_ENABLED" in true|1|yes|on) return 0;; *) return 1;; esac
  fi
  [ "$(jq -r 'if .local.enabled == true then "1" else "0" end' "$CFG" 2>/dev/null || echo 0)" = "1" ]
}

HOST="${DREAMTEAM_LOCAL_HOST:-$(getcfg host http://localhost:11434)}"; HOST="${HOST%/}"
if [ -z "$MODEL" ]; then
  if [ "$MODE" = embed ]; then
    MODEL="${DREAMTEAM_LOCAL_EMBED_MODEL:-$(getcfg embedModel nomic-embed-text:v1.5)}"
  else
    MODEL="${DREAMTEAM_LOCAL_MODEL:-$(getcfg model qwen2.5:14b-instruct-q4_K_M)}"
  fi
fi
[ -z "$TIMEOUT" ] && TIMEOUT="${DREAMTEAM_LOCAL_TIMEOUT:-$(getcfg timeoutSec 120)}"
TIMEOUT="${TIMEOUT//[!0-9]/}"; [ -n "$TIMEOUT" ] || TIMEOUT=120   # curl --max-time needs an int

# daemon_up — is an ollama actually answering at $HOST? Requires a /api/tags
# response that parses as ollama's shape. curl-transport failure (daemon down) or
# absent curl/jq → false. Bounded so a hung daemon can't stall a caller.
daemon_up() {
  have curl && have jq || return 1
  curl -s --connect-timeout 2 --max-time 4 "$HOST/api/tags" 2>/dev/null \
    | jq -e 'has("models")' >/dev/null 2>&1
}

# ── probe modes: --check (verbose→stderr) / --available (silent) ──────────────
if [ "$MODE" = check ] || [ "$MODE" = available ]; then
  say() { [ "$MODE" = check ] && printf '%s\n' "$1" >&2 || true; }   # NEVER stdout
  if ! enabled;               then say "local lane: DISABLED (.local.enabled is not true — opt in to arm)"; exit $RC_UNAVAIL; fi
  if ! have curl || ! have jq; then say "local lane: UNAVAILABLE (curl/jq missing)"; exit $RC_UNAVAIL; fi
  if ! daemon_up;             then say "local lane: DOWN (no ollama responding at $HOST — 'ollama serve'?)"; exit $RC_UNAVAIL; fi
  models="$(curl -s --max-time 4 "$HOST/api/tags" 2>/dev/null | jq -r '.models[]?.name' 2>/dev/null || true)"
  if printf '%s\n' "$models" | grep -qxF "$MODEL"; then mp="present"; else mp="NOT pulled → 'ollama pull $MODEL'"; fi
  say "local lane: READY  host=$HOST  model=$MODEL ($mp)"
  exit $RC_OK
fi

# ── generate / embed ─────────────────────────────────────────────────────────
enabled || exit $RC_UNAVAIL                          # disabled → clean no-op, caller falls back
have curl && have jq || exit $RC_UNAVAIL             # toolchain absent → fall back
[ -n "$PROMPT" ] || { printf 'local-model.sh: no prompt/text supplied\n' >&2; exit $RC_USAGE; }
daemon_up || exit $RC_UNAVAIL                        # ollama absent/down → fall back

if [ "$MODE" = embed ]; then
  body="$(jq -cn --arg m "$MODEL" --arg p "$PROMPT" '{model:$m, prompt:$p}')"
  resp="$(curl -s --connect-timeout 3 --max-time "$TIMEOUT" "$HOST/api/embeddings" --data-binary "$body" 2>/dev/null)" || exit $RC_UNAVAIL
  emb="$(printf '%s' "$resp" | jq -c '.embedding // empty' 2>/dev/null || true)"
  [ -n "$emb" ] || exit $RC_UNAVAIL
  printf '%s\n' "$emb"
  exit $RC_OK
fi

# generate — `system` is optional (top-level ollama param); stream off for one shot.
if [ -n "$SYSTEM" ]; then
  body="$(jq -cn --arg m "$MODEL" --arg p "$PROMPT" --arg s "$SYSTEM" '{model:$m, prompt:$p, system:$s, stream:false}')"
else
  body="$(jq -cn --arg m "$MODEL" --arg p "$PROMPT" '{model:$m, prompt:$p, stream:false}')"
fi
resp="$(curl -s --connect-timeout 3 --max-time "$TIMEOUT" "$HOST/api/generate" --data-binary "$body" 2>/dev/null)" || exit $RC_UNAVAIL
out="$(printf '%s' "$resp" | jq -r '.response // empty' 2>/dev/null || true)"
[ -n "$out" ] || exit $RC_UNAVAIL                    # empty/absent completion → fall back
printf '%s\n' "$out"
exit $RC_OK
