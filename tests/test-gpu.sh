#!/usr/bin/env bash
# dreamteam — regression tests for the GPU FLEET (spec docs/superpowers/specs/2026-09-29-gpu-fleet-design.md).
#
#   • scripts/lib/gpu_fleet.py — admission math, the claims ledger, windows, the guard's decision, launch
#     building. Tested through its CLI against the REAL gpu/fleet.json, with a temp ledger.
#   • scripts/gpu-guard.sh — the PreToolUse(Bash) wrapper: exit 2 in enforce mode, allow in warn mode.
#   • scripts/gpu/safe_run.sh and remote_run.sh — admission refusals and the exact launch they build,
#     with PATH-stubbed systemd-run, choom, nvidia-smi, loginctl, sudo, setsid, nohup and systemd-inhibit.
#     (scripts/gpu/test_guest_run.sh is the ON-HOST control for guest_run.sh: real scopes, run by hand.)
#
# THE INCIDENTS IT ENCODES (FAMILIAR-RULES.md, 2026-09-28): a 26-band pair on gpu1 kernel-OOM-killed at
# 5.23 GiB each (the pad-once loader's 2.81 GiB pairs fit); reverie's 6G + 8G + 4G stack on katana, each
# job admitted alone; the arena and GDAL-cache jobs that outgrew "subset peak + 20%" (hence x1.5).
#
# ISOLATION: env seams only (DREAMTEAM_GPU_STATE, DREAMTEAM_CONFIG, DREAMTEAM_GPU_NOW, DREAMTEAM_AGENT_ID,
# DREAMTEAM_GPU_LOCAL_HOST, DREAMTEAM_GPU_SSH = a stub serving canned probes, GPU_MEMINFO, GPU_NVIDIA_SMI).
# No network, no real ssh, no real scope.
#
# IDENTITY FIXTURE NOTE (the no-poll suite's trap): with DREAMTEAM_AGENT_ID empty, the wrapper's
# agent-id walk finds the RUNNER's own id when an agent runs this suite. The wrapper's orchestrator case
# therefore uses an id with no '@' (deterministically "not a teammate": fail open).
#
# Run standalone:  bash tests/test-gpu.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/scripts/lib/gpu_fleet.py"
PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
check() { if [ "$1" = "$2" ]; then pass "$3"; else fail "$3 (got '$1', want '$2')"; fi; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export TZ=UTC DREAMTEAM_GPU_LOCAL_HOST=katana
export DREAMTEAM_GPU_NOW=1790683200                         # 2026-09-29 12:00:00 UTC
printf '%s\n' '{"gpu":{"guard":"warn"}}'    > "$TMP/warn.json"
printf '%s\n' '{"gpu":{"guard":"enforce"}}' > "$TMP/enforce.json"
printf '%s\n' '{"gpu":{"guard":"off"}}'     > "$TMP/off.json"
printf '%s\n' '{}'                          > "$TMP/empty.json"
export DREAMTEAM_CONFIG="$TMP/enforce.json"
# a stub ssh: serves canned probe output per host from $PROBES/<host>.probe (missing file = asleep, 255)
PROBES="$TMP/probes"; mkdir -p "$PROBES" "$TMP/sshstub"
cat > "$TMP/sshstub/ssh" <<'STUB'
#!/usr/bin/env bash
host=""; while [ $# -gt 1 ]; do case "$1" in -o) shift 2 ;; -*) shift ;; *) host=$1; shift; break ;; esac; done
case "${1:-}" in *"kill -0"*) [ -e "$PROBES/$host.alive" ] && exit 0 || exit 1 ;; esac
[ -f "$PROBES/$host.probe" ] || exit 255
cat "$PROBES/$host.probe"
STUB
chmod +x "$TMP/sshstub/ssh"; export PROBES DREAMTEAM_GPU_SSH="$TMP/sshstub/ssh"
probe_fixture() {  # probe_fixture <host> <idx> <used_mib> <total_mib> [app-name app-mib]
  { echo "GPU,$2,00000000:0$2:00.0,$3,$4,10"; [ -n "${5:-}" ] && echo "APP,00000000:0$2:00.0,4242,$6,$5"
    echo "MEM,9000000,0,0"; echo "DISK,/,50"; echo "PAUSE,0"; } > "$PROBES/$1.probe"
}
probe_fixture katana 0 500 11264; probe_fixture familiar 0 3409 10240; probe_fixture gpu1 1 0 10240
fresh() { rm -rf "$TMP/state"; export DREAMTEAM_GPU_STATE="$TMP/state"; }
G()  { local id="$1"; shift; DREAMTEAM_AGENT_ID="$id" python3 "$LIB" "$@"; }   # G <agent-id> <verb> ...
rc() { "$@" >/dev/null 2>&1; echo $?; }
ORCH=""                                                      # an orchestrator session: no --agent-id
claim() { G "$ORCH" claim "$@" >/dev/null 2>&1; echo $?; }

# ── 1. the cap ───────────────────────────────────────────────────────────────────────────────────
fresh
out=$(G "$ORCH" claim gpu1:0 --lane drift-gems --until 2h --peak-ram 2881 --peak-vram 3000 --dry-run 2>&1)
case "$out" in *"cap 3458 MB"*) pass "cap = measured peak x 1.2 (2881 -> 3458 MB)" ;; *) fail "cap x1.2: $out" ;; esac
out=$(G "$ORCH" claim gpu1:0 --lane drift-gems --until 2h --peak-ram 4750 --peak-vram 3000 --grows --dry-run 2>&1)
case "$out" in *"cap 7125 MB"*) pass "a job that grows with run length caps at x1.5 (Canary's 4750 -> 7125 MB)" ;; *) fail "cap x1.5: $out" ;; esac

