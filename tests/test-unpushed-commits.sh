#!/usr/bin/env bash
# CHECK unpushed-commits (scripts/unpushed-commits-check.sh + scripts/lib/unpushed_commits.py) on real temp git
# repositories with a local bare remote, a stub mail command, a fixed clock, and its own state and checks dirs.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
S="${UNPUSHED_SCRIPT:-$ROOT/scripts/unpushed-commits-check.sh}"
T=$(mktemp -d "${TMPDIR:-/tmp}/unpushed.XXXXXX") || { echo "no temp dir"; exit 1; }
trap 'chmod -R u+rwx "$T" 2>/dev/null; rm -rf -- "$T"' EXIT
pass=0; fail=0
ok() { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "  FAIL: $1"; }

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid \
       GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
NOW=1800000000; DAY=86400
P="$T/Projects"; V="$T/srv"; mkdir -p "$P" "$V" "$T/state" "$T/checks" "$T/remotes" "$T/bin" "$T/cfg"
cat > "$T/bin/mail" <<EOS
#!/usr/bin/env bash
[ -e "$T/mail.fail" ] && exit 1
printf '%s\t%s\n' "\$1" "\$2" >> "$T/mail.log"
EOS
chmod +x "$T/bin/mail"; : > "$T/mail.log"
run() { DREAMTEAM_UNPUSHED_ROOTS="${ROOTS_OVERRIDE:-$P:$V}" DREAMTEAM_NOW="$NOW" XDG_STATE_HOME="$T/state" DREAMTEAM_CHECKS_DIR="$T/checks" \
        DREAMTEAM_MAIL_CMD="$T/bin/mail" DREAMTEAM_LEAD_MAIL=lead DREAMTEAM_REPO_OWNERS="$T/cfg/owners.tsv" DREAMTEAM_CHECK_HOST=familiar \
        HOME="$T" bash "$S" "$@" > "$T/stdout"; local rc=$?; case "${1:-}" in --list) cat "$T/stdout" ;; esac; return "$rc"; }
run_lead() { DREAMTEAM_UNPUSHED_ROOTS="$T/onlyok" DREAMTEAM_NOW="$NOW" XDG_STATE_HOME="$T/state" DREAMTEAM_CHECKS_DIR="$T/checks" \
        DREAMTEAM_MAIL_CMD="$T/bin/mail" DREAMTEAM_LEAD_MAIL="$1" DREAMTEAM_REPO_OWNERS="$T/cfg/owners.tsv" DREAMTEAM_CHECK_HOST=familiar \
        HOME="$T" bash "$S" > /dev/null 2>&1; }
line() { cat "$T"/checks/unpushed-commits*.line 2>/dev/null; }
mails() { wc -l < "$T/mail.log"; }
commit() { # repo, message, age in days
  local at=$(( NOW - $3 * DAY ))
  GIT_AUTHOR_DATE="@$at +0000" GIT_COMMITTER_DATE="@$at +0000" git -C "$1" commit -q --allow-empty -m "$2"
}
mkrepo() { # dir [remote-name]  → repo with one pushed commit, 30 days old
  git init -q -b main "$1"
  commit "$1" first 30
  if [ -n "${2:-}" ]; then
    git init -q --bare "$T/remotes/$2.git"
    git -C "$1" remote add origin "$T/remotes/$2.git"; git -C "$1" push -q -u origin main
  fi
}

# 1. everything pushed → ok, nothing told
mkrepo "$P/alpha" alpha; mkrepo "$V/site" site
mkdir "$P/plain"; echo x > "$P/afile"; ln -s "$P/alpha" "$P/alink"; git init -q "$P/empty"
run; rc=$?
[ "$rc" = 0 ] && ok || bad "rc $rc on a clean tree"
[ "$(line)" = "CHECK unpushed-commits ok · 0 of 3 repos ahead for a day or more, 0 without a remote · daily, owner Sen" ] && ok || bad "clean line: $(line)"
[ "$(mails)" = 0 ] && ok || bad "a clean run sent mail"
[ ! -s "$T/state/dreamteam/unpushed-commits.list" ] && ok || bad "clean list not empty"

