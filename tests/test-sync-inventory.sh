#!/usr/bin/env bash
# dreamteam tests — scripts/sync-inventory.py (phase 0 of the sync replacement; read-only inventory).
# Fixture: a temp projects root with real git repos and a local bare remote. No network, no real home.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
S="$ROOT/scripts/sync-inventory.py"
TMP="$(mktemp -d)"; trap 'rm -rf -- "$TMP"' EXIT INT TERM
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
export HOME="$TMP/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
       GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
mkdir -p "$HOME"
P="$TMP/Projects"; mkdir -p "$P"
g() { git -c init.defaultBranch=main "$@" >/dev/null 2>&1; }

# clean: pushed, nothing extra
g init --bare "$TMP/remote-clean.git"
g init "$P/clean"; echo a > "$P/clean/a.txt"; g -C "$P/clean" add a.txt; g -C "$P/clean" commit -m one
g -C "$P/clean" remote add origin "$TMP/remote-clean.git"; g -C "$P/clean" push -u origin main

# busy: one unpushed commit, a dirty file, an untracked file, a kept ignored file, a regenerable ignored dir, a conflict
g init --bare "$TMP/remote-busy.git"
g init "$P/busy"; printf 'node_modules/\n.env\nscratch/\n' > "$P/busy/.gitignore"; echo a > "$P/busy/a.txt"
g -C "$P/busy" add .gitignore a.txt; g -C "$P/busy" commit -m one
g -C "$P/busy" remote add origin "$TMP/remote-busy.git"; g -C "$P/busy" push -u origin main
echo b > "$P/busy/b.txt"; g -C "$P/busy" add b.txt; g -C "$P/busy" commit -m two          # unpushed
echo changed > "$P/busy/a.txt"                                                             # dirty
echo new > "$P/busy/notes.md"                                                              # untracked
echo K=V > "$P/busy/.env"; mkdir -p "$P/busy/scratch"; echo f > "$P/busy/scratch/findings.md"   # kept ignored x2
mkdir -p "$P/busy/node_modules/x"; echo j > "$P/busy/node_modules/x/i.js"                  # regenerable
touch "$P/busy/a.sync-conflict-20261117-101010-ABCDEFG.txt" "$P/busy/node_modules/x/i.sync-conflict-20261117-101010-ABCDEFG.js"

# local-only: commits, no remote at all
g init "$P/localonly"; echo a > "$P/localonly/a.txt"; g -C "$P/localonly" add a.txt
g -C "$P/localonly" commit -m one; echo b >> "$P/localonly/a.txt"; g -C "$P/localonly" commit -am two

# empty repo, a plain dir, a symlinked dir (skipped), a plain FILE (skipped)
g init "$P/empty"
mkdir -p "$P/plain/data"; echo d > "$P/plain/data/d.bin"
ln -s "$P/plain" "$P/link"; echo x > "$P/README.txt"

before=$(cd "$P" && find . -type f -not -path '*/.git/objects/*' -printf '%p %T@ %s\n' | sort | sha256sum)
out=$(python3 -I "$S" --root "$P" 2>"$TMP/summary"); rc=$?
after=$(cd "$P" && find . -type f -not -path '*/.git/objects/*' -printf '%p %T@ %s\n' | sort | sha256sum)
[ "$rc" = 0 ] && ok "exit 0" || bad "rc=$rc"
[ "$before" = "$after" ] && ok "read-only: no file (index included) changed" || bad "the inventory changed a file"

col() { awk -F'\t' -v n="$1" -v c="$2" 'NR==1{for(i=1;i<=NF;i++)h[$i]=i} $1==n{print $h[c]}' <<< "$out"; }
[ "$(head -1 <<< "$out" | cut -f1-3)" = "name	kind	size_mb" ] && ok "header row" || bad "header: $(head -1 <<< "$out")"
[ "$(wc -l <<< "$out")" = 6 ] && ok "five dirs listed (symlink and file skipped)" || bad "row count $(wc -l <<< "$out")"

[ "$(col clean unpushed)|$(col clean dirty)|$(col clean untracked)|$(col clean kept_ignored)|$(col clean conflicts)|$(col clean note)" = "0|0|0|0|0|" ] \
  && ok "clean repo: all zeros, no note" || bad "clean row: $(grep '^clean' <<< "$out")"