# ── 2. gpu1's pair rule, with the 2026-09-28 numbers ─────────────────────────────────────────────
fresh
check "$(claim gpu1:0 --lane drift-gems --until 2h --peak-ram 2878 --peak-vram 3000)" 0 "pair rule: the first 2.81 GiB run is admitted"
check "$(claim gpu1:1 --lane morpheus-gems --until 2h --peak-ram 2878 --peak-vram 3000)" 0 "pair rule: a second 2.81 GiB run fits (2 x 3454 + 1536 <= 10426 MB)"
fresh
check "$(claim gpu1:0 --lane drift-gems --until 2h --peak-ram 5356 --peak-vram 3000)" 0 "pair rule: one 5.23 GiB run alone is admitted"
check "$(claim gpu1:1 --lane morpheus-gems --until 2h --peak-ram 5356 --peak-vram 3000)" 75 "pair rule: a 5.23 GiB pair is REFUSED (the 19:29:47 OOM kill)"
out=$(G "$ORCH" claim gpu1:1 --lane morpheus-gems --until 2h --peak-ram 5356 --peak-vram 3000 2>&1)
case "$out" in *"rule 7"*) pass "the pair refusal cites FAMILIAR-RULES rule 7" ;; *) fail "pair refusal text: $out" ;; esac