# 2. a young unpushed commit is work in progress: not a finding
commit "$P/alpha" wip 0
run; case "$(line)" in "CHECK unpushed-commits ok · 0 of 3 "*) ok ;; *) bad "young commit reported: $(line)" ;; esac

# 3. the same commit a day later IS one; the lead hears once
NOW=$(( NOW + DAY + 60 )); run
case "$(line)" in "CHECK unpushed-commits warn · 1 of 3 repos ahead for a day or more (oldest: alpha, 1 d), 0 without a remote · list: ~/state/dreamteam/unpushed-commits.list") ok ;; *) bad "ahead line: $(line)" ;; esac
[ "$(mails)" = 1 ] && grep -q $'^lead\t.*alpha (ahead, 1 commits)' "$T/mail.log" && ok || bad "lead not told once: $(cat "$T/mail.log")"
grep -q "history on familiar only" "$T/mail.log" && ok || bad "the message does not say where the only copy is"
run; [ "$(mails)" = 1 ] && ok || bad "told twice for the same finding"
grep -q $'^ahead\t'"$P/alpha"$'\t1\t' "$T/state/dreamteam/unpushed-commits.list" && ok || bad "list row: $(cat "$T/state/dreamteam/unpushed-commits.list")"
[ "$(stat -c %a "$T/state/dreamteam/unpushed-commits.list")" = 600 ] && ok || bad "list mode"

# 4. pushed → gone and forgotten; a later return is told again
git -C "$P/alpha" push -q origin main; run
case "$(line)" in "CHECK unpushed-commits ok · "*) ok ;; *) bad "after push: $(line)" ;; esac
[ ! -s "$T/state/dreamteam/unpushed-commits.told" ] && ok || bad "a finding that went away is still remembered"
commit "$P/alpha" again 3; run
[ "$(mails)" = 2 ] && ok || bad "a returned finding was not told again ($(mails))"
case "$(line)" in *"(oldest: alpha, 3 d)"*) ok ;; *) bad "age in days: $(line)" ;; esac
git -C "$P/alpha" push -q origin main

# 5. no remote at all → a finding at once (age does not matter), told once
mkrepo "$V/lonely"; run
case "$(line)" in "CHECK unpushed-commits warn · 0 of 4 repos ahead for a day or more, 1 without a remote · list: "*) ok ;; *) bad "no-remote line: $(line)" ;; esac
grep -q $'^lead\t.*lonely (no-remote, 1 commits)' "$T/mail.log" && ok || bad "no-remote not told"
m=$(mails); run; [ "$(mails)" = "$m" ] && ok || bad "no-remote told twice"

# 6. an owner map routes a finding to its lane; an invalid lane name falls back to the lead
printf 'beta\tluna-web\ngamma\t-oBad Name\n' > "$T/cfg/owners.tsv"
mkrepo "$P/beta" beta; commit "$P/beta" x 2; mkrepo "$P/gamma" gamma; commit "$P/gamma" y 2
: > "$T/mail.log"; run
grep -q $'^luna-web\t.*beta (ahead, 1 commits)' "$T/mail.log" && ok || bad "owner not told: $(cat "$T/mail.log")"
grep -q $'^lead\t.*gamma (ahead' "$T/mail.log" && ok || bad "invalid lane did not fall back to the lead"
! grep -q -- "-oBad" "$T/mail.log" && ok || bad "an invalid lane name reached the mail command"
[ "$(mails)" = 2 ] && ok || bad "one message per owner expected, got $(mails)"

