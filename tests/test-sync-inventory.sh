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
grep -q "5 dirs: 4 git, 1 plain · unpushed commits 3 · dirty 1 · untracked 2 · kept ignored 2 · conflict copies 1 · dirs with something a clone would not carry: 4" "$TMP/summary" \
  && ok "summary line on stderr" || bad "summary: $(cat "$TMP/summary")"

out=$(python3 -I "$S" --root "$P" --no-size --only busy clean 2>/dev/null)
[ "$(wc -l <<< "$out")" = 3 ] && [ "$(col busy size_mb)" = "" ] && ok "--only and --no-size" || bad "--only/--no-size: $out"
python3 -I "$S" --root "$P" --only nope >/dev/null 2>&1; [ $? = 22 ] && ok "--only with an unknown name: exit 22" || bad "--only unknown rc"
python3 -I "$S" --root "$TMP/absent" >/dev/null 2>&1; [ $? = 2 ] && ok "absent root: exit 2" || bad "absent root rc"
python3 -I "$S" --bogus >/dev/null 2>&1; [ $? = 22 ] && ok "bad option: exit 22" || bad "bad option rc"

echo "----"; echo "sync-inventory: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