# ── 3. the other host rules ──────────────────────────────────────────────────────────────────────
fresh
check "$(claim katana:0 --lane reverie-gems --until 2h --peak-ram 11000 --peak-vram 4000)" 75 "katana guest budget: a cap above 12 GB is refused (the sum rule)"
check "$(claim katana:0 --lane reverie-gems --until 2h --peak-ram 5000 --peak-vram 8000)" 0 "katana guest budget: 6 GB cap and 8 GiB VRAM fit"
fresh
check "$(claim familiar:0 --lane morpheus-gems --until 2h --peak-ram 3000 --peak-vram 3000 --protected)" 0 "familiar: one heavy job"
check "$(claim familiar:xpu0 --lane tapstone --until 2h --peak-ram 2000 --peak-vram 8000 --vulkan)" 75 "familiar: a second heavy job is refused (rule 2)"
fresh
check "$(claim familiar:0 --lane morpheus-gems --until 2h --peak-ram 3000 --peak-vram 9500)" 75 "VRAM: a claim must leave 1 GiB (9500 > 10240 - 1024)"
check "$(claim familiar:xpu0 --lane drift-gems --until 2h --peak-ram 500 --peak-vram 4000)" 75 "the B60 is refused for compute (Resizable BAR is off)"
check "$(claim familiar:xpu0 --lane drift-gems --until 2h --peak-ram 500 --peak-vram 4000 --vulkan)" 0 "the B60 is allowed for a Vulkan job"
fresh
check "$(claim gpu0:0 --lane nebula-gems --until 2h --peak-ram 2000 --peak-vram 2000 --estimate)" 2 "an estimated peak needs --solo (exit 2)"
check "$(claim gpu1:0 --lane nebula-gems --until 2h --peak-ram 3900 --peak-vram 3000 --estimate --solo)" 0 "an estimate with --solo is admitted"
check "$(claim gpu1:1 --lane drift-gems --until 2h --peak-ram 1000 --peak-vram 1000)" 75 "a solo claim keeps its host alone until measured"

# ── 4. windows ───────────────────────────────────────────────────────────────────────────────────
fresh
check "$(rc G "$ORCH" window katana:0 22:00-06:00 --note 'JP away')" 0 "a granter sets a window that crosses midnight"
check "$(claim katana:0 --lane reverie-gems --until 1h --peak-ram 3000 --peak-vram 3000)" 75 "a claim at 12:00 outside 22:00-06:00 is refused"
check "$(DREAMTEAM_GPU_NOW=1790650800 claim katana:0 --lane reverie-gems --until 1h --peak-ram 3000 --peak-vram 3000)" 0 "the same claim at 03:00 is admitted (inside a midnight-crossing window)"
check "$(rc G "$ORCH" window katana:0 25:00-26:00)" 2 "a malformed window is a usage error"

# ── 5. the ledger and who may write it ───────────────────────────────────────────────────────────
fresh
check "$(rc G luna-refurb@jp claim gpu0:0 --lane luna-refurb --until 1h --peak-ram 1000 --peak-vram 1000)" 77 "a lane cannot claim for itself (77: ask the lead)"
check "$(rc G nyx-res@jp claim gpu0:0 --lane luna-refurb --until 1h --peak-ram 1000 --peak-vram 1000)" 0 "a Nyx-class agent may grant"
check "$(rc G morpheus-gems@jp claim gpu1:0 --lane drift-gems --until 1h --peak-ram 1000 --peak-vram 1000)" 0 "morpheus-gems may grant (the GEMS window-granter)"
check "$(claim gpu0:0 --lane drift-gems --until 1h --peak-ram 1000 --peak-vram 1000)" 75 "one holder per card: a second lane is refused"
out=$(G "$ORCH" claim gpu0:0 --lane drift-gems --until 1h --peak-ram 1000 --peak-vram 1000 2>&1)
case "$out" in *"held by luna-refurb"*) pass "the refusal names the holder" ;; *) fail "holder not named: $out" ;; esac
check "$(DREAMTEAM_GPU_NOW=1790690400 claim gpu0:0 --lane drift-gems --until 1h --peak-ram 1000 --peak-vram 1000)" 0 "an expired claim reads as free (2 h later)"
check "$(rc G drift-gems@jp release gpu1:0)" 0 "the holder releases its own card"
check "$(rc G luna-refurb@jp release gpu0:0)" 77 "another lane cannot release a card it does not hold"