[ "$(col busy unpushed)" = 1 ] && ok "busy: 1 unpushed commit" || bad "busy unpushed=$(col busy unpushed)"
[ "$(col busy dirty)" = 1 ] && ok "busy: 1 dirty tracked file" || bad "busy dirty=$(col busy dirty)"
[ "$(col busy untracked)" = 2 ] && ok "busy: 2 untracked (notes.md + the conflict copy)" || bad "busy untracked=$(col busy untracked)"
[ "$(col busy kept_ignored)" = 2 ] && ok "busy: 2 kept ignored (.env, scratch/); node_modules left out" || bad "busy kept=$(col busy kept_ignored)"
[ "$(col busy conflicts)" = 1 ] && ok "busy: 1 conflict copy (the one under node_modules pruned)" || bad "busy conflicts=$(col busy conflicts)"
[ "$(col busy branch)" = main ] && ok "busy: branch named" || bad "busy branch"
[ "$(col localonly unpushed)" = 2 ] && [ "$(col localonly note)" = no-remote ] && ok "no remote: every commit counts as unpushed, noted" || bad "localonly: $(grep '^localonly' <<< "$out")"
[ "$(col empty note)" = "no-commits no-remote" ] && [ "$(col empty unpushed)" = "" ] && ok "empty repo: noted, no number invented" || bad "empty: $(grep '^empty' <<< "$out")"
[ "$(col plain kind)" = plain ] && [ "$(col plain dirty)" = "" ] && ok "plain dir: kind plain, git columns blank" || bad "plain: $(grep '^plain' <<< "$out")"
[ -n "$(col busy size_mb)" ] && ok "size column filled" || bad "size blank"
grep -q "5 dirs: 4 git, 1 plain · unpushed commits 3 · dirty 1 · untracked 2 · kept ignored 2 · conflict copies 1 · dirs with something a clone would not carry: 4 · dirs not fully measured: 0$" "$TMP/summary" \
  && ok "summary line on stderr" || bad "summary: $(cat "$TMP/summary")"

out=$(python3 -I "$S" --root "$P" --no-size --only busy clean 2>/dev/null)
[ "$(wc -l <<< "$out")" = 3 ] && [ "$(col busy size_mb)" = "" ] && ok "--only and --no-size" || bad "--only/--no-size: $out"
python3 -I "$S" --root "$P" --only nope >/dev/null 2>&1; [ $? = 22 ] && ok "--only with an unknown name: exit 22" || bad "--only unknown rc"
python3 -I "$S" --root "$TMP/absent" >/dev/null 2>&1; [ $? = 2 ] && ok "absent root: exit 2" || bad "absent root rc"
python3 -I "$S" --bogus >/dev/null 2>&1; [ $? = 22 ] && ok "bad option: exit 22" || bad "bad option rc"

# --- xreview round 1: a number is printed only when it was measured -------------------------------------------
Q="$TMP/Projects2"; mkdir -p "$Q"
# (a) a repo whose clean filter would write a marker: status must not run there
g init "$Q/filtered"; echo a > "$Q/filtered/a.dat"; g -C "$Q/filtered" add a.dat; g -C "$Q/filtered" commit -m one
git -C "$Q/filtered" config filter.mark.clean "sh -c 'touch \"$TMP/FILTER-RAN\"; cat'"
echo '*.dat filter=mark' > "$Q/filtered/.gitattributes"; echo changed > "$Q/filtered/a.dat"
# (b) a .git that git cannot read as a repo
mkdir -p "$Q/corrupt"; echo "not a gitdir" > "$Q/corrupt/.git"; echo x > "$Q/corrupt/x.txt"
# (c) a detached HEAD
g init "$Q/detached"; echo a > "$Q/detached/a"; g -C "$Q/detached" add a; g -C "$Q/detached" commit -m one
g -C "$Q/detached" checkout --detach
# (d) a plain dir with an unreadable subdirectory holding a conflict copy
mkdir -p "$Q/locked/in"; touch "$Q/locked/top.sync-conflict-20261117-000000-ABCDEFG" "$Q/locked/in/hid.sync-conflict-20261117-000000-ABCDEFG"
[ "$(id -u)" != 0 ] && chmod 000 "$Q/locked/in"
out=$(python3 -I "$S" --root "$Q" --no-size 2>"$TMP/summary2"); rc=$?
[ "$(id -u)" != 0 ] && chmod 700 "$Q/locked/in"
[ "$rc" = 0 ] && ok "second fixture: exit 0" || bad "second fixture rc=$rc"
[ ! -e "$TMP/FILTER-RAN" ] && ok "a repo's clean filter is never run" || bad "the clean filter ran"
[ "$(col filtered note)" = "no-remote has-filters" ] && [ "$(col filtered dirty)" = "" ] && [ "$(col filtered unpushed)" = 1 ] \
  && ok "has-filters: status columns blank, unpushed still measured" || bad "filtered: $(grep '^filtered' <<< "$out")"
[ "$(col corrupt note)" = "git-error:rev-parse" ] && [ "$(col corrupt unpushed)$(col corrupt dirty)$(col corrupt branch)" = "" ] \
  && ok "unreadable .git: git-error, no fact invented (not 'no-commits')" || bad "corrupt: $(grep '^corrupt' <<< "$out")"
