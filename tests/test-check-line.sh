#!/usr/bin/env bash
# dreamteam tests — scripts/lib/check-line.sh, the one CHECK line every dreamteam timer writes (docs/CHECKS.md).
#
# The line is read by the Watch (plan checks.py): its LINE regex takes the fact as everything up to the FIRST " · ",
# and its NAME regex decides whether a file is read at all. So the shape is checked here against the Watch's own
# regexes, read from the plan checkout when there is one (else the pinned copies below), as well as by eye.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/scripts/lib/check-line.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT INT TERM
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
export DREAMTEAM_CHECKS_DIR="$TMP/checks"
# shellcheck disable=SC1090
. "$LIB"

WATCH="$HOME/srv/plan.realm.watch/src/plan_realm_watch/checks.py"
watch_parse() {  # watch_parse <line>  → "name|status|fact|next" by the Watch's LINE regex, or "NOMATCH"
  python3 -I - "$1" "$WATCH" <<'PY'
import re, sys
line, src = sys.argv[1], sys.argv[2]
pat = r"CHECK (\S+) (ok|warn|fail) · (.*?) · (.*)"          # pinned copy of plan checks.py LINE (2026-11-17)
try:
    m = re.search(r'^LINE = re\.compile\(r"(.+)", re\.S\)$', open(src).read(), re.M)
    if m: pat = m.group(1)
except OSError:
    pass
m = re.fullmatch(pat, line.strip(), re.S)
print("|".join(m.groups()) if m else "NOMATCH")
PY
}
watch_name_ok() {  # the Watch's NAME regex
  python3 -I - "$1" "$WATCH" <<'PY'
import re, sys
name, src = sys.argv[1], sys.argv[2]
pat = r"[a-z0-9][a-z0-9-]{0,63}"                             # pinned copy of plan checks.py NAME (2026-11-17)
try:
    m = re.search(r'^NAME = re\.compile\(r"(.+)"\)$', open(src).read(), re.M)
    if m: pat = m.group(1)
except OSError:
    pass
print("yes" if re.fullmatch(pat, name) else "no")
PY
}

bash -n "$LIB" && ok "bash -n check-line.sh" || bad "bash -n"

# 1. shape: three segments the Watch parses back exactly, even when the fact holds " · " and newlines
out=$(check_line demo-check ok $'7 repos · open 3\nsecond line' "next 16:50, owner Sen"); rc=$?
[ "$rc" = 0 ] && [ "$(cat "$TMP/checks/demo-check.line")" = "$out" ] && ok "published, and stdout is the same line" || bad "publish: rc=$rc"
[ "$(watch_parse "$out")" = "demo-check|ok|7 repos, open 3 second line|next 16:50, owner Sen" ] \
  && ok "the Watch parses name|status|fact|next exactly (fact's ' · ' → ', ', newline → space)" || bad "watch parse: $(watch_parse "$out")"
[ "$(wc -l < "$TMP/checks/demo-check.line")" = 1 ] && ok "one line" || bad "line count"

for pair in "a · · b|a, , b" "a ·|a ," "· a|, a" "a·b|a,b"; do
  in=${pair%%|*}; want=${pair#*|}; out=$(check_line demo-check ok "$in" "next")
  [ "$(watch_parse "$out")" = "demo-check|ok|$want|next" ] && ok "fact '$in' → one segment '$want', next intact" || bad "edge '$in': $(watch_parse "$out")"
done

# 2. an unknown status is published as fail, never ok
out=$(check_line demo-check maybe "x" "y")
[[ "$out" == "CHECK demo-check fail · unknown status 'maybe': x · y" ]] && ok "unknown status → fail" || bad "status: $out"

# 3. names: what the Watch would not read is never published; what it reads always is
for nm in demo.dot demo_under Demo-upper -lead ../x 'a b' ''; do
  rm -rf "$TMP/checks"; check_line "$nm" ok f n >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] && [ -z "$(ls -A "$TMP/checks" 2>/dev/null)" ] && [ "$(watch_name_ok "$nm")" = no ] \
    && ok "name '$nm': the Watch would skip it, so nothing is published" || bad "name '$nm': rc=$rc files=$(ls -A "$TMP/checks" 2>/dev/null)"
done
for nm in issues-queue dreamteam-audit-katana nightly-guarded; do
  [ "$(watch_name_ok "$nm")" = yes ] && ok "name '$nm' is one the Watch reads" || bad "name '$nm' not Watch-readable"
done

# 4. check_name: plain on familiar, host-suffixed elsewhere
[ "$(DREAMTEAM_CHECK_HOST=familiar check_name dreamteam-briefing)" = dreamteam-briefing ] && ok "check_name on familiar: no suffix" || bad "check_name familiar"
[ "$(DREAMTEAM_CHECK_HOST=katana check_name dreamteam-briefing)" = dreamteam-briefing-katana ] && ok "check_name on katana: -katana" || bad "check_name katana"
[ "$(DREAMTEAM_CHECK_HOST=KATANA.lan check_name x)" = x-katanalan ] && [ "$(DREAMTEAM_CHECK_HOST=FAMILIAR check_name x)" = x ] \
  && ok "check_name lower-cases the host and keeps [a-z0-9-] only" || bad "check_name case: $(DREAMTEAM_CHECK_HOST=KATANA.lan check_name x)"

# 5. publication: a symlink at the destination is replaced, its target untouched; a directory there is refused
rm -rf "$TMP/checks"; mkdir -p "$TMP/checks"; echo SENTINEL > "$TMP/sentinel"; ln -s "$TMP/sentinel" "$TMP/checks/demo-check.line"
check_line demo-check ok f n >/dev/null
[ "$(cat "$TMP/sentinel")" = SENTINEL ] && [ -f "$TMP/checks/demo-check.line" ] && [ ! -L "$TMP/checks/demo-check.line" ] \
  && ok "symlink at the destination replaced, never followed" || bad "symlink followed"
rm -rf "$TMP/checks"; mkdir -p "$TMP/checks/demo-check.line"
check_line demo-check ok f n >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && [ -z "$(ls -A "$TMP/checks/demo-check.line")" ] && [ "$(ls -A "$TMP/checks")" = demo-check.line ] \
  && ok "directory at the destination refused (rc=$rc), nothing written into it, no temp left" || bad "dir dest: rc=$rc"
#    planted symlinks at predictable temp names are not followed
rm -rf "$TMP/checks"; mkdir -p "$TMP/checks"; echo SENTINEL > "$TMP/sentinel2"
for t in demo-check.line.tmp .demo-check.line.tmp; do ln -s "$TMP/sentinel2" "$TMP/checks/$t"; done
check_line demo-check ok f n >/dev/null
[ "$(cat "$TMP/sentinel2")" = SENTINEL ] && ok "predictable temp names not used" || bad "predictable temp followed"

echo "─────────────────────────────────────────"
echo "SUMMARY: $PASS passed, $FAIL failed, $((PASS+FAIL)) total"
[ "$FAIL" -eq 0 ]