# ── 6. the guard's decision ──────────────────────────────────────────────────────────────────────
fresh
claim gpu1:1 --lane drift-gems --until 2h --peak-ram 2878 --peak-vram 3000 >/dev/null
claim katana:0 --lane reverie-gems --until 2h --peak-ram 3000 --peak-vram 3000 >/dev/null
decide() {  # decide <agent-id> <config> <command> -> action
  jq -nc --arg c "$3" '{tool_name:"Bash", tool_input:{command:$c}}' \
    | DREAMTEAM_AGENT_ID="$1" DREAMTEAM_CONFIG="$2" python3 "$LIB" guard | jq -r .action
}
cards() { DREAMTEAM_AGENT_ID=x python3 "$LIB" detect "$1" | jq -r '(.cards + (.host_any | map(. + ":*"))) | join(",")'; }
E="$TMP/enforce.json"
# positive controls: each is a launch, attributed to the right card
check "$(cards 'ssh -o ConnectTimeout=10 gpu1 "cd /var/tmp/fwork/gems && CUDA_VISIBLE_DEVICES=1 python stage2_train.py"')" "gpu1:1" "detect: CUDA_VISIBLE_DEVICES=1 over ssh -> gpu1:1"
check "$(cards 'HOST=gpu0 lanes/drift/gpu1_launch.sh 0 A g0-S3-x --loss dwt')" "gpu0:0" "detect: HOST=gpu0 gpu1_launch.sh 0 -> gpu0:0"
check "$(cards 'lanes/drift/gpu1_launch.sh 1 B g1-S3-x --seeds 6')" "gpu1:1" "detect: gpu1_launch.sh 1 (default HOST) -> gpu1:1"
check "$(cards 'ssh familiar ~/Projects/x/tools/safe_run.sh --protected 6G .venv/bin/python train.py')" "familiar:0" "detect: safe_run --protected on familiar -> familiar:0 (the B60 is compute-blocked)"
check "$(cards 'tools/guest_run.sh --mem 4G -- python ssl.py')" "katana:0" "detect: guest_run with a GPU cap on katana -> katana:0"
check "$(cards 'CUDA_VISIBLE_DEVICES=0 python -m train')" "katana:0" "detect: a local CUDA_VISIBLE_DEVICES=0 -> katana:0"
check "$(cards 'ssh gpu1 python3 run.py')" "gpu1:*" "detect: python on gpu1 with no index -> any gpu1 card"
check "$(cards 'ssh familiar "ZE_AFFINITY_MASK=0 python bench.py"')" "familiar:xpu0" "detect: ZE_AFFINITY_MASK=0 on familiar -> familiar:xpu0"
# negative controls: reads and non-GPU work are not launches (the guard must not be vacuous either way)
for c in 'nvidia-smi' 'ssh gpu1 nvidia-smi --query-gpu=memory.used --format=csv' 'ssh gpu1 tail -f /var/tmp/fwork/gems/runs/x.log' \
         'dreamteam gpu board' 'python3 analyze.py' 'ssh familiar python3 palace_stats.py' 'tools/guest_run.sh --gpu-mem 0 --mem 2G -- make' \
         'ssh familiar tools/safe_run.sh 3G python sweep.py' 'CUDA_VISIBLE_DEVICES= python cpu_only.py'; do
  check "$(cards "$c")" "" "not a launch: $c"
done
check "$(cards 'ssh "$HOST" "CUDA_VISIBLE_DEVICES=0 python x.py"')" "" "an ssh to an unresolved host fails OPEN (never blames the wrong card)"
# decisions
check "$(decide drift-gems@jp "$E" 'ssh gpu1 "CUDA_VISIBLE_DEVICES=1 python train.py"')" allow "enforce: the holder launches on its card"
check "$(decide drift-gems@jp "$E" 'ssh gpu1 "CUDA_VISIBLE_DEVICES=0 python train.py"')" block "enforce: the same lane on a card it does not hold is BLOCKED"
check "$(decide luna-refurb@jp "$E" 'ssh gpu1 python3 run.py')" block "enforce: python on gpu1 with no claim there is blocked"
check "$(decide drift-gems@jp "$E" 'ssh gpu1 python3 run.py')" allow "enforce: a lane holding any gpu1 card may run unindexed python there"
check "$(decide luna-refurb@jp "$E" 'dreamteam gpu run --card gpu1:0 -- python x.py')" allow "gpu run passes the guard (it checks the claim itself)"
check "$(decide luna-refurb@jp "$E" 'nvidia-smi')" allow "a read is always allowed"
check "$(decide "" "$E" 'ssh gpu1 "CUDA_VISIBLE_DEVICES=0 python x.py"')" allow "an orchestrator (no --agent-id) is never blocked (fail open)"
check "$(decide luna-refurb@jp "$TMP/warn.json" 'ssh gpu1 "CUDA_VISIBLE_DEVICES=0 python x.py"')" warn "warn mode: the would-block is a warn"
grep -q '"luna-refurb@jp"' "$TMP/state/guard.log" 2>/dev/null && pass "warn mode logs the would-block line" || fail "no guard.log line"
check "$(decide luna-refurb@jp "$TMP/empty.json" 'ssh gpu1 "CUDA_VISIBLE_DEVICES=0 python x.py"')" warn "a missing gpu.guard is warn, never off"
check "$(decide luna-refurb@jp "$TMP/off.json" 'ssh gpu1 "CUDA_VISIBLE_DEVICES=0 python x.py"')" allow "off disables the check"

