#!/usr/bin/env bash
# The unit files vendored on 2026-11-20 (timers that ran from no repository): quota-resume (user units) and
# reap-fambuild-agents (system units, copy of record in systemd/system + scripts/host). Static checks only: this
# suite cannot see a host, so "the installed file still matches" is a CHECK row's job, not a test's.
set -uo pipefail
ROOT="${VENDORED_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
pass=0; fail=0
ok() { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "  FAIL: $1"; }
t() { if "${@:2}" >/dev/null 2>&1; then ok; else bad "$1"; fi; }

unit_val() { sed -n "s/^$2=//p" "$1" | head -1; }

# 1. every vendored unit file is there, non-empty, and has the section its kind needs
for u in systemd/quota-resume.service systemd/quota-resume.timer \
         systemd/system/reap-fambuild-agents.service systemd/system/reap-fambuild-agents.timer; do
  t "$u exists and is not empty" test -s "$ROOT/$u"
  case "$u" in
    *.timer)   t "$u has [Timer]" grep -qx '\[Timer\]' "$ROOT/$u"
               t "$u is wanted by timers.target" grep -qx 'WantedBy=timers.target' "$ROOT/$u" ;;
    *.service) t "$u has [Service]" grep -qx '\[Service\]' "$ROOT/$u"
               t "$u is a oneshot" grep -qx 'Type=oneshot' "$ROOT/$u" ;;
  esac
done

# 2. each timer has a service of the same name beside it (a timer with no service starts nothing)
for tm in "$ROOT"/systemd/quota-resume.timer "$ROOT"/systemd/system/reap-fambuild-agents.timer; do
  t "$(basename "$tm") has its service beside it" test -s "${tm%.timer}.service"
done

# 3. quota-resume runs the script in THIS repo, not a scratch copy (the 2026-11-17 finding), and the script is there
ex=$(unit_val "$ROOT/systemd/quota-resume.service" ExecStart)
case "$ex" in
  "/usr/bin/python3 %h/Projects/dreamteam/scripts/quota_resume.py") ok ;;
  *) bad "quota-resume ExecStart is not the repo script: $ex" ;;
esac
case "$ex" in *scratch*) bad "quota-resume ExecStart names a scratch path" ;; *) ok ;; esac
t "scripts/quota_resume.py exists" test -s "$ROOT/scripts/quota_resume.py"
t "scripts/quota_resume.py parses" python3 -I -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$ROOT/scripts/quota_resume.py"

# 4. the system service runs the installed name, and the copy of record of that script is here, executable and parses
ex=$(unit_val "$ROOT/systemd/system/reap-fambuild-agents.service" ExecStart)
case "$ex" in "/usr/local/bin/reap-fambuild-agents "[0-9]*) ok ;; *) bad "reap ExecStart unexpected: $ex" ;; esac
t "scripts/host/reap-fambuild-agents is executable" test -x "$ROOT/scripts/host/reap-fambuild-agents"
t "scripts/host/reap-fambuild-agents parses" bash -n "$ROOT/scripts/host/reap-fambuild-agents"
# It deletes directories: pin the two properties that keep it narrow.
t "reap only ever looks one level deep for agent-* dirs" \
  grep -q 'find "\$FB" -maxdepth 1 -type d -name "agent-\*" -mtime' "$ROOT/scripts/host/reap-fambuild-agents"
t "reap matches the compiler by executable name (-x), never by command line" \
  grep -q 'pgrep -u jp -x cargo' "$ROOT/scripts/host/reap-fambuild-agents"
if grep -Eq 'pgrep[^|;]* -f ' <(grep -v '^[[:space:]]*#' "$ROOT/scripts/host/reap-fambuild-agents"); then bad "reap uses pgrep -f in code"; else ok; fi

# 5. systemd reads the user units without complaint (skipped, and said so, where the tool is missing)
if command -v systemd-analyze >/dev/null 2>&1; then
  d=$(mktemp -d "${TMPDIR:-/tmp}/vendored-units.XXXXXX"); trap 'rm -rf -- "$d"' EXIT
  cp "$ROOT/systemd/quota-resume.service" "$ROOT/systemd/quota-resume.timer" "$d/"
  out=$(SYSTEMD_UNIT_PATH="$d:" systemd-analyze --user verify "$d/quota-resume.timer" 2>&1); rc=$?
  if [ "$rc" = 0 ] && ! printf '%s\n' "$out" | grep -q 'quota-resume'; then ok; else bad "systemd-analyze verify: rc=$rc ${out:0:200}"; fi
  # positive control: the same call must object to a broken unit, or the check above proves nothing
  printf '[Unit]\nDescription=x\n[Timer]\nOnCalendar=not a time\n' > "$d/quota-resume.timer"
  out=$(SYSTEMD_UNIT_PATH="$d:" systemd-analyze --user verify "$d/quota-resume.timer" 2>&1); rc=$?
  if [ "$rc" != 0 ] || printf '%s\n' "$out" | grep -q 'quota-resume'; then ok; else bad "verify accepted a broken timer (control)"; fi
else
  echo "  note: systemd-analyze not found; unit verification skipped"
fi

# 6. docs: every vendored timer has a CHECKS.md row, and the system-unit README names the installed paths
for n in quota-resume quota-resume-katana reap-fambuild-agents; do
  t "docs/CHECKS.md has a row for $n" grep -q "^| $n |" "$ROOT/docs/CHECKS.md"
done
t "systemd/system/README.md names /etc/systemd/system" grep -q '/etc/systemd/system' "$ROOT/systemd/system/README.md"

echo "vendored-units: $pass passed, $fail failed"
[ "$fail" = 0 ]
