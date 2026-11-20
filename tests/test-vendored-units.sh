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
# The three system files are COPIES OF RECORD of installed production text, and the script deletes directories. A
# marker grep cannot hold its scope (`-o -type d` appended to the find, or the rustc guard removed, would pass one),
# so the whole text is pinned: any edit turns this red, and the digest is changed in the same reviewed commit that
# changes the text and the host.
pin() { # file, sha256
  got=$(sha256sum "$ROOT/$1" 2>/dev/null | cut -d' ' -f1)
  if [ "$got" = "$2" ]; then ok; else bad "$1 is not the reviewed text (sha256 ${got:0:16}…, pinned ${2:0:16}…)"; fi
}
pin scripts/host/reap-fambuild-agents               97bd5eb3c769d7b2202d6d4e95d190a77726e8a363dfb296fd50dcabd3ef5387
pin systemd/system/reap-fambuild-agents.service     777ef1107e2db6d742643ca63d2e6b25084ffde16c64148caa8a800598495387
pin systemd/system/reap-fambuild-agents.timer       8f15d4e708f7e572b49011ebdd9b9e2b95e47edccb24d75097f52a1b1460862a

# 5. systemd reads the units without complaint (skipped, and said so, where the tool is missing).
# What this step touches: it WRITES only inside its own temp dir, and stops if that dir cannot be made. It is not
# read-isolated: the trailing colon in SYSTEMD_UNIT_PATH adds systemd's default unit paths (verify needs the
# targets a unit names), so the host's own units are read, and their warnings are filtered out by unit name.
# verify installs nothing, starts nothing and runs no ExecStart.
if command -v systemd-analyze >/dev/null 2>&1; then
  d=$(mktemp -d "${TMPDIR:-/tmp}/vendored-units.XXXXXX") && [ -n "$d" ] && [ -d "$d" ] \
    || { echo "  FAIL: no temp dir; nothing verified"; echo "vendored-units: $pass passed, $((fail+1)) failed"; exit 1; }
  trap 'rm -rf -- "$d"' EXIT
  verify() { # scope-flag-or-empty, unit file name in $d  → 0 when systemd has no complaint about OUR unit
    local out rc stem="${2%.*}"
    # shellcheck disable=SC2086
    out=$(SYSTEMD_UNIT_PATH="$d:" systemd-analyze $1 verify "$d/$2" 2>&1); rc=$?
    [ "$rc" = 0 ] && ! printf '%s\n' "$out" | grep -q -- "$stem"
  }
  if cp -- "$ROOT/systemd/quota-resume.service" "$ROOT/systemd/quota-resume.timer" \
           "$ROOT/systemd/system/reap-fambuild-agents.service" "$ROOT/systemd/system/reap-fambuild-agents.timer" "$d/"; then
    t "systemd accepts the quota-resume user units" verify --user quota-resume.timer
    # The system service names /usr/local/bin/reap-fambuild-agents, which exists only on the host that runs it: the
    # temp copy's ExecStart is pointed at /bin/true so every OTHER directive of both system units is verified.
    if sed -i 's|^ExecStart=.*|ExecStart=/bin/true|' "$d/reap-fambuild-agents.service"; then
      t "systemd accepts the reap system units (ExecStart stubbed in the copy)" verify "" reap-fambuild-agents.timer
    else bad "could not stub ExecStart in the temp copy"; fi
    # positive controls: the same calls must object to a broken unit, or the two checks above prove nothing
    if printf '[Unit]\nDescription=x\n[Timer]\nOnCalendar=not a time\n' > "$d/quota-resume.timer" \
       && ! verify --user quota-resume.timer; then ok; else bad "verify accepted a broken user timer (control)"; fi
    if sed -i 's|^OnCalendar=.*|OnCalendar=not a time|' "$d/reap-fambuild-agents.timer" \
       && ! verify "" reap-fambuild-agents.timer; then ok; else bad "verify accepted a broken system timer (control)"; fi
  else
    bad "could not copy the units into the temp dir; nothing verified"
  fi
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