# ── 7. the bash wrapper (exit codes a hook runner sees) ──────────────────────────────────────────
W="$ROOT/scripts/gpu-guard.sh"
payload() { jq -nc --arg c "$1" '{tool_name:"Bash", tool_input:{command:$c}}'; }
payload 'ssh gpu1 "CUDA_VISIBLE_DEVICES=0 python x.py"' | DREAMTEAM_AGENT_ID=luna-refurb@jp DREAMTEAM_CONFIG="$E" bash "$W" 2>"$TMP/err"; r=$?
check "$r" 2 "wrapper: enforce blocks with exit 2"
grep -q "GPU GUARD" "$TMP/err" && pass "wrapper: the reason reaches stderr" || fail "wrapper: no stderr reason"
payload 'ssh gpu1 "CUDA_VISIBLE_DEVICES=0 python x.py"' | DREAMTEAM_AGENT_ID=luna-refurb@jp DREAMTEAM_CONFIG="$TMP/warn.json" bash "$W" 2>/dev/null
check "$?" 0 "wrapper: warn allows (exit 0)"
payload 'ssh gpu1 "CUDA_VISIBLE_DEVICES=0 python x.py"' | DREAMTEAM_AGENT_ID=orchestrator-fixture DREAMTEAM_CONFIG="$E" bash "$W" 2>/dev/null
check "$?" 0 "wrapper: a non-teammate identity fails open"
payload 'ls -la' | DREAMTEAM_AGENT_ID=luna-refurb@jp DREAMTEAM_CONFIG="$E" bash "$W" 2>/dev/null
check "$?" 0 "wrapper: an ordinary command never reaches python (pre-filter)"
echo 'not json' | DREAMTEAM_AGENT_ID=luna-refurb@jp DREAMTEAM_CONFIG="$E" bash "$W" 2>/dev/null
check "$?" 0 "wrapper: a malformed payload fails open"

