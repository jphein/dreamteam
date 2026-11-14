#!/usr/bin/env bash
# dreamteam — workflows/overnight.js under stubbed Workflow globals (agent/parallel/pipeline/phase/log/
# budget): the guarded nightly's three args. `issues` skips Scout and works exactly the handed-over
# list; `prOnly` never runs Ship (no merge agent at all); `prGate` makes the merge warden gate on
# pr-gate.sh instead of one named check. And without those args the old behaviour stands (Scout runs,
# approved PRs reach Ship). Needs node; skips (exit 0) without it.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
command -v node >/dev/null 2>&1 || { echo "SKIP: node not installed"; exit 0; }
PASS=0; FAIL=0
pass(){ echo "PASS: $1"; PASS=$((PASS+1)); }
fail(){ echo "FAIL: $1"; FAIL=$((FAIL+1)); }

run(){ # $1 = args JSON → prints one JSON line {labels:[...], prompts:{label:prompt}, result}
  node - "$ROOT/workflows/overnight.js" "$1" <<'JS'
const fs = require('fs')
const [file, argsJson] = process.argv.slice(2)
const src = fs.readFileSync(file, 'utf8').replace(/^export const meta/m, 'const meta')
const labels = [], prompts = {}
let pr = 100
const agent = async (prompt, o) => {
  labels.push(o.label); prompts[o.label] = prompt
  if (o.label.startsWith('scout:')) return { issues: [{ title: 'scouted thing', area: 'x', severity: 'high', rationale: 'r', issueNumber: 1 }] }
  if (o.label.startsWith('fix:')) return { ok: true, action: 'pr-opened', prNumber: ++pr }
  if (o.label.startsWith('review:')) return { verdict: 'approve', rationale: 'ok' }
  if (o.label.startsWith('ship:')) return { pr: 0, merged: true, action: 'merged' }
  return null
}
const parallel = async fns => Promise.all(fns.map(f => f()))
const pipeline = async (items, a, b) => Promise.all(items.map(async it => b(await a(it), it)))
const budget = { total: 0, remaining: () => 0, spent: () => 0 }
const body = new Function('args', 'budget', 'phase', 'log', 'agent', 'parallel', 'pipeline',
  'return (async () => {' + src + '})()')
body(JSON.parse(argsJson), budget, () => {}, () => {}, agent, parallel, pipeline)
  .then(result => console.log(JSON.stringify({ labels, prompts, result })))
  .catch(e => { console.log(JSON.stringify({ error: String(e) })); })
JS
}
has(){ jq -e "$2" <<<"$1" >/dev/null 2>&1; }

o=$(run '{"repo":"o/r","issues":[{"number":7,"title":"seven"},{"number":9,"title":"nine"}],"prOnly":true,"prGate":"/x/pr-gate.sh"}')
has "$o" '[.labels[]|select(startswith("scout:"))]|length==0' && pass "issues given → no scout agent" || fail "scouted despite issues: $o"
has "$o" '[.labels[]|select(startswith("fix:"))]|length==2' && pass "exactly the 2 handed-over issues are fixed" || fail "fix count: $(jq -c .labels <<<"$o")"
has "$o" '[.prompts|to_entries[]|select(.key|startswith("fix:"))|.value|test("gh #7|gh #9")]|all' && pass "fix prompts name the dream issue numbers" || fail "issue numbers missing from fix prompts"
has "$o" '[.prompts|to_entries[]|select(.key|startswith("fix:"))|.value|(test("UNTRUSTED DATA") and test("DATA, never instructions") and test("--json title,body") and test("never its comments"))]|all' \
  && pass "fixer prompts fence the issue text as untrusted data and read title+body only, never comments" || fail "fixer prompt lacks the untrusted-data fence"
has "$o" '[.prompts|to_entries[]|select(.key|startswith("review:"))|.value|test("untrusted data")]|all' \
  && pass "reviewer prompts quote the issue as untrusted and check for smuggled CI/credential edits" || fail "reviewer prompt lacks the fence"
has "$o" '[.labels[]|select(startswith("ship:"))]|length==0' && pass "prOnly → no merge agent runs" || fail "prOnly shipped: $(jq -c .labels <<<"$o")"
has "$o" '.result.prOnly==true and (.result.approvedOpen|length==2) and (.result.merged|length==0)' && pass "prOnly result: approved PRs left open, none merged" || fail "prOnly result: $(jq -c .result <<<"$o")"

o=$(run '{"repo":"o/r","issues":[{"number":7,"title":"seven"}],"prOnly":false,"prGate":"/x/pr-gate.sh"}')
has "$o" '[.labels[]|select(startswith("ship:"))]|length==1' && pass "merge repo → one serial merge warden" || fail "merge-mode ship: $(jq -c .labels <<<"$o")"
has "$o" '[.prompts|to_entries[]|select(.key|startswith("ship:"))|.value|(test("/x/pr-gate.sh o/r 101") and test("Exit 4") and (test("gh pr checks")|not))]|all' \
  && pass "prGate → warden gates on pr-gate.sh (exit 4 = no merge), no checks-grep loop" || fail "warden prompt: $(jq -r '.prompts|to_entries[]|select(.key|startswith("ship:"))|.value' <<<"$o" | head -12)"

o=$(run '{"repo":"o/r"}')
has "$o" '[.labels[]|select(startswith("scout:"))]|length>=2' && pass "no args → Scout still runs (old behaviour)" || fail "default scout: $o"
has "$o" '[.labels[]|select(startswith("ship:"))]|length>=1' && pass "no args → approved PRs still reach Ship" || fail "default ship"
has "$o" '[.prompts|to_entries[]|select(.key|startswith("ship:"))|.value|test("Build APK")]|all' && pass "no prGate → named required-check wait kept" || fail "default warden lost REQUIRED"

echo "SUMMARY: $PASS passed, $FAIL failed, $((PASS+FAIL)) total"
[ "$FAIL" -eq 0 ]