# 7. many new findings for one owner → ONE message naming five and counting the rest
for i in 1 2 3 4 5 6 7; do mkrepo "$P/many$i"; done
: > "$T/mail.log"; run
[ "$(mails)" = 1 ] && ok || bad "seven findings sent $(mails) messages"
grep -q "and 2 more" "$T/mail.log" && ok || bad "the rest is not counted: $(cat "$T/mail.log")"
[ "$(grep -o 'many[0-9] (no-remote' "$T/mail.log" | wc -l)" = 5 ] && ok || bad "the message names $(grep -o 'many[0-9] (no-remote' "$T/mail.log" | wc -l) repos, not five"
case "$(line)" in *"2 of 13 repos ahead for a day or more"*", 8 without a remote"*) ok ;; *) bad "counts: $(line)" ;; esac

# 8. a message that cannot be sent is owed: tried again, then remembered
mkrepo "$P/late"; : > "$T/mail.log"; touch "$T/mail.fail"; run 2>/dev/null
[ "$(mails)" = 0 ] && ! grep -q "late" "$T/state/dreamteam/unpushed-commits.told" && ok || bad "an unsent message was remembered as told"
rm -f "$T/mail.fail"; run; grep -q "late (no-remote" "$T/mail.log" && ok || bad "the owed message was not retried"
m=$(mails); run; [ "$(mails)" = "$m" ] && ok || bad "retried message sent again"

# 9. only HEAD is asked: an unpushed commit on a branch that is not checked out is not a finding (pinned limit)
mkrepo "$P/side" side; git -C "$P/side" checkout -q -b feature; commit "$P/side" f 5; git -C "$P/side" checkout -q main
run --list > "$T/list.out"; ! grep -q "/side" "$T/list.out" && ok || bad "a not-checked-out branch was reported"
git -C "$P/side" checkout -q feature; run --list > "$T/list.out"; grep -q $'^ahead\t'"$P/side"$'\t1\t' "$T/list.out" && ok || bad "the same commit on HEAD is not reported"
head -n 1 "$T/list.out" | grep -q '^CHECK unpushed-commits warn' && ok || bad "--list does not print the line first"

# 10. a repository git cannot read is counted, makes the line warn, and is never part of an ok
mkdir -p "$T/only/broken/.git" "$T/onlyok"; mkrepo "$T/onlyok/fine" fine
ROOTS_OVERRIDE="$T/only" run
case "$(line)" in "CHECK unpushed-commits warn · 0 of 1 repos ahead for a day or more, 0 without a remote, 1 unreadable · list: "*) ok ;; *) bad "unreadable line: $(line)" ;; esac
ROOTS_OVERRIDE="$T/onlyok" run; case "$(line)" in "CHECK unpushed-commits ok · 0 of 1 "*) ok ;; *) bad "control for unreadable: $(line)" ;; esac

# 11. a root that is missing, unreadable or relative is a fail, never a zero
ROOTS_OVERRIDE="$T/onlyok:$T/nowhere" run; case "$(line)" in "CHECK unpushed-commits fail · "*"is not a readable directory"*) ok ;; *) bad "missing root: $(line)" ;; esac
ROOTS_OVERRIDE="relative/dir" run; case "$(line)" in "CHECK unpushed-commits fail · a root is not an absolute path"*) ok ;; *) bad "relative root: $(line)" ;; esac
if [ "$(id -u)" != 0 ]; then
  mkdir "$T/locked"; chmod 000 "$T/locked"; ROOTS_OVERRIDE="$T/locked" run
  case "$(line)" in "CHECK unpushed-commits fail · "*) ok ;; *) bad "unreadable root: $(line)" ;; esac
  chmod 700 "$T/locked"
fi