# ── 8. run: the launch each host form builds (dry run) ───────────────────────────────────────────
fresh
claim familiar:0 --lane morpheus-gems --until 2h --peak-ram 3000 --peak-vram 3000 --protected >/dev/null
claim katana:0 --lane reverie-gems --until 2h --peak-ram 5000 --peak-vram 4096 >/dev/null
claim gpu1:1 --lane drift-gems --until 2h --peak-ram 2878 --peak-vram 3000 >/dev/null
out=$(G morpheus-gems@jp run --card familiar:0 --dry-run -- python train.py 2>&1)
case "$out" in *safe_run.sh*"--protected 3600M python train.py"*) pass "run familiar: safe_run --protected with the claim's cap" ;; *) fail "familiar form: $out" ;; esac
case "$out" in *"GPU_PROT_MIN_AVAIL_MB=6144"*"CUDA_VISIBLE_DEVICES=0"*) pass "run familiar: thresholds and the card come from fleet.json" ;; *) fail "familiar env: $out" ;; esac
out=$(G reverie-gems@jp run --card katana:0 --dry-run -- python ssl.py 2>&1)
case "$out" in *"GUEST_MAX_MEM_MB=12288 GUEST_MAX_GPU_MIB=9216 GUEST_HEADROOM_MB=4096"*"--mem 6000M --gpu-mem 4.00"*) pass "run katana: guest_run with katana's budget and the claim's caps" ;; *) fail "guest form: $out" ;; esac
out=$(G drift-gems@jp run --card gpu1:1 --name g1-S3-test --dry-run -- bash tools/run_exp.sh 2>&1)
case "$out" in *remote_run.sh*"--gpu 1 --cap 3454M --name g1-S3-test"*) pass "run gpu1: remote_run with the card index and cap" ;; *) fail "remote form: $out" ;; esac
check "$(rc G luna-refurb@jp run --card gpu1:1 --dry-run -- python x.py)" 77 "run: a lane that does not hold the card is refused (77)"
check "$(rc G drift-gems@jp run --card gpu1:0 --dry-run -- python x.py)" 77 "run: an unclaimed card is refused (77)"
check "$(rc G drift-gems@jp run --card gpu1:1 --peak-ram 9000 --dry-run -- python x.py)" 75 "run: a peak above the claim re-runs the host budget (9000 x 1.2 is too big for gpu1)"

