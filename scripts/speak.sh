#!/usr/bin/env bash
# dreamteam — speak.sh: fire-and-forget VOICE seam for attention events.
# Contract:  speak.sh "<text>" [--voice <azure-voice-or-alias>]
#
# Audio channel for RED-tier / scope-pressure attention (team-events.sh). DETACHED
# + hard-timeout so a HOOK NEVER BLOCKS; SILENT NO-OP (exit 0) when python3/tts.py/
# Azure creds are missing or synth fails — attention must never brick a hook.
# Voice: state.py honors AZURE_SPEECH_VOICE (state.py:166, verified) — tts.py has no
# --voice flag — so we pass the resolved id via that env seam. Alias davis/sandman →
# en-US-DavisNeural (Sandman voice); the DragonHD ids 400 in this region (probed
# 2026-07-02) so the working standard-neural id is used; unknown values pass through.
set -uo pipefail
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CFG="${DREAMTEAM_CONFIG:-$ROOT/config.json}"

TEXT="${1:-}"; [ -z "$TEXT" ] && exit 0        # nothing to say → no-op
shift 2>/dev/null || true
VOICE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --voice)   VOICE="${2:-}"; shift 2 2>/dev/null || shift ;;
    --voice=*) VOICE="${1#--voice=}"; shift ;;
    *)         shift ;;
  esac
done

# Master mute (default on). ==false-safe: jq's // treats false as empty, which
# would make speech.enabled=false unreachable (the reuse-gate/scope-attach bug).
[ "$(jq -r 'if .speech.enabled == false then "false" else "true" end' "$CFG" 2>/dev/null || echo true)" = "false" ] && exit 0

# Resolve tts.py: config .speech.ttsPath override → default; expand a leading ~.
TTS="$(jq -r '.speech.ttsPath // empty' "$CFG" 2>/dev/null || true)"
[ -z "$TTS" ] && TTS="$HOME/Projects/speech-to-cli/tts.py"
TTS="${TTS/#\~/$HOME}"

PY="$(command -v python3 2>/dev/null || true)"
[ -n "$PY" ] || exit 0                          # no python → silent no-op
[ -f "$TTS" ] || exit 0                          # no tts.py → silent no-op

# Alias → Azure id. Empty defaults to the Davis attention voice so the seam never
# silently 400s on the region's absent DragonHD default.
case "$VOICE" in
  ""|davis|sandman|Davis|Sandman) VOICE_ID="en-US-DavisNeural" ;;
  *)                              VOICE_ID="$VOICE" ;;
esac

# Fire FULLY DETACHED (new session survives the hook's exit), all fds closed,
# hard-capped at 10s (SIGKILL 2s later). Returns immediately; result ignored.
if command -v setsid >/dev/null 2>&1; then
  setsid env AZURE_SPEECH_VOICE="$VOICE_ID" timeout -k 2 10 "$PY" "$TTS" "$TEXT" </dev/null >/dev/null 2>&1 &
else
  env AZURE_SPEECH_VOICE="$VOICE_ID" timeout -k 2 10 "$PY" "$TTS" "$TEXT" </dev/null >/dev/null 2>&1 &
fi
disown 2>/dev/null || true
exit 0
