# dreamteam per-host config overlay (Sen 2026-11-17). Sourced by every config reader: mem-gate.sh, mem-budget.sh,
# overnight-guarded.sh (dashboard-data.sh mirrors it in Python; tests/test-roster.sh guards that they agree).
#
#   dreamteam_host                 this host's short name, lower-cased, [a-z0-9-] only (DREAMTEAM_HOST overrides; tests/run.sh
#                                  pins it to dreamteam-test so no suite picks up a real host's overlay)
#   dreamteam_config <config.json> the config as JSON on stdout: <config.json> deep-merged (jq `*`) with
#                                  config.<host>.json beside it, when that file exists and parses. An overlay that does not
#                                  parse is ignored: the base (the stricter, shared floors) applies, never a half-read.
#                                  No readable base → "{}" (every reader then uses its baked defaults, as before).
dreamteam_host() {
  local h="${DREAMTEAM_HOST:-$(hostname -s 2>/dev/null || hostname 2>/dev/null)}"
  h="$(printf '%s' "$h" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')"
  printf '%s' "${h:-unknown}"
}
dreamteam_config() {
  local base="$1" ov out
  ov="${base%.json}.$(dreamteam_host).json"
  if [ -f "$ov" ] && out=$(jq -s 'if (.[0] | type) == "object" and (.[1] | type) == "object" then .[0] * .[1] else error("not objects") end' "$base" "$ov" 2>/dev/null) && [ -n "$out" ]; then
    printf '%s\n' "$out"; return 0
  fi
  out=$(jq -c 'if type == "object" then . else {} end' "$base" 2>/dev/null) && [ -n "$out" ] || out='{}'
  printf '%s\n' "$out"
}