probe_fixture gpu1 1 9500 10240 python 9400
check "$(rc G drift-gems@jp run --card gpu1:1 --dry-run -- python x.py)" 75 "run: live VRAM refuses a card another process fills (9500 of 10240 used)"
out=$(G drift-gems@jp run --card gpu1:1 --dry-run -- python x.py 2>&1)
case "$out" in *"in use: 4242 9400MiB python"*) pass "run: the live-VRAM refusal names what holds the card" ;; *) fail "live VRAM refusal text: $out" ;; esac
probe_fixture gpu1 1 0 10240
fresh
check "$(claim familiar:0 --lane morpheus-gems --until 2h --peak-ram 3000 --peak-vram 6000)" 75 "residents: familiar:0's services leave 10240 - 1024 - 3406 = 5810 MiB claimable (6000 refused)"
check "$(claim familiar:0 --lane morpheus-gems --until 2h --peak-ram 3000 --peak-vram 5800)" 0 "residents: 5800 MiB fits beside them"
filters=$(cd "$ROOT/scripts/lib" && python3 -c '
import gpu_fleet as g
res = [{"match": "llama-server"}]
apps = [{"name": "renderD128 --crashpad-handler-pid=1 --enable-crash-reporter", "used_mib": "991"},
        {"name": "/opt/llama.cpp/build/bin/llama-server", "used_mib": "3026"},
        {"name": "python", "used_mib": "1302"}, {"name": "python", "used_mib": "40"}]
print(",".join(x["name"] for x in g.unclaimed_use(apps, res)))')
check "$filters" "python" "board: a Chromium GPU process and a resident service are not 'in use, no claim'; a 1.3 GB python job is, a 40 MiB one is not"

# ── 9. safe_run.sh: the familiar form's live admission (stubbed meminfo, systemd-run and choom) ───
S="$TMP/stub"; mkdir -p "$S"
printf '#!/bin/sh\necho "systemd-run $*"\n' > "$S/systemd-run"; printf '#!/bin/sh\nexec "$@"\n' > "$S/choom"
chmod +x "$S"/*
mi() { printf 'MemTotal: 32000000 kB\nMemAvailable: %s kB\nSwapTotal: 16000000 kB\nSwapFree: %s kB\n' "$1" "$2" > "$TMP/meminfo"; }
SR="$ROOT/scripts/gpu/safe_run.sh"
mi 3072000 16000000; check "$(GPU_MEMINFO="$TMP/meminfo" GPU_ONE_HEAVY=0 PATH="$S:$PATH" bash "$SR" 2G true >/dev/null 2>&1; echo $?)" 75 "safe_run: MemAvailable 3000 MB < 2G + 2 GB is refused (75)"
mi 9216000 16000000; out=$(GPU_MEMINFO="$TMP/meminfo" GPU_ONE_HEAVY=0 PATH="$S:$PATH" bash "$SR" 2G true 2>/dev/null)
case "$out" in *"MemoryMax=2G -p MemorySwapMax=0"*"-n 500"*) pass "safe_run: admitted into a capped, no-swap, +500 scope" ;; *) fail "safe_run launch: $out" ;; esac
mi 9216000 6400000; check "$(GPU_MEMINFO="$TMP/meminfo" GPU_ONE_HEAVY=0 PATH="$S:$PATH" bash "$SR" --protected 2G true >/dev/null 2>&1; echo $?)" 75 "safe_run --protected: swap at 60% is refused"
mi 9216000 6400000; check "$(GPU_MEMINFO="$TMP/meminfo" GPU_ONE_HEAVY=0 GPU_PROT_MAX_SWAP_PCT=70 PATH="$S:$PATH" bash "$SR" --protected 2G true >/dev/null 2>&1; echo $?)" 0 "safe_run --protected: the swap threshold comes from env (fleet.json)"

# ── 10. remote_run.sh: preflight, run-exists, floor, and the exact detached launch ────────────────
R="$ROOT/scripts/gpu/remote_run.sh"; RS="$TMP/rstub"; mkdir -p "$RS"; REC="$TMP/rec"
printf '#!/bin/sh\nexit 0\n' > "$RS/nvidia-smi"; printf '#!/bin/sh\nexit 1\n' > "$RS/nvidia-smi-bad"
printf '#!/bin/sh\necho no\n' > "$RS/loginctl"
printf '#!/bin/sh\n[ "$1 $2" = "-n true" ] && exit 0\necho "sudo $*" >> %s\n' "$REC" > "$RS/sudo"
printf '#!/bin/sh\nexec "$@"\n' > "$RS/setsid"; printf '#!/bin/sh\nexec "$@"\n' > "$RS/nohup"
printf '#!/bin/sh\necho "systemd-inhibit $*" > %s\n' "$REC" > "$RS/systemd-inhibit"
chmod +x "$RS"/*
check "$(GPU_NVIDIA_SMI="$RS/nvidia-smi-bad" PATH="$RS:$PATH" bash "$R" --gpu 1 --cap 2G --name t --log "$TMP/r/t.log" -- true >/dev/null 2>&1; echo $?)" 5 "remote_run: a failed nvidia-smi preflight exits 5"
mkdir -p "$TMP/r"; : > "$TMP/r/exists.log"
check "$(GPU_NVIDIA_SMI="$RS/nvidia-smi" PATH="$RS:$PATH" bash "$R" --gpu 1 --cap 2G --name x --log "$TMP/r/exists.log" -- true >/dev/null 2>&1; echo $?)" 17 "remote_run: an existing run log exits 17"
check "$(GPU_NVIDIA_SMI="$RS/nvidia-smi" GPU_DISK_FLOOR_GB=999999 PATH="$RS:$PATH" bash "$R" --gpu 1 --cap 2G --name f --log "$TMP/r/f.log" -- true >/dev/null 2>&1; echo $?)" 75 "remote_run: below the disk floor exits 75"
GPU_NVIDIA_SMI="$RS/nvidia-smi" GPU_DISK_FLOOR_GB=0 PATH="$RS:$PATH" bash "$R" --gpu 1 --cap 3454M --name ok --log "$TMP/r/ok.log" -- python train.py >/dev/null 2>&1
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$REC" ] && break; sleep 0.1; done
rec=$(cat "$REC" 2>/dev/null)
case "$rec" in *"--what=sleep"*"sudo -n systemd-run --scope"*"MemoryMax=3454M -p MemorySwapMax=0"*"env CUDA_VISIBLE_DEVICES=1"*"python train.py"*) pass "remote_run: sleep lock + a system scope (no lingering) + the card, in that order" ;; *) fail "remote_run launch: $rec" ;; esac

echo ""
echo "test-gpu: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