case "$(col detached note)" in "detached no-remote") ok "detached HEAD noted" ;; *) bad "detached: $(grep '^detached' <<< "$out")" ;; esac
if [ "$(id -u)" != 0 ]; then
  [ "$(col locked conflicts)" = 1 ] && [ "$(col locked note)" = walk-error ] && ok "unreadable subdir: walk-error, the count is a floor" || bad "locked: $(grep '^locked' <<< "$out")"
  grep -q "dirs not fully measured: 3 (a floor: see the notes)$" "$TMP/summary2" && ok "summary counts the unmeasured dirs" || bad "summary2: $(cat "$TMP/summary2")"
  grep -q "would not carry: 4 " "$TMP/summary2" && ok "an unmeasured dir is never counted as safe" || bad "stranded count: $(cat "$TMP/summary2")"
else
  ok "unreadable subdir: skipped as root"; ok "summary: skipped as root"; ok "stranded: skipped as root"
fi
# (e) a du that prints a number but exits non-zero is not a size
mkdir -p "$TMP/stub"; printf '#!/bin/sh\necho "4096\t$3"\nexit 1\n' > "$TMP/stub/du"; chmod +x "$TMP/stub/du"
out=$(PATH="$TMP/stub:$PATH" python3 "$S" --root "$P" --only clean 2>/dev/null)
[ "$(col clean size_mb)" = "" ] && [ "$(col clean note)" = size-error ] && ok "du exit 1: size blank + size-error" || bad "du stub: $(grep '^clean' <<< "$out")"

# --- xreview round 2: repo config and index flags cannot hide files; submodules are not entered ----------------
R="$TMP/Projects3"; mkdir -p "$R"
g init "$R/hideuntracked"; echo a > "$R/hideuntracked/a"; g -C "$R/hideuntracked" add a; g -C "$R/hideuntracked" commit -m one
git -C "$R/hideuntracked" config status.showUntrackedFiles no; echo n > "$R/hideuntracked/new.txt"
g init "$R/assume"; echo a > "$R/assume/a"; g -C "$R/assume" add a; g -C "$R/assume" commit -m one
g -C "$R/assume" update-index --assume-unchanged a; echo changed > "$R/assume/a"
g init "$R/skipwt"; echo a > "$R/skipwt/a"; g -C "$R/skipwt" add a; g -C "$R/skipwt" commit -m one
g -C "$R/skipwt" update-index --skip-worktree a
g init "$R/withsub"; echo a > "$R/withsub/a"; printf '[submodule "s"]\n\tpath = s\n\turl = ../none\n' > "$R/withsub/.gitmodules"
g -C "$R/withsub" add a .gitmodules; g -C "$R/withsub" commit -m one
g init "$R/sized"; printf 'scratch/\n' > "$R/sized/.gitignore"; g -C "$R/sized" add .gitignore; g -C "$R/sized" commit -m one
mkdir -p "$R/sized/scratch/node_modules"; head -c 3145728 /dev/zero > "$R/sized/scratch/node_modules/big.bin"
for i in $(seq 1 40); do head -c 40960 /dev/zero > "$R/sized/scratch/f$i.bin"; done
out=$(python3 -I "$S" --root "$R" 2>"$TMP/summary3")
[ "$(col hideuntracked untracked)" = 1 ] && ok "status.showUntrackedFiles=no cannot hide an untracked file" || bad "hideuntracked: $(grep '^hideuntracked' <<< "$out")"
case "$(col assume note)" in *hidden-index-flags*) ok "assume-unchanged: hidden-index-flags" ;; *) bad "assume: $(grep '^assume' <<< "$out")" ;; esac
case "$(col skipwt note)" in *hidden-index-flags*) ok "skip-worktree: hidden-index-flags" ;; *) bad "skipwt: $(grep '^skipwt' <<< "$out")" ;; esac
case "$(col withsub note)" in *has-submodules*) ok "a repo with .gitmodules says has-submodules" ;; *) bad "withsub: $(grep '^withsub' <<< "$out")" ;; esac
case "$(col hideuntracked note)" in *hidden*|*has-sub*) bad "a plain repo got a hidden/submodule note" ;; *) ok "a plain repo carries neither note" ;; esac
mb=$(col sized kept_ignored_mb)
awk -v m="$mb" 'BEGIN{exit !(m >= 1.4 && m <= 2.2)}' && ok "kept size: 40 small files sum to ~1.6 MB, the nested node_modules left out ($mb)" || bad "kept size $mb"
grep -q "dirs not fully measured: 3 " "$TMP/summary3" && ok "hidden flags and submodules count as not fully measured" || bad "summary3: $(cat "$TMP/summary3")"

echo "----"; echo "sync-inventory: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
