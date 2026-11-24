#!/usr/bin/env bash
# dreamteam — probe: what the lane output style does to OUTPUT TOKENS (by hand, NOT under tests/run.sh: it starts
# real Claude Code sessions and spends tokens).
#
#   tests/probe-lane-tokens.sh [RUNS]        RUNS per prompt and condition, default 2
#
# Three fixed prompts, each a small piece of real work in a fresh copy of a fixture directory:
#   fix     a failing test: find the bug, fix it, run the test, report
#   explain what a script does and one exit code
#   fail    a build that fails: the failure must be reported whole
# Two conditions, same prompts, same model, same plugin tree (this checkout, via --plugin-dir), each a new
# `claude -p` session:
#   before  a session that is NOT a lane (no tmux pane in its environment): what a session gets today, which
#           on hosts with the explanatory-output-style plugin includes its Insight instructions
#   after   the same session as the lane "fx-probe" (DREAMTEAM_LANE_NAME, the hook's seam): the SessionStart
#           hook gives it the lane style
# Printed per run: output tokens (from the session's own usage report), lines and characters of the final
# message, and for `after` whether the report still has what it must have. Then the medians.
# Nothing is asserted: this prints numbers for a person. The directories are thrown away.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNS="${1:-2}"; [[ "$RUNS" =~ ^[1-9]$ ]] || { echo "usage: probe-lane-tokens.sh [RUNS 1-9]" >&2; exit 22; }
command -v claude >/dev/null && command -v jq >/dev/null || { echo "needs claude and jq" >&2; exit 2; }
T="$(mktemp -d)"; trap 'rm -rf -- "$T"' EXIT
mkdir -p "$T/fx"
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
P_fix='The test in this directory fails (python3 test_calc.py). Find the bug, fix it, run the test, and report.'
P_explain='What does scan.sh in this directory do, and what is its exit code when the directory argument does not exist?'
P_fail='Run ./build.sh in this directory and report the outcome. Do not try to fix anything.'

run() {  # run <condition> <prompt name> <n>
  local cond=$1 pn=$2 n=$3 d="$T/$1-$2-$3" prompt out
  cp -r "$T/fx" "$d"; prompt="P_$pn"
  if [ "$cond" = after ]; then
    out=$(cd "$d" && DREAMTEAM_LANE_NAME=fx-probe timeout 300 claude --plugin-dir "$ROOT" --dangerously-skip-permissions --output-format json -p "${!prompt}" 2>/dev/null)
  else
    out=$(cd "$d" && env -u TMUX -u TMUX_PANE -u DREAMTEAM_LANE_NAME timeout 300 claude --plugin-dir "$ROOT" --dangerously-skip-permissions --output-format json -p "${!prompt}" 2>/dev/null)
  fi
  local tok res lines chars model keep=""
  tok=$(jq -r '.usage.output_tokens // "?"' <<<"$out" 2>/dev/null) || tok="?"
  res=$(jq -r '.result // ""' <<<"$out" 2>/dev/null)
  model=$(jq -r '(.modelUsage // {}) | keys | join(",")' <<<"$out" 2>/dev/null)
  lines=$(printf '%s\n' "$res" | grep -c . || true); chars=${#res}
  printf '%s\n' "$res" > "$T/$cond-$pn-$n.txt"
  if [ "$cond" = after ]; then
    [ "$pn" = explain ] || { grep -q 'Not verified' <<<"$res" && keep="$keep not-verified:yes" || keep="$keep not-verified:NO"; }   # explain is a question, not a report
    grep -q 'Insight' <<<"$res" && keep="$keep insight:PRESENT" || keep="$keep insight:none"
    [ "$pn" = fail ] && { grep -q "frobnicate" <<<"$res" && grep -q "b.c:41" <<<"$res" && keep="$keep failure-whole:yes" || keep="$keep failure-whole:NO"; }
    [ "$pn" = fix ] && { (cd "$d" && python3 test_calc.py > /dev/null 2>&1) && keep="$keep test-passes:yes" || keep="$keep test-passes:NO"; }
  else
    grep -q 'Insight' <<<"$res" && keep="$keep insight:present" || keep="$keep insight:none"
    [ "$pn" = fix ] && { (cd "$d" && python3 test_calc.py > /dev/null 2>&1) && keep="$keep test-passes:yes" || keep="$keep test-passes:NO"; }
  fi
  printf '%-7s %-8s run %s  output_tokens %6s  lines %3s  chars %5s  %s  [%s]\n' "$cond" "$pn" "$n" "$tok" "$lines" "$chars" "$keep" "$model"
  echo "$cond $pn $tok" >> "$T/numbers"
}
echo "probe: $RUNS run(s) per prompt and condition; plugin tree $ROOT; $(claude --version 2>/dev/null | head -1); $(date '+%F %T')"
for pn in fix explain fail; do for n in $(seq 1 "$RUNS"); do run before "$pn" "$n"; run after "$pn" "$n"; done; done
echo "── medians (output tokens) ──"
for pn in fix explain fail; do
  b=$(awk -v p="$pn" '$1 == "before" && $2 == p && $3 ~ /^[0-9]+$/ {print $3}' "$T/numbers" | sort -n | awk '{a[NR]=$1} END {if (NR) print (NR % 2 ? a[(NR+1)/2] : int((a[NR/2] + a[NR/2+1]) / 2)); else print "?"}')
  a=$(awk -v p="$pn" '$1 == "after" && $2 == p && $3 ~ /^[0-9]+$/ {print $3}' "$T/numbers" | sort -n | awk '{a[NR]=$1} END {if (NR) print (NR % 2 ? a[(NR+1)/2] : int((a[NR/2] + a[NR/2+1]) / 2)); else print "?"}')
  if [[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[1-9][0-9]*$ ]]; then printf '%-8s before %6s  after %6s  (%s%%)\n' "$pn" "$b" "$a" "$(( (a - b) * 100 / b ))"; else printf '%-8s before %s after %s\n' "$pn" "$b" "$a"; fi
done
echo "── one 'after' report, as written (fix, run 1) ──"; cat "$T/after-fix-1.txt" 2>/dev/null
