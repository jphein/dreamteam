#!/usr/bin/env bash
# dreamteam — probe: what the lane output style does to OUTPUT TOKENS (by hand, NOT under tests/run.sh: it starts
# real Claude Code sessions and spends tokens).
#
#   tests/probe-lane-tokens.sh [RUNS]        RUNS per prompt and condition, default 2
#   PROBE_MODEL=<model id>                   the model both conditions are pinned to (default claude-fable-5-2,
#                                            what the lanes run)
#
# Three fixed prompts, each a small piece of real work in a fresh copy of a fixture directory:
#   fix     a failing test: find the bug, fix it, run the test, report
#   explain what a script does and one exit code
#   fail    a build that fails: the failure must be reported whole
# Two conditions. Same prompts, the SAME PINNED MODEL, the same plugin tree (this checkout), each run a new
# `claude -p` session in a pane of a THROWAWAY tmux server, so the role is taken from the pane as in production:
#   before  in the tmux session `fx-plain`, which the probe's config does NOT list: no lane style
#   after   in the tmux session `fx-probe`, which it lists: the SessionStart hook injects the lane style
# A run COUNTS only if the hook's own log agrees with its condition for that run's session id: an `after` run
# without an injection line, or a `before` run with one, is printed as INVALID and left out of the medians. So
# two unstyled conditions can never be reported as a result.
# Printed per run: the model the session reports, output tokens (from the session's own usage report), lines and
# characters of the final message, and what the report kept. Then the medians. Nothing is asserted about the
# size of the saving: this prints numbers for a person.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNS="${1:-2}"; [[ "$RUNS" =~ ^[1-9]$ ]] || { echo "usage: probe-lane-tokens.sh [RUNS 1-9]" >&2; exit 22; }
MODEL="${PROBE_MODEL:-claude-fable-5-2}"; [[ "$MODEL" =~ ^[A-Za-z0-9._-]{3,60}$ ]] || { echo "PROBE_MODEL is not a plain model id" >&2; exit 22; }
command -v claude >/dev/null && command -v jq >/dev/null && command -v tmux >/dev/null || { echo "needs claude, jq and tmux" >&2; exit 2; }
T="$(mktemp -d)"; S="$T/sock"; trap 'tmux -S "$S" kill-server 2>/dev/null; rm -rf -- "$T"' EXIT
mkdir -p "$T/fx" "$T/state"
printf '{"laneStyle":{"enabled":true,"lanes":["fx-probe"],"lead":[],"neverHosts":[]}}\n' > "$T/config.json"
LOGF="$T/lane.log"; : > "$LOGF"
ENVS="DREAMTEAM_CONFIG=$T/config.json DREAMTEAM_LANE_STYLE_LOG=$LOGF LEAD_WATCHDOG_STATE=$T/state"
cat > "$T/fx/calc.py" <<'EOF'
def mean(values):
    """Arithmetic mean of a non-empty list."""
    return sum(values) / (len(values) - 1)
EOF
cat > "$T/fx/test_calc.py" <<'EOF'
from calc import mean
assert mean([2, 4, 6]) == 4, mean([2, 4, 6])
assert mean([5]) == 5
print("ok")
EOF
cat > "$T/fx/scan.sh" <<'EOF'
#!/usr/bin/env bash
# count the files under a directory that are larger than a size, by extension
set -uo pipefail
dir=${1:?dir}; min=${2:-1024}
[ -d "$dir" ] || { echo "scan: $dir is not a directory" >&2; exit 3; }
find "$dir" -type f -size +"${min}c" -printf '%f\n' | awk -F. 'NF > 1 {n[$NF]++} NF == 1 {n["(none)"]++} END {for (e in n) print n[e], e}' | sort -rn
EOF
cat > "$T/fx/build.sh" <<'EOF'
#!/usr/bin/env bash
echo "compiling 3 units"
echo "unit a: ok"
echo "unit b: error: undefined reference to 'frobnicate' (b.c:41)" >&2
echo "unit c: skipped"
echo "build FAILED: 1 error, 1 unit skipped" >&2
exit 2
EOF
chmod +x "$T/fx/scan.sh" "$T/fx/build.sh"
printf '%s' 'The test in this directory fails (python3 test_calc.py). Find the bug, fix it, run the test, and report.' > "$T/p-fix"
printf '%s' 'What does scan.sh in this directory do, and what is its exit code when the directory argument does not exist?' > "$T/p-explain"
printf '%s' 'Run ./build.sh in this directory and report the outcome. Do not try to fix anything.' > "$T/p-fail"