# 12. a measurement that does not finish is a fail (python3 replaced by one that prints nothing, then one that lies)
mkdir "$T/pybin"; printf '#!/bin/sh\nexit 0\n' > "$T/pybin/python3"; chmod +x "$T/pybin/python3"
PATH="$T/pybin:$PATH" ROOTS_OVERRIDE="$T/onlyok" run
case "$(line)" in "CHECK unpushed-commits fail · the measurement did not finish"*) ok ;; *) bad "silent measurer: $(line)" ;; esac
printf '#!/bin/sh\nprintf "ahead\\t/x/y\\t1\\t5\\nRESULT repos=3 ahead=0 noremote=0 errors=0 young=0 empty=0\\n"\n' > "$T/pybin/python3"
PATH="$T/pybin:$PATH" ROOTS_OVERRIDE="$T/onlyok" run
case "$(line)" in "CHECK unpushed-commits fail · the findings do not match their own counts"*) ok ;; *) bad "lying measurer: $(line)" ;; esac
# a well-formed RESULT from a measurer that exited non-zero is not believed either
printf '#!/bin/sh\nprintf "RESULT repos=3 ahead=0 noremote=0 errors=0 young=0 empty=0\\n"\nexit 3\n' > "$T/pybin/python3"
PATH="$T/pybin:$PATH" ROOTS_OVERRIDE="$T/onlyok" run
case "$(line)" in "CHECK unpushed-commits fail · the measurement did not finish (exit 3)"*) ok ;; *) bad "failed measurer believed: $(line)" ;; esac

# 13. nothing is written into any repository: every file under every .git is byte-identical after a run, none added
snap() { find "$P" "$V" -path '*/.git/*' -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum; find "$P" "$V" -path '*/.git/*' | wc -l; }
a=$(snap); run; b=$(snap); [ "$a" = "$b" ] && ok || bad "a run changed something under a .git"
[ -z "$(git -C "$P/alpha" for-each-ref refs/remotes | head -c 1)" ] && bad "fixture has no remote ref (control)" || ok

# 13b. review round 1. A PARTIAL clone is never inspected (an old git could fetch a missing object there, which
# writes): it is unreadable, not clean. Positive control: the same repo without the setting is clean.
mkdir "$T/pc"; mkrepo "$T/pc/part" part
ROOTS_OVERRIDE="$T/pc" run; case "$(line)" in "CHECK unpushed-commits ok · 0 of 1 "*) ok ;; *) bad "partial-clone control: $(line)" ;; esac
git -C "$T/pc/part" config remote.origin.promisor true
ROOTS_OVERRIDE="$T/pc" run; case "$(line)" in "CHECK unpushed-commits warn · "*"1 unreadable"*) ok ;; *) bad "promisor remote inspected: $(line)" ;; esac
git -C "$T/pc/part" config --unset remote.origin.promisor; git -C "$T/pc/part" config extensions.partialClone origin
ROOTS_OVERRIDE="$T/pc" run; case "$(line)" in "CHECK unpushed-commits warn · "*"1 unreadable"*) ok ;; *) bad "extensions.partialClone inspected: $(line)" ;; esac
# every git call the check makes forbids all transports and lazy fetching, and none is a command that writes
# (a wrapper logs each call's arguments and environment, then runs the real git)
realgit=$(command -v git); mkdir "$T/gitlog"
printf '#!/bin/sh\nprintf "%%s | lazy=%%s locks=%%s\\n" "$*" "${GIT_NO_LAZY_FETCH:-unset}" "${GIT_OPTIONAL_LOCKS:-unset}" >> "%s/git.calls"\nexec %s "$@"\n' "$T" "$realgit" > "$T/gitlog/git"; chmod +x "$T/gitlog/git"
: > "$T/git.calls"; PATH="$T/gitlog:$PATH" ROOTS_OVERRIDE="$T/onlyok:$T/pc" run
n=$(wc -l < "$T/git.calls"); g=$(grep -c -- '-c protocol.allow=never .* | lazy=1 locks=0$' "$T/git.calls" || true)
[ "$n" -ge 4 ] && [ "$n" = "$g" ] && ok || bad "git calls without the transport guard: $g of $n guarded"
! grep -qE ' (fetch|pull|push|status|gc|checkout|commit|add|reset|update-ref|pack-refs|repack|prune) ' "$T/git.calls" && ok || bad "a writing git command was called: $(grep -E ' (fetch|status|gc) ' "$T/git.calls" | head -n 2)"
[ "$(sed -E 's/.* -C [^ ]+ ([a-z-]+).*/\1/' "$T/git.calls" | sort -u | tr '\n' ' ')" = "config remote rev-list rev-parse " ] && ok || bad "git subcommands used: $(sed -E 's/.* -C [^ ]+ ([a-z-]+).*/\1/' "$T/git.calls" | sort -u | tr '\n' ' ')"
# a HEAD that exists but cannot be resolved is unreadable, never "empty"
mkdir "$T/hd"; mkrepo "$T/hd/gone" gone2; mkrepo "$T/hd/tree" tree2; git init -q -b main "$T/hd/unborn"
printf '%s\n' 1111111111111111111111111111111111111111 > "$T/hd/gone/.git/refs/heads/main"; rm -f "$T/hd/gone/.git/packed-refs"
tr=$(git -C "$T/hd/tree" rev-parse 'HEAD^{tree}'); [ "${#tr}" = 40 ] || bad "fixture: no tree id"   # read BEFORE the ref is overwritten
printf '%s\n' "$tr" > "$T/hd/tree/.git/refs/heads/main"; rm -f "$T/hd/tree/.git/packed-refs"
[ "$(git -C "$T/hd/tree" cat-file -t "$(cat "$T/hd/tree/.git/refs/heads/main")")" = tree ] && ok || bad "fixture: HEAD's ref does not name a tree"
ROOTS_OVERRIDE="$T/hd" run
case "$(line)" in "CHECK unpushed-commits warn · 0 of 3 repos ahead for a day or more, 0 without a remote, 2 unreadable · list: "*) ok ;; *) bad "broken HEADs: $(line)" ;; esac
grep -q $'^error\t'"$T/hd/gone"$'\t' "$T/state/dreamteam/unpushed-commits.list" && grep -q $'^error\t'"$T/hd/tree"$'\t' "$T/state/dreamteam/unpushed-commits.list" && ok || bad "broken HEADs not listed as errors"
! grep -q "unborn" "$T/state/dreamteam/unpushed-commits.list" && ok || bad "a truly unborn repo was listed"
# a git call that never finishes is cut by the timeout and that repo is unreadable (stub git: sleeps on the first call)
mkdir "$T/gitbin"; printf '#!/bin/sh\nexec sleep 30\n' > "$T/gitbin/git"; chmod +x "$T/gitbin/git"
s0=$(date +%s); PATH="$T/gitbin:$PATH" DREAMTEAM_UNPUSHED_GIT_TIMEOUT=1 ROOTS_OVERRIDE="$T/onlyok" run; s1=$(date +%s)
case "$(line)" in "CHECK unpushed-commits warn · "*"1 unreadable"*) [ $((s1-s0)) -lt 15 ] && ok || bad "stalled git took $((s1-s0)) s" ;; *) bad "stalled git: $(line)" ;; esac
# the lead's name is held to the lane grammar before anything is measured or sent
: > "$T/mail.log"
for badlead in "-oProxy" "Sen" "a b" ""; do
  run_lead "$badlead"
  case "$(line)" in "CHECK unpushed-commits fail · DREAMTEAM_LEAD_MAIL is not a plain lane name"*) : ;; *) [ -z "$badlead" ] || bad "lead '$badlead' accepted: $(line)" ;; esac