run() {  # run <condition> <prompt name> <n>
  local cond=$1 pn=$2 n=$3 d="$T/$1-$2-$3" s o="$T/$1-$2-$3.json"
  cp -r "$T/fx" "$d"; [ "$cond" = after ] && s=fx-probe || s=fx-plain
  tmux -S "$S" has-session -t "=$s" 2>/dev/null || env -u TMUX -u TMUX_PANE tmux -S "$S" new-session -d -s "$s" -x 200 -y 50 -c "$T" "bash --norc --noprofile"
  sleep 0.4; rm -f "$o.done"
  tmux -S "$S" send-keys -t "=$s:" -l "cd $d && env $ENVS claude --plugin-dir $ROOT --model $MODEL --dangerously-skip-permissions --output-format json -p \"\$(cat $T/p-$pn)\" > $o 2>/dev/null; touch $o.done"
  tmux -S "$S" send-keys -t "=$s:" Enter
  for _ in $(seq 1 420); do [ -e "$o.done" ] && break; sleep 1; done
  local tok res lines chars model sid inj keep="" valid=yes
  tok=$(jq -r '.usage.output_tokens // "?"' "$o" 2>/dev/null) || tok="?"
  res=$(jq -r '.result // ""' "$o" 2>/dev/null); sid=$(jq -r '.session_id // ""' "$o" 2>/dev/null)
  model=$(jq -r '(.modelUsage // {}) | keys | join(",")' "$o" 2>/dev/null)
  inj=0; [ -n "$sid" ] && inj=$(grep -c " fx-probe $sid\$" "$LOGF" || true)
  [ "$cond" = after ] && [ "$inj" -lt 1 ] && valid="INVALID(no injection logged for this session)"
  [ "$cond" = before ] && { [ -z "$sid" ] || grep -q " $sid\$" "$LOGF"; } && valid="INVALID(an injection was logged, or no session id)"
  case ",$model," in *",$MODEL,"*) : ;; *) valid="INVALID(the session reports model '$model', not $MODEL)" ;; esac
  [[ "$tok" =~ ^[0-9]+$ ]] || valid="INVALID(no token count)"
  lines=$(printf '%s\n' "$res" | grep -c . || true); chars=${#res}
  printf '%s\n' "$res" > "$T/$cond-$pn-$n.txt"
  grep -q 'Insight' <<<"$res" && keep="$keep insight-block:yes" || keep="$keep insight-block:no"
  [ "$pn" = explain ] || { grep -q 'Not verified' <<<"$res" && keep="$keep not-verified:yes" || keep="$keep not-verified:no"; }
  [ "$pn" = fail ] && { grep -q "frobnicate" <<<"$res" && grep -q "b.c:41" <<<"$res" && keep="$keep failure-whole:yes" || keep="$keep failure-whole:NO"; }
  [ "$pn" = fix ] && { (cd "$d" && python3 test_calc.py > /dev/null 2>&1) && keep="$keep test-passes:yes" || keep="$keep test-passes:NO"; }
  printf '%-7s %-8s run %s  output_tokens %6s  lines %3s  chars %5s  model %s  injected %s  session %s  %s %s\n' "$cond" "$pn" "$n" "$tok" "$lines" "$chars" "$model" "$inj" "${sid:-?}" "$keep" "$([ "$valid" = yes ] || echo "$valid")"
  [ "$valid" = yes ] && echo "$cond $pn $tok" >> "$T/numbers"
}
echo "probe: $RUNS run(s) per prompt and condition; model pinned to $MODEL; plugin tree $ROOT ($(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null)); $(claude --version 2>/dev/null | head -1); $(hostname -s) $(date '+%F %T')"
: > "$T/numbers"
for pn in fix explain fail; do for n in $(seq 1 "$RUNS"); do run before "$pn" "$n"; run after "$pn" "$n"; done; done
med() { awk -v c="$1" -v p="$2" '$1 == c && $2 == p {print $3}' "$T/numbers" | sort -n | awk '{a[NR]=$1} END {if (NR) print (NR % 2 ? a[(NR+1)/2] : int((a[NR/2] + a[NR/2+1]) / 2)); else print "?"}'; }
echo "── medians of the VALID runs (output tokens) ──"
for pn in fix explain fail; do
  b=$(med before "$pn"); a=$(med after "$pn")
  if [[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[1-9][0-9]*$ ]]; then printf '%-8s before %6s  after %6s  (%s%%)\n' "$pn" "$b" "$a" "$(( (a - b) * 100 / b ))"; else printf '%-8s before %s after %s (not enough valid runs)\n' "$pn" "$b" "$a"; fi
done
echo "valid runs: $(wc -l < "$T/numbers") of $((RUNS * 6)); injections logged by the hook: $(wc -l < "$LOGF")"
echo "── one 'after' report, as written (fix, run 1) ──"; cat "$T/after-fix-1.txt" 2>/dev/null