done
[ "$(mails)" = 0 ] && ok || bad "a message was sent with an invalid lead name"
# an unreadable run does not erase the told-once memory: finding → unreadable → the same finding = no second message
mkdir "$T/mem"; mkrepo "$T/mem/keep"; : > "$T/mail.log"
ROOTS_OVERRIDE="$T/mem" run; [ "$(mails)" = 1 ] && ok || bad "memory fixture not told ($(mails))"
mv "$T/mem/keep/.git/HEAD" "$T/mem/keep/.git/HEAD.aside"
ROOTS_OVERRIDE="$T/mem" run; case "$(line)" in *"1 unreadable"*) ok ;; *) bad "memory fixture not unreadable: $(line)" ;; esac
grep -q $'^no-remote\t'"$T/mem/keep"'$' "$T/state/dreamteam/unpushed-commits.told" && ok || bad "an unreadable run erased the memory"
mv "$T/mem/keep/.git/HEAD.aside" "$T/mem/keep/.git/HEAD"
ROOTS_OVERRIDE="$T/mem" run; [ "$(mails)" = 1 ] && ok || bad "told again after an unreadable run ($(mails))"

# 13c. review round 2. A repository directory that cannot be looked into is unreadable, never skipped.
if [ "$(id -u)" != 0 ]; then
  mkdir "$T/perm"; mkrepo "$T/perm/shut" shut; mkrepo "$T/perm/open" open2; chmod 000 "$T/perm/shut"
  ROOTS_OVERRIDE="$T/perm" run
  case "$(line)" in "CHECK unpushed-commits warn · 0 of 2 repos ahead for a day or more, 0 without a remote, 1 unreadable · list: "*) ok ;; *) bad "a closed repo dir was skipped: $(line)" ;; esac
  grep -q $'^error\t'"$T/perm/shut"$'\t' "$T/state/dreamteam/unpushed-commits.list" && ok || bad "closed repo dir not listed"
  chmod 700 "$T/perm/shut"
  ROOTS_OVERRIDE="$T/perm" run; case "$(line)" in "CHECK unpushed-commits ok · 0 of 2 "*) ok ;; *) bad "control for the closed dir: $(line)" ;; esac
fi
# a directory with no .git at all is still simply not a repository (control for the rule above)
mkdir -p "$T/perm2/justadir"; mkrepo "$T/perm2/r" r2; ROOTS_OVERRIDE="$T/perm2" run
case "$(line)" in "CHECK unpushed-commits ok · 0 of 1 "*) ok ;; *) bad "a plain dir was counted: $(line)" ;; esac
# a symlink where the memory or the list should be is refused BEFORE anything is opened: nothing is written through it
mkdir "$T/sl"; mkrepo "$T/sl/victim" victim; echo "sentinel" > "$T/sl/victim/keepme.txt"; mkdir -p "$T/slstate/dreamteam"
for f in unpushed-commits.told unpushed-commits.list; do
  rm -f "$T/slstate/dreamteam/"unpushed-commits.*; ln -s "$T/sl/victim/keepme.txt" "$T/slstate/dreamteam/$f"
  DREAMTEAM_UNPUSHED_ROOTS="$T/sl" DREAMTEAM_NOW="$NOW" XDG_STATE_HOME="$T/slstate" DREAMTEAM_CHECKS_DIR="$T/checks" DREAMTEAM_MAIL_CMD="$T/bin/mail" \
    DREAMTEAM_LEAD_MAIL=lead DREAMTEAM_CHECK_HOST=familiar HOME="$T" bash "$S" >/dev/null 2>&1
  case "$(line)" in "CHECK unpushed-commits fail · a state file is a symlink or not a plain file of ours: $f"*) : ;; *) bad "symlinked $f not refused: $(line)" ;; esac
  [ "$(cat "$T/sl/victim/keepme.txt")" = "sentinel" ] && [ -L "$T/slstate/dreamteam/$f" ] || bad "something was written through the symlinked $f"
done
[ "$(cat "$T/sl/victim/keepme.txt")" = "sentinel" ] && ok || bad "the repository file behind the symlink changed"
rm -f "$T/slstate/dreamteam/"unpushed-commits.*
# a first run with no memory file creates it by rename and works
DREAMTEAM_UNPUSHED_ROOTS="$T/sl" DREAMTEAM_NOW="$NOW" XDG_STATE_HOME="$T/slstate" DREAMTEAM_CHECKS_DIR="$T/checks" DREAMTEAM_MAIL_CMD="$T/bin/mail" \
  DREAMTEAM_LEAD_MAIL=lead DREAMTEAM_CHECK_HOST=familiar HOME="$T" bash "$S" >/dev/null 2>&1
[ -f "$T/slstate/dreamteam/unpushed-commits.told" ] && [ ! -L "$T/slstate/dreamteam/unpushed-commits.told" ] && ok || bad "first run did not create the memory file"
# a directory whose name holds a control character is not inspected: an error under a stable printable name,
# never a finding, nobody told; a sibling that sorts before it does not change that name
mkdir "$T/odd"; oddn="$T/odd/we"$'\t'"ird"; mkrepo "$oddn"; : > "$T/mail.log"
ROOTS_OVERRIDE="$T/odd" run
case "$(line)" in "CHECK unpushed-commits warn · 0 of 1 repos ahead for a day or more, 0 without a remote, 1 unreadable · list: "*) ok ;; *) bad "odd name inspected: $(line)" ;; esac
a=$(cat "$T/state/dreamteam/unpushed-commits.list"); [ "$a" = "error"$'\t'"$T/odd/we?ird"$'\t0\t0' ] && ok || bad "odd name row: $a"
mkrepo "$T/odd/aaa" aaa; ROOTS_OVERRIDE="$T/odd" run
grep -qxF "$a" "$T/state/dreamteam/unpushed-commits.list" && ok || bad "the odd name's row changed when a sibling was added"
[ "$(mails)" = 0 ] && ok || bad "an uninspected odd-named dir was told as a finding"

# 13d. review round 3. A broken repository inside a clean ENCLOSING repository is unreadable: git must not climb to
# the parent and report the parent's state as the child's. (The root here is itself a repository.)
mkrepo "$T/enc" enc; mkdir -p "$T/enc/kid/.git"; mkrepo "$T/enc/good" encgood
ROOTS_OVERRIDE="$T/enc" run
case "$(line)" in "CHECK unpushed-commits warn · 0 of 2 repos ahead for a day or more, 0 without a remote, 1 unreadable · list: "*) ok ;; *) bad "a broken child read as its parent: $(line)" ;; esac
grep -q $'^error\t'"$T/enc/kid"$'\t' "$T/state/dreamteam/unpushed-commits.list" && ok || bad "broken child not listed"
# the state dir and the checks dir may not lie inside an inspected root, through any symlink: nothing is created there
mkdir "$T/sy"; mkrepo "$T/sy/victim2" victim2; mkdir -p "$T/systate"; ln -s "$T/sy/victim2" "$T/systate/dreamteam"
before=$(find "$T/sy/victim2" | sort | sha256sum)
DREAMTEAM_UNPUSHED_ROOTS="$T/sy" DREAMTEAM_NOW="$NOW" XDG_STATE_HOME="$T/systate" DREAMTEAM_CHECKS_DIR="$T/checks" DREAMTEAM_MAIL_CMD="$T/bin/mail" \
  DREAMTEAM_LEAD_MAIL=lead DREAMTEAM_CHECK_HOST=familiar HOME="$T" bash "$S" >/dev/null 2>&1
case "$(line)" in "CHECK unpushed-commits fail · the state dir lies inside an inspected root"*) ok ;; *) bad "state dir inside a root accepted: $(line)" ;; esac
[ "$(find "$T/sy/victim2" | sort | sha256sum)" = "$before" ] && ok || bad "files were created inside the repository: $(find "$T/sy/victim2" -newer "$T/systate" | head -n 3)"
old=$(line); mkdir -p "$T/sy/victim2/sub"
DREAMTEAM_UNPUSHED_ROOTS="$T/sy" DREAMTEAM_NOW="$NOW" XDG_STATE_HOME="$T/state" DREAMTEAM_CHECKS_DIR="$T/sy/victim2/sub/checks" DREAMTEAM_MAIL_CMD="$T/bin/mail" \
  DREAMTEAM_LEAD_MAIL=lead DREAMTEAM_CHECK_HOST=familiar HOME="$T" bash "$S" >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && [ ! -e "$T/sy/victim2/sub/checks" ] && [ "$(line)" = "$old" ] && ok || bad "a checks dir inside a root was written to (rc $rc)"
# a directory name with literal backslashes finds its own owner (awk -v would read \n and \\ as escapes)
mkdir "$T/bs"; mkrepo "$T/bs/"'we\nird'; mkrepo "$T/bs/"'back\\slash'; mkrepo "$T/bs/"'wenird'
printf '%s\t%s\n' 'we\nird' lane-a 'back\\slash' lane-b 'wenird' lane-c > "$T/cfg/owners.tsv"; : > "$T/mail.log"
ROOTS_OVERRIDE="$T/bs" run
grep -q $'^lane-a\t.*we\\\\nird (no-remote' "$T/mail.log" && grep -q $'^lane-b\t.*back\\\\\\\\slash (no-remote' "$T/mail.log" && grep -q $'^lane-c\t.*wenird (no-remote' "$T/mail.log" && ok || bad "backslash names not routed to their owners: $(cut -c1-70 "$T/mail.log" | tr '\n' '|')"
[ "$(mails)" = 3 ] && ok || bad "three owners expected, $(mails) messages"
printf 'beta\tluna-web\ngamma\t-oBad Name\n' > "$T/cfg/owners.tsv"

# 14. arguments, lock, units
run --nope 2>/dev/null; [ "$?" = 22 ] && ok || bad "bad argument not 22"
run --list extra 2>/dev/null; [ "$?" = 22 ] && ok || bad "extra argument not 22"
( exec 9>> "$T/state/dreamteam/unpushed-commits.lock"; flock -n 9; before=$(line); run 2>/dev/null; rc=$?; [ "$rc" = 75 ] && [ "$before" = "$(line)" ] ) && ok || bad "a held lock did not stop the run with 75"
python3 -I "$ROOT/scripts/lib/unpushed_commits.py" x y z >/dev/null 2>&1; [ "$?" = 22 ] && ok || bad "measurer bad arguments not 22"
python3 -I "$ROOT/scripts/lib/unpushed_commits.py" "$NOW" "$DAY" "$T/nowhere" >/dev/null 2>&1; [ "$?" = 2 ] && ok || bad "measurer missing root not 2"
if command -v systemd-analyze >/dev/null 2>&1; then
  d="$T/units"; mkdir "$d"; cp "$ROOT/systemd/dreamteam-unpushed-commits.service" "$ROOT/systemd/dreamteam-unpushed-commits.timer" "$d/"
  out=$(SYSTEMD_UNIT_PATH="$d:" systemd-analyze --user verify "$d/dreamteam-unpushed-commits.timer" 2>&1); rc=$?
  [ "$rc" = 0 ] && ! printf '%s\n' "$out" | grep -q 'unpushed-commits' && ok || bad "units: rc=$rc ${out:0:160}"
  sed -i 's/^OnCalendar=.*/OnCalendar=not a time/' "$d/dreamteam-unpushed-commits.timer"
  out=$(SYSTEMD_UNIT_PATH="$d:" systemd-analyze --user verify "$d/dreamteam-unpushed-commits.timer" 2>&1); rc=$?
  { [ "$rc" != 0 ] || printf '%s\n' "$out" | grep -q 'unpushed-commits'; } && ok || bad "verify accepted a broken timer (control)"
fi
grep -q '^| unpushed-commits |' "$ROOT/docs/CHECKS.md" && ok || bad "docs/CHECKS.md has no row"

echo "unpushed-commits: $pass passed, $fail failed"
[ "$fail" = 0 ]
