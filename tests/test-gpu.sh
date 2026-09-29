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

# ── 2. the pair rule on RAW measured peaks (STAGE3 00:27: "2 x peak + 1.5 <= 10.2, no margin needed") ──
fresh
check "$(claim gpu1:0 --lane drift-gems --until 2h --peak-ram 2878 --peak-vram 3000)" 0 "pair rule: the first 2.81 GiB run is admitted"
check "$(claim gpu1:1 --lane morpheus-gems --until 2h --peak-ram 2878 --peak-vram 3000)" 0 "pair rule: a second 2.81 GiB run fits (2 x 2878 + 1536 <= 10444)"
fresh
check "$(claim gpu1:0 --lane drift-gems --until 2h --peak-ram 4322 --peak-vram 3000)" 0 "pair rule: a 46-band 4.22 GiB run is admitted"
check "$(claim gpu1:1 --lane reverie-gems --until 2h --peak-ram 4322 --peak-vram 3000)" 0 "pair rule: the 46-band PAIR fits on raw peaks (2 x 4322 + 1536 = 10180 <= 10444, as STAGE3 decided)"
fresh
check "$(claim gpu1:0 --lane drift-gems --until 2h --peak-ram 5356 --peak-vram 3000)" 0 "pair rule: one 5.23 GiB run alone is admitted"
check "$(claim gpu1:1 --lane morpheus-gems --until 2h --peak-ram 5356 --peak-vram 3000)" 75 "pair rule: a 5.23 GiB pair is REFUSED (the 19:29:47 OOM kill)"
out=$(G "$ORCH" claim gpu1:1 --lane morpheus-gems --until 2h --peak-ram 5356 --peak-vram 3000 2>&1)
case "$out" in *"rule 7"*) pass "the pair refusal cites FAMILIAR-RULES rule 7" ;; *) fail "pair refusal text: $out" ;; esac
fresh
check "$(claim gpu0:0 --lane nebula-gems --until 2h --peak-ram 3277 --peak-vram 1400)" 0 "gpu0: a DEM3 run (3.2 GB, 1.4 GiB VRAM)"
check "$(claim gpu0:0 --lane drift-gems --until 2h --peak-ram 3277 --peak-vram 1400)" 0 "gpu0: a DEM3 pair SHARES its one card (RAM 8090 <= idle MemAvailable 9500; VRAM 2800 <= 3072)"
check "$(claim gpu0:0 --lane reverie-gems --until 2h --peak-ram 3277 --peak-vram 200)" 75 "gpu0: a third run is refused on RAM, keyed to idle MemAvailable (drift, 09-29)"
check "$(claim gpu0:0 --lane reverie-gems --until 2h --peak-ram 500 --peak-vram 400)" 75 "gpu0: VRAM is summed across the card's claims (2800 + 400 > 3072)"

# ── 3. the other host rules ──────────────────────────────────────────────────────────────────────
fresh
check "$(claim katana:0 --lane reverie-gems --until 2h --peak-ram 11000 --peak-vram 4000)" 75 "katana guest budget: a cap above 12 GB is refused (the sum rule)"
check "$(claim katana:0 --lane reverie-gems --until 2h --peak-ram 5000 --peak-vram 5000)" 0 "katana guest budget: a 6 GB cap and 5 GiB VRAM fit beside the desktop's 2700 MiB"
fresh
check "$(claim katana:0 --lane luna-refurb --until 1h --peak-ram 5000 --peak-vram 8000)" 75 "katana: an 8 GB docker audit breaks the margin beside the desktop (8000 + 1024 > 11264 - 2700)"
check "$(claim katana:0 --lane luna-refurb --until 1h --peak-ram 5000 --peak-vram 8000 --override 'lead: the call watcher kills it under 512 MiB free')" 0 "katana: the lead may override the margin (8000 <= 8564 physically)"
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

# ── 5. the ledger, who may write it, sharing, exclusivity, schedules and overrides ───────────────
fresh
check "$(rc G luna-refurb@jp claim gpu0:0 --lane luna-refurb --until 1h --peak-ram 1000 --peak-vram 1000)" 77 "a lane cannot claim for itself (77: ask the lead)"
check "$(rc G nyx-res@jp claim gpu0:0 --lane luna-refurb --until 1h --peak-ram 1000 --peak-vram 1000)" 0 "a Nyx-class agent may grant"
check "$(rc G morpheus-gems@jp claim gpu1:0 --lane drift-gems --until 1h --peak-ram 1000 --peak-vram 1000)" 0 "morpheus-gems may grant (the GEMS window-granter)"
check "$(claim gpu0:0 --lane drift-gems --until 1h --peak-ram 1000 --peak-vram 1000)" 0 "a second lane SHARES a card while VRAM and the host budget fit"
check "$(DREAMTEAM_GPU_NOW=1790690400 claim gpu0:0 --lane reverie-gems --until 1h --peak-ram 1000 --peak-vram 2500)" 0 "expired claims read as free (2 h later the card's VRAM is free again)"
fresh
check "$(claim gpu1:1 --lane morpheus-gems --until 2h --peak-ram 2000 --peak-vram 2000 --exclusive --purpose bench)" 0 "an exclusive claim (a bench)"
check "$(claim gpu1:1 --lane reverie-gems --until 1h --peak-ram 1000 --peak-vram 1000)" 75 "an exclusive holder keeps co-tenants off the card"
out=$(G "$ORCH" claim gpu1:1 --lane reverie-gems --until 1h --peak-ram 1000 --peak-vram 1000 2>&1)
case "$out" in *"exclusively by morpheus-gems"*) pass "the refusal names the exclusive holder" ;; *) fail "holder not named: $out" ;; esac
check "$(claim gpu1:1 --lane reverie-gems --until 1h --peak-ram 1000 --peak-vram 1000 --override 'lead: overlap for the handoff')" 0 "a granter's --override passes exclusivity, and records why"
grep -q '"override": "lead: overlap for the handoff"' "$TMP/state/claims.json" && pass "the override reason is kept in the ledger" || fail "override not recorded"
check "$(claim gpu1:1 --lane nebula-gems --until 1h --peak-ram 500 --peak-vram 7500 --override 'no')" 75 "nothing overrides the physics (2000 + 1000 + 7500 > 10240 on the card)"
fresh
check "$(claim familiar:0 --lane vesper-mozilla --until 2h --peak-ram 3000 --peak-vram 6560 --protected)" 75 "the 1 GiB margin: vesper's measured 6560 MiB beside 3406 MiB of residents is refused by policy"
check "$(claim familiar:0 --lane vesper-mozilla --until 2h --peak-ram 3000 --peak-vram 6560 --protected --override 'lead: running at 97% since 09:40, measured')" 0 "the margin is policy: a granter's override seeds what already runs"
check "$(claim familiar:0 --lane drift-gems --until 1h --peak-ram 500 --peak-vram 400 --override 'no')" 75 "but the physics holds: 6560 + 400 > 10240 - 3406, whatever the override"
fresh
check "$(claim familiar:0 --lane vesper-mozilla --until 2h --peak-ram 3000 --peak-vram 4506 --grows)" 0 "rule 3: a GROWING 4.4 GiB VRAM job fits beside the residents (x1.5 = 6759 <= 6834; the x1.5 is its headroom)"
fresh
check "$(claim familiar:0 --lane vesper-mozilla --until 2h --peak-ram 3000 --peak-vram 4608 --grows --override 'no')" 75 "rule 3: a growing 4.5 GiB job does not (x1.5 = 6912 > 6834), override or not"
fresh
check "$(claim gpu1:0 --lane morpheus-gems --until 13:15 --peak-ram 2000 --peak-vram 2000 --exclusive --purpose bench)" 0 "schedule: morpheus's bench until 13:15"
check "$(claim gpu1:0 --lane nebula-gems --from 13:15 --until 14:35 --peak-ram 3277 --peak-vram 1400)" 0 "schedule: nebula's lindep from 13:15 (a handoff, no overlap)"
check "$(claim gpu1:0 --lane drift-gems --from 13:00 --until 14:00 --peak-ram 1000 --peak-vram 1000)" 75 "schedule: a claim overlapping the exclusive bench is refused"
check "$(claim gpu1:0 --lane drift-gems --from 2026-09-29T14:00 --until 2026-09-29T13:00 --peak-ram 1000 --peak-vram 1000)" 2 "schedule: an explicit --until before --from is a usage error"
check "$(claim gpu0:0 --lane drift-gems --from 22:00 --until 06:00 --peak-ram 1000 --peak-vram 1000)" 0 "schedule: --from 22:00 --until 06:00 is an overnight claim (HH:MM = the next occurrence, like windows)"
jq -nc --arg c 'ssh gpu1 "CUDA_VISIBLE_DEVICES=0 python lindep.py"' '{tool_name:"Bash", tool_input:{command:$c}}' > "$TMP/p.json"
a1=$(DREAMTEAM_AGENT_ID=nebula-gems@jp python3 "$LIB" guard < "$TMP/p.json" | jq -r .action)
a2=$(DREAMTEAM_GPU_NOW=1790692200 DREAMTEAM_AGENT_ID=nebula-gems@jp python3 "$LIB" guard < "$TMP/p.json" | jq -r .action)
check "$a1/$a2" "block/allow" "schedule: nebula is blocked at 12:00 and allowed at 13:30, when its claim is live"
fresh
check "$(claim familiar:0 --lane morpheus-gems --until 2h --peak-ram 3000 --peak-vram 3000 --protected)" 0 "familiar: vesper-style protected run"
check "$(claim familiar:xpu0 --lane drift-gems --until 2h --peak-ram 2000 --peak-vram 8000 --vulkan)" 75 "familiar: a second heavy job is refused (rule 2)"
check "$(claim familiar:xpu0 --lane drift-gems --until 2h --peak-ram 2000 --peak-vram 8000 --vulkan --override 'lead: B60 bench beside vesper')" 0 "familiar: the lead's override admits the B60 bench, recorded"
fresh
check "$(claim gpu0:0 --lane luna-refurb --until 1h --peak-ram 1000 --peak-vram 1000)" 0 "release setup"
check "$(rc G reverie-gems@jp release gpu0:0)" 77 "a lane with no claim on the card has nothing to release (77)"
check "$(rc G reverie-gems@jp release gpu0:0 --lane luna-refurb)" 77 "only a granter releases another lane's claim"
check "$(rc G luna-refurb@jp release gpu0:0)" 0 "the holder releases its own claim"

# ── 6. the guard's decision ──────────────────────────────────────────────────────────────────────
fresh
claim gpu1:1 --lane drift-gems --until 2h --peak-ram 2878 --peak-vram 3000 >/dev/null
claim katana:0 --lane reverie-gems --until 2h --peak-ram 3000 --peak-vram 3000 >/dev/null
decide() {  # decide <agent-id> <config> <command> -> action
  jq -nc --arg c "$3" '{tool_name:"Bash", tool_input:{command:$c}}' \
    | DREAMTEAM_AGENT_ID="$1" DREAMTEAM_CONFIG="$2" python3 "$LIB" guard | jq -r .action
}
cards() {  # the cards detect names; every command checked here is replayed through the real wrapper in section 7
  local r; r=$(DREAMTEAM_AGENT_ID=x python3 "$LIB" detect "$1" | jq -r '(.cards + (.host_any | map(. + ":*"))) | join(",")')
  if [ -n "$r" ]; then printf '%s\0' "$1" >> "$TMP/positives"; else printf '%s\0' "$1" >> "$TMP/negatives"; fi
  echo "$r"
}
E="$TMP/enforce.json"
# positive controls: each is a launch, attributed to the right card
check "$(cards 'ssh -o ConnectTimeout=10 gpu1 "cd /var/tmp/fwork/gems && CUDA_VISIBLE_DEVICES=1 python stage2_train.py"')" "gpu1:1" "detect: CUDA_VISIBLE_DEVICES=1 over ssh -> gpu1:1"
check "$(cards 'HOST=gpu0 lanes/drift/gpu1_launch.sh 0 A g0-S3-x --loss dwt')" "gpu0:0" "detect: HOST=gpu0 gpu1_launch.sh 0 -> gpu0:0"
check "$(cards 'lanes/drift/gpu1_launch.sh 1 B g1-S3-x --seeds 6')" "gpu1:1" "detect: gpu1_launch.sh 1 (default HOST) -> gpu1:1"
check "$(cards 'ssh familiar ~/Projects/x/tools/safe_run.sh --protected 6G .venv/bin/python train.py')" "familiar:0" "detect: safe_run --protected on familiar -> familiar:0 (the B60 is compute-blocked)"
check "$(cards 'tools/guest_run.sh --mem 4G -- python ssl.py')" "katana:0" "detect: guest_run with a GPU cap on katana -> katana:0"
check "$(cards 'CUDA_VISIBLE_DEVICES=0 python -m train')" "katana:0" "detect: a local CUDA_VISIBLE_DEVICES=0 -> katana:0"
check "$(cards 'ssh gpu1 python3 train.py')" "gpu1:*" "detect: a GPU program (train.py) on gpu1 with no index -> any gpu1 card"
check "$(cards 'ssh familiar "ZE_AFFINITY_MASK=0 python bench.py"')" "familiar:xpu0" "detect: ZE_AFFINITY_MASK=0 on familiar -> familiar:xpu0"
check "$(cards 'docker run --rm --gpus all -m 8g lostintranscription/audit:latest')" "katana:0" "detect: docker run --gpus all on katana -> katana:0 (luna's audits, vesper's verify windows)"
check "$(cards 'ssh gpu1 docker run --rm --gpus device=1 img:latest')" "gpu1:1" "detect: docker run --gpus device=1 on gpu1 -> gpu1:1"
check "$(cards 'ssh gpu1 docker run --rm --gpus all img:latest')" "gpu1:0,gpu1:1" "detect: --gpus all on gpu1 takes both cards"
check "$(cards 'docker run --rm --runtime=nvidia img')" "katana:0" "detect: docker --runtime=nvidia -> katana:0"
# negative controls: reads and non-GPU work are not launches (the guard must not be vacuous either way)
for c in 'nvidia-smi' 'ssh gpu1 nvidia-smi --query-gpu=memory.used --format=csv' 'ssh gpu1 tail -f /var/tmp/fwork/gems/runs/x.log' \
         'dreamteam gpu board' 'python3 analyze.py' 'ssh familiar python3 palace_stats.py' 'tools/guest_run.sh --gpu-mem 0 --mem 2G -- make' \
         'ssh familiar tools/safe_run.sh 3G python sweep.py' 'CUDA_VISIBLE_DEVICES= python cpu_only.py' \
         'docker run --rm -v /x:/x alpine ls' 'docker ps --filter status=running' 'docker logs lit-audit-1'; do
  check "$(cards "$c")" "" "not a launch: $c"
done
check "$(cards 'ssh "$HOST" "CUDA_VISIBLE_DEVICES=0 python x.py"')" "" "an ssh to an unresolved host fails OPEN (never blames the wrong card)"
# decisions
check "$(decide drift-gems@jp "$E" 'ssh gpu1 "CUDA_VISIBLE_DEVICES=1 python train.py"')" allow "enforce: the holder launches on its card"
check "$(decide drift-gems@jp "$E" 'ssh gpu1 "CUDA_VISIBLE_DEVICES=0 python train.py"')" block "enforce: the same lane on a card it does not hold is BLOCKED"
check "$(decide luna-refurb@jp "$E" 'ssh gpu1 python3 train.py')" block "enforce: a GPU program on gpu1 with no claim there is blocked"
check "$(decide drift-gems@jp "$E" 'ssh gpu1 python3 train.py')" allow "enforce: a lane holding any gpu1 card may run an unindexed GPU program there"
check "$(decide luna-refurb@jp "$E" 'dreamteam gpu run --card gpu1:0 -- python x.py')" allow "gpu run passes the guard (it checks the claim itself)"
check "$(decide luna-refurb@jp "$E" 'nvidia-smi')" allow "a read is always allowed"
check "$(decide "" "$E" 'ssh gpu1 "CUDA_VISIBLE_DEVICES=0 python x.py"')" allow "an orchestrator (no --agent-id) is never blocked (fail open)"
check "$(decide luna-refurb@jp "$TMP/warn.json" 'ssh gpu1 "CUDA_VISIBLE_DEVICES=0 python x.py"')" warn "warn mode: the would-block is a warn"
grep -q '"luna-refurb@jp"' "$TMP/state/guard.log" 2>/dev/null && pass "warn mode logs the would-block line" || fail "no guard.log line"
check "$(decide luna-refurb@jp "$TMP/empty.json" 'ssh gpu1 "CUDA_VISIBLE_DEVICES=0 python x.py"')" warn "a missing gpu.guard is warn, never off"
check "$(decide luna-refurb@jp "$TMP/off.json" 'ssh gpu1 "CUDA_VISIBLE_DEVICES=0 python x.py"')" allow "off disables the check"

# ── 6b. v1.3: a launch is where a shell RUNS it, never where it is mentioned ───────────────────────
# The replay of 2026-09-29 (3560 lane commands) found ~100 of v1.2's 125 would-blocks were reads and edits that
# named a launcher. Each class below is one of them, with fictional paths; the positives are the real launch forms.
NL=$'\n'
for c in 'cat tools/gpu1_launch.sh; sed -n 1,60p tools/guest_run.sh; grep -n obs tools/guest_run.sh' \
         'cp -p run_exp.sh run_exp.sh.new && scp -q run_exp.sh gpu0:/work/tools/ && sha256sum run_exp.sh' \
         "cat > run.sh <<'EOF'${NL}CUDA_VISIBLE_DEVICES=0 python stage2_train.py${NL}EOF" \
         "git commit -q -F - <<'EOF'${NL}feat: docker run --gpus all and guest_run.sh --gpu-mem 3 are detected${NL}EOF" \
         "python3 - <<'PY'${NL}s = 'CUDA_VISIBLE_DEVICES=1 python train.py'${NL}PY" \
         "jq -nc --arg c 'ssh gpu1 \"CUDA_VISIBLE_DEVICES=0 python probe.py\"' '{c:\$c}'" \
         "ssh gpu1 'ps -eo pid,args | grep -E \"run_exp|stage2_train\" | grep -v grep'" \
         "until ssh gpu1 'test -s /work/runs/done.log'; do sleep 60; done" \
         "ssh gpu0 'cd /work && /work/tools/safe_run.sh 4G env OMP_NUM_THREADS=1 .venv/bin/python build_stack.py --out x.tif'" \
         "ssh gpu0 '.venv/bin/python -c \"import rasterio; print(rasterio.open(\\\"x.tif\\\").count)\"'" \
         "cat >> NOTES.md <<'EOF'${NL}- katana: tools/guest_run.sh --mem 6G --gpu-mem 3 -- queue.sh${NL}EOF" \
         'bash -n tools/run_exp.sh && echo ok' \
         'diff <(sed -n 1,40p a/guest_run.sh) <(sed -n 1,40p b/guest_run.sh)' \
         "ssh gpu1 'CUDA_VISIBLE_DEVICES= python train.py'" "ssh gpu1 'python train.py --device cpu'" \
         'ssh gpu1 python3 run.py' 'ssh gpu1 .venv/bin/python train.py --help' \
         'docker run --rm img:latest python x.py --gpus all' 'CUDA_VISIBLE_DEVICES=0 nvidia-smi' \
         'tools/../../../tools/guest_run.sh --help 2>&1 | head -0' \
         'arr=(guest_run.sh run_exp.sh); echo "${arr[@]}"' 'declare -a Q=(run_exp.sh gpu1_launch.sh); printf "%s\n" "${Q[@]}"' 'L+=(tools/gpu1_launch.sh)' "ssh familiar '/work/tools/safe_run.sh --protected 64M true; echo exit \$?'"; do
  check "$(cards "$c")" "" "v1.3 not a launch: ${c%%$NL*}"
done
check "$(cards "(FEATURES=f.tif setsid nohup tools/guest_run.sh --mem 6G --gpu-mem 3 -- queue.sh a b > q.log 2>&1 &)")" "katana:0" "v1.3 launch: a detached guest_run queue in a subshell"
check "$(cards "ssh gpu1 'cd /work; CUDA_VISIBLE_DEVICES=1 FEATURES=x setsid nohup bash /work/queue.sh rad6 > log 2>&1 &'")" "gpu1:1" "v1.3 launch: CUDA_VISIBLE_DEVICES=1 in front of a remote queue script"
check "$(cards "ssh gpu0 'cd /work && cat > runs/bench.sh <<\"EOF\"${NL}#!/bin/bash${NL}CUDA_VISIBLE_DEVICES=0 python stage2_train.py --seed 0${NL}EOF${NL}setsid nohup bash runs/bench.sh > runs/bench.log 2>&1 &'")" "gpu0:0" "v1.3 launch: a bench script written by a heredoc and run by the same command"
check "$(cards "ssh familiar \"CUDA_VISIBLE_DEVICES=0 PYTHONUNBUFFERED=1 setsid nohup systemd-inhibit --what=sleep --mode=block .venv/bin/python cache.py > log 2>&1 &\"")" "familiar:0" "v1.3 launch: CUDA_VISIBLE_DEVICES=0 through setsid, nohup and systemd-inhibit"
check "$(cards "ssh gpu0 'OMP_NUM_THREADS=4 /work/tools/safe_run.sh 3G .venv/bin/python dino_features.py --out smoke.tif'")" "gpu0:0" "v1.3 launch: a GPU program (dino_features.py) under an unprotected cap"
check "$(cards "ssh gpu1 bash -s <<'EOF'${NL}export CUDA_VISIBLE_DEVICES=0${NL}python stage2_train.py${NL}EOF")" "gpu1:0" "v1.3 launch: a heredoc fed to a remote shell, with an exported index"
check "$(cards 'P=.venv/bin/python; ssh gpu1 "CUDA_VISIBLE_DEVICES=1 $P train.py"')" "gpu1:1" "v1.3 launch: the index in front of a variable program"
# device kinds and the GEMS classes in fleet.json guard (morpheus-gems 12:1x): a CUDA job gets a CUDA card, an XPU
# job the B60; named GPU wrappers count when unreadable; CPU programs never count; --device on a launcher names the card
check "$(cards 'ssh familiar "python bench.py --device xpu"')" "familiar:xpu0" "kinds: --device xpu with no index is the B60, not familiar's CUDA card"
check "$(cards 'ssh familiar "CUDA_VISIBLE_DEVICES=1 python bench.py --device xpu"')" "familiar:xpu0" "kinds: a CUDA index does not move an XPU job"
check "$(cards 'ssh familiar bash /work/lanes/xpu/b60_bench.sh')" "familiar:xpu0" "gpu_scripts: b60_bench.sh (unreadable, run on familiar) is an XPU launch"
check "$(cards 'ssh gpu0 bash /work/lanes/whacky/chain45.sh')" "gpu0:0" "gpu_scripts: chain45.sh run on gpu0 is a GPU launch by name"
check "$(cards 'ssh gpu1 "CUDA_VISIBLE_DEVICES=1 bash tools/queue_stack_seeds.sh a b"')" "gpu1:1" "gpu_scripts: a named wrapper takes its CUDA index"
check "$(cards "ssh familiar 'S=/work/tools/safe_run.sh; \"\$S\" --protected 10G /usr/bin/time -v -o t.time bash /work/run_exp_xpu.sh A m --device xpu --epochs 1'")" "familiar:xpu0" "safe_run --protected defers to its command: --device xpu through an unread script is the B60 (drift's b60_bench.sh)"
check "$(cards 'ssh gpu1 bash /work/unknown.sh --device cuda:1')" "gpu1:1" "an unread script told --device cuda:1 is a launch on that card"
check "$(cards "ssh familiar '/work/tools/safe_run.sh --protected 6G env ZE_AFFINITY_MASK=0 python bench.py'")" "familiar:xpu0" "safe_run --protected: the wrapped command's own card wins (no extra CUDA default)"
check "$(cards "ssh familiar '/work/tools/safe_run.sh --protected 6G env OMP_NUM_THREADS=1 bash /work/unread.sh'")" "familiar:0" "safe_run --protected with env and an unread script is still a training run (env is a wrapper, not a read)"
check "$(cards "ssh familiar '/work/tools/safe_run.sh --protected 64M env X=1 true'")" "" "safe_run --protected wrapping env … true is a smoke test"
check "$(cards 'ssh gpu0 python3 /work/lanes/reverie/tools/stage2_train_rv.py')" "gpu0:0" "gpu_programs: stage2_train_rv.py matches the stage2_train prefix"
for c in 'CUDA_VISIBLE_DEVICES=0 python ens_eval.py' "ssh gpu0 'CUDA_VISIBLE_DEVICES=0 python build_stacks.py --out x.tif'" \
         'ssh gpu1 bash /work/unknown.sh --epochs 3' 'grep -n -- "--device cuda" tools/run_exp.sh'; do
  check "$(cards "$c")" "" "kinds/classes not a launch: $c"
done
# a local chain script followed two levels: chain.sh -> gpu_run.sh -> ssh gpu1 (vesper's chain-nh.sh, 09-29)
mkdir -p "$TMP/chain"
printf '#!/usr/bin/env bash\nset -u\n./gpu_run.sh 1 nh-C\n' > "$TMP/chain/chain.sh"
printf '#!/usr/bin/env bash\nssh gpu1 "cd /work && CUDA_VISIBLE_DEVICES=1 nohup .venv/bin/python train.py --tag $2 > log 2>&1 &"\n' > "$TMP/chain/gpu_run.sh"
check "$(cards "cd $TMP/chain && nohup bash chain.sh > chain.log 2>&1 &")" "gpu1:1" "v1.3 launch: a local chain script followed to the ssh it runs (two levels)"
check "$(cards "cat $TMP/chain/chain.sh $TMP/chain/gpu_run.sh")" "" "v1.3 not a launch: reading the same two scripts"
# a script copied to the host by the same command, then chained there behind GEMS's queue_after.sh (drift, 09-29)
printf '#!/usr/bin/env bash\nG=/work; PY=$G/.venv/bin/python; SAFE=$G/tools/safe_run.sh\nexport CUDA_VISIBLE_DEVICES=0 OMP_NUM_THREADS=4\n"$SAFE" 3G /usr/bin/time -v -o t.time "$PY" dino_features.py --device cuda --batch 32\n' > "$TMP/chain/run_infer.sh"
check "$(cards "cd $TMP/chain && scp -q run_infer.sh gpu0:/work/lanes/ && ssh gpu0 'cd /work && nohup setsid bash tools/queue_after.sh runs/bench.log \"BENCH_DONE\" env CAP=4G bash lanes/run_infer.sh > q.log 2>&1 &'")" "gpu0:0" "v1.3 launch: a script scp'd to gpu0 and run there behind queue_after.sh is followed"
check "$(cards "ssh gpu0 'cd /work && nohup setsid bash tools/queue_after.sh runs/bench.log \"BENCH_DONE\" bash lanes/run_infer.sh > q.log 2>&1 &'")" "" "v1.3 known limit: an unreadable remote script with no GPU evidence is not a launch (the board catches it)"
check "$(cards "cd $TMP/chain && cat > fresh_idea.sh <<'EOF'${NL}#!/usr/bin/env bash${NL}CUDA_VISIBLE_DEVICES=1 python stage2_train.py${NL}EOF${NL}scp -q fresh_idea.sh gpu1:/work/tools/ && ssh gpu1 'setsid nohup bash /work/tools/fresh_idea.sh > /dev/null 2>&1 &'")" "gpu1:1" "v1.3 launch: written by heredoc, scp'd and run in ONE call (the file is not on disk yet at hook time)"
s0=$(date +%s%N); r=$(DREAMTEAM_AGENT_ID=x python3 "$LIB" detect "cat > loop.sh <<'EOF'${NL}bash loop.sh${NL}EOF${NL}bash loop.sh" | jq -r '"\(.launch) \(.why)"'); ms=$(( ($(date +%s%N) - s0) / 1000000 ))
check "$r" "false " "v1.3: a script that runs itself is bounded by MAX_DEPTH (not a launch, and no parse-error fail-open)"
deep=$(python3 -c 'print("echo " + "$(echo " * 150 + "x" + ")" * 150)')
check "$(DREAMTEAM_AGENT_ID=x python3 "$LIB" detect "$deep" | jq -r '"\(.launch) \(.why)"')" "false " "v1.3: 150 nested \$(…) parse (no parse-error fail-open)"
check "$(DREAMTEAM_AGENT_ID=x python3 -c 'import sys, json; sys.path.insert(0, sys.argv[1]); import gpu_detect as g; print(g.detect(None, json.load(open(sys.argv[2])), "katana", "/")["launch"])' "$ROOT/scripts/lib" "$ROOT/gpu/fleet.json")" "False" "v1.3: an empty command is not a launch"
[ "$ms" -lt 3000 ] && pass "v1.3: the self-running script is decided in ${ms} ms (< 3 s; the hook's timeout is 4 s)" || fail "self-running script took ${ms} ms"
[ ! -e "$TMP/chain/fresh_idea.sh" ] && pass "v1.3: that control never wrote the file (the heredoc body alone was read)" || fail "fresh_idea.sh exists: the control is vacuous"

# ── 6c. `dreamteam gpu replay`: the warn-phase instrument has its own positive control ────────────────
# Hooks load at session start, so lanes alive before the guard never log; the replay reads their transcripts instead.
P="$TMP/proj/-work-lane"; mkdir -p "$P"
line() { jq -nc --arg who "$1" --arg c "$2" --arg id "$3" \
  '{type:"assistant", agentName:(if $who == "" then null else $who end), teamName:"t", cwd:"/work",
    timestamp:"2026-09-29T12:00:00Z", message:{content:[{type:"tool_use", id:$id, name:"Bash", input:{command:$c}}]}}'; }
{ line fixture-lane "ssh gpu1 'CUDA_VISIBLE_DEVICES=1 nohup python train.py > t.log 2>&1 &'" a1
  line fixture-lane 'cat tools/gpu1_launch.sh' a2
  line fixture-lane 'cat tools/gpu1_launch.sh' a2                      # a resumed transcript repeats a line
  line "" "CUDA_VISIBLE_DEVICES=0 python train.py" a3; } > "$P/s.jsonl"   # an orchestrator: passes by design
out=$(python3 "$ROOT/scripts/lib/gpu_replay.py" --projects "$TMP/proj" --since '2026-09-29 00:00' --until '2026-09-30 00:00' --plugin "$ROOT" 2>&1)
case "$out" in *"calls in the window: **2**"*) pass "replay: counts the lane's 2 calls once each, skips the orchestrator" ;; *) fail "replay calls: $(echo "$out" | sed -n 3p)" ;; esac
case "$out" in *"would-block with no claims seeded): **1**"*) pass "replay: the one launch is a would-block, the read is not" ;; *) fail "replay launches: $(echo "$out" | sed -n 5p)" ;; esac
case "$out" in *"[gpu1:1] (CUDA_VISIBLE_DEVICES=1"*) pass "replay: names the lane's card" ;; *) fail "replay card: $out" ;; esac
case "$(DREAMTEAM_AGENT_ID=x python3 "$LIB" replay --projects "$TMP/proj" --since '2026-09-29 00:00' --until '2026-09-30 00:00' 2>&1)" in
  *"would-block with no claims seeded): **1**"*) pass "replay: reachable as \`dreamteam gpu replay\`" ;; *) fail "replay subcommand" ;; esac

# ── 6d. the board's guard section: which lanes the hook cannot reach, and the incremental replay ───────
fresh
P2="$TMP/proj2/-work-lane"; mkdir -p "$P2"; T="$P2/s.jsonl"
{ line lane-a "ssh gpu1 'CUDA_VISIBLE_DEVICES=1 nohup python train.py > t.log 2>&1 &'" b1
  line lane-a 'cat tools/gpu1_launch.sh' b2; } > "$T"
gs() { (cd "$ROOT/scripts/lib" && DREAMTEAM_GPU_PROJECTS="$TMP/proj2" DREAMTEAM_AGENT_ID=x \
        python3 -c 'import json, gpu_fleet as g; print(json.dumps(g.guard_status(g.load_fleet(), g.load_config())))'); }
SESS='[{"pid":11,"agent":"old-lane@t","start":1000},{"pid":12,"agent":"new-lane@t","start":3000},{"pid":13,"agent":"","start":500}]'
out=$(DREAMTEAM_GPU_SESSIONS="$SESS" DREAMTEAM_GPU_HOOK_SINCE=2000 gs)
check "$(echo "$out" | jq -r '[.unguarded[].agent] | join(",")')" "old-lane@t" "guard: a lane started before the hook is unguarded, one after is guarded, an orchestrator is no lane"
check "$(echo "$out" | jq -r '.lane_sessions')" "2" "guard: two lane sessions (the orchestrator is not one)"
check "$(DREAMTEAM_GPU_SESSIONS="$SESS" DREAMTEAM_GPU_HOOK_SINCE=none gs | jq -r '.unguarded | length')" "2" "guard: an unknown hook arrival counts every lane unguarded (never a false 'all guarded')"
check "$(echo "$out" | jq -r '"\(.replay.calls) \(.replay.blocks | length)"')" "2 1" "guard: the board's replay finds the one launch in two lane calls"
# incremental: one new complete line, and one still being written
line lane-b "CUDA_VISIBLE_DEVICES=0 python train.py" b3 >> "$T"
line lane-b 'tools/guest_run.sh --mem 4G -- q.sh' b4 | tr -d '\n' >> "$T"          # no newline yet: mid-write
out=$(DREAMTEAM_GPU_SESSIONS='[]' DREAMTEAM_GPU_HOOK_SINCE=2000 gs)
check "$(echo "$out" | jq -r '"\(.replay.calls) \(.replay.blocks | length)"')" "3 2" "replay cache: the new complete line is read, the partial one waits"
part=$(line lane-b 'tools/guest_run.sh --mem 4G -- q.sh' b4 | tr -d '\n' | wc -c)
check "$(jq -r --arg f "$T" '.offsets[$f][1]' "$TMP/state/replay-cache.json")" "$(( $(stat -c %s "$T") - part ))" "replay cache: the offset stops at the end of the last complete line"
echo >> "$T"
out=$(DREAMTEAM_GPU_SESSIONS='[]' DREAMTEAM_GPU_HOOK_SINCE=2000 gs)
check "$(echo "$out" | jq -r '"\(.replay.calls) \(.replay.blocks | length)"')" "4 3" "replay cache: the finished line is read once"
check "$(jq -r --arg f "$T" '.offsets[$f][1]' "$TMP/state/replay-cache.json")" "$(stat -c %s "$T")" "replay cache: the offset reaches the end of the file"
line lane-a 'cat tools/gpu1_launch.sh' b2 > "$T.new" && mv "$T.new" "$T"            # rewritten, shorter
out=$(DREAMTEAM_GPU_SESSIONS='[]' DREAMTEAM_GPU_HOOK_SINCE=2000 gs)
check "$(echo "$out" | jq -r '"\(.replay.calls) \(.replay.blocks | length)"')" "1 0" "replay cache: a replaced transcript rebuilds the cache (no stale rows)"
# the board prints it
b=$(DREAMTEAM_GPU_PROJECTS="$TMP/proj2" DREAMTEAM_GPU_SESSIONS="$SESS" DREAMTEAM_GPU_HOOK_SINCE=2000 G x board 2>&1)
case "$b" in *"1 of 2 lane sessions unguarded"*"old-lane"*"would-blocks since"*) pass "board: the guard section lists the unguarded lane and the would-blocks" ;; *) fail "board guard section: $(echo "$b" | grep -A3 ' guard ')" ;; esac
# hook arrival from a real reflog
R="$TMP/hookrepo"; mkdir -p "$R/hooks"; gc() { git -C "$R" -c user.email=t@example.invalid -c user.name=t commit -q "$@"; }
git -C "$R" init -q && gc --allow-empty -m init && echo '{"hooks":{}}' > "$R/hooks/hooks.json" && git -C "$R" add hooks/hooks.json && gc -m "no guard"
ha() { (cd "$ROOT/scripts/lib" && env -u DREAMTEAM_GPU_HOOK_SINCE python3 -c 'import sys, gpu_fleet as g; print(g.hook_arrival(sys.argv[1]))' "$1"); }
check "$(ha "$R")" "None" "hook arrival: a checkout whose hooks.json never named the guard -> None"
tb=$(date +%s); echo '{"hooks":{"x":"bash gpu-guard.sh"}}' > "$R/hooks/hooks.json"; gc -am "add the guard"; ta=$(date +%s)
v=$(ha "$R"); v=${v%.*}
[ "$v" -ge "$tb" ] 2>/dev/null && [ "$v" -le "$ta" ] && pass "hook arrival: the reflog time HEAD first held the guard" || fail "hook arrival: got '$v', want $tb..$ta"

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
payload 'docker run --rm --gpus all -m 8g audit:latest' | DREAMTEAM_AGENT_ID=luna-refurb@jp DREAMTEAM_CONFIG="$E" bash "$W" 2>/dev/null
check "$?" 2 "wrapper: a docker --gpus launch reaches the decision through the pre-filter (enforce blocks it)"
echo 'not json' | DREAMTEAM_AGENT_ID=luna-refurb@jp DREAMTEAM_CONFIG="$E" bash "$W" 2>/dev/null
check "$?" 0 "wrapper: a malformed payload fails open"
# every command the detect checks above called a launch must reach the decision THROUGH the pre-filter (so the
# pre-filter stays a superset of detect), and every non-launch must pass; luna-refurb holds no card here
np=0; bad=""
while IFS= read -r -d '' c; do
  np=$((np + 1)); payload "$c" | DREAMTEAM_AGENT_ID=luna-refurb@jp DREAMTEAM_CONFIG="$E" bash "$W" 2>/dev/null
  r=$?; [ "$r" = 2 ] || [ "$c" = 'dreamteam gpu run --card gpu1:0 -- python x.py' ] || bad="$bad | $r: ${c%%$'\n'*}"
done < "$TMP/positives"
check "${bad:-none}" none "wrapper: all $np detected launches are blocked through the pre-filter (enforce, no claim)"
nn=0; bad=""
while IFS= read -r -d '' c; do
  nn=$((nn + 1)); payload "$c" | DREAMTEAM_AGENT_ID=luna-refurb@jp DREAMTEAM_CONFIG="$E" bash "$W" 2>/dev/null
  r=$?; [ "$r" = 0 ] || bad="$bad | $r: ${c%%$'\n'*}"
done < "$TMP/negatives"
check "${bad:-none}" none "wrapper: all $nn non-launches pass (reads, edits, heredocs, CPU jobs)"

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
check "$(rc G drift-gems@jp run --card gpu1:1 --peak-ram 9000 --dry-run -- python x.py)" 75 "run: a peak above the claim re-runs the pair rule (9000 + 1536 > 10444)"

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
labels=$(cd "$ROOT/scripts/lib" && python3 -c '
import gpu_fleet as g
names = ["/opt/brave.com/brave/brave --type=gpu-process --render-node-override=/dev/dri/renderD128 --crashpad-handler-pid=7",
         "/usr/bin/gnome-control-center", "python", "[Not Found]", ""]
print(",".join(g.proc_label(n) for n in names))')
check "$labels" "brave,gnome-control-center,python,[Not Found],?" "board: a process is labelled by its program, not by the tail of a Chromium command line (renderD128 --crashpad…)"

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

# ── 11. the call watcher: a stand-in camera (never the real one), OBS vs a second reader ───────────
CW="$ROOT/scripts/gpu/callwatch.sh"; C="$TMP/cam"; mkdir -p "$C"; : > "$C/video9"
DS="$TMP/dockstub"; mkdir -p "$DS"; DREC="$TMP/docker.rec"; : > "$DREC"
cat > "$DS/docker" <<STUB
#!/usr/bin/env bash
case "\$1" in
  ps) printf 'gpu-box\nweb-box\n' ;;
  inspect) case "\$*" in *"{{.Name}}"*) echo "/runtime-box" ;; *) [ "\${@: -1}" = gpu-box ] && echo '[{"Driver":"nvidia","Count":-1}]' || echo null ;; esac ;;
  pause|unpause|kill) echo "\$1 \$2" >> "$DREC" ;;
esac
STUB
chmod +x "$DS/docker"
# a GPU compute pid (4711) whose cgroup is a docker scope: a container started with --runtime=nvidia (no DeviceRequests)
mkdir -p "$C/proc/4711"; echo "0::/system.slice/docker-$(printf 'ab%.0s' {1..32}).scope" > "$C/proc/4711/cgroup"
echo "4711, 6000" > "$DS/apps"; echo 4000 > "$DS/free"
cat > "$DS/nvidia-smi" <<SMI
#!/bin/sh
case "\$*" in
  *query-compute-apps=pid,used_memory*) cat "$DS/apps" ;;
  *query-compute-apps=pid*) cut -d, -f1 "$DS/apps" ;;
  *query-gpu=memory.free*) cat "$DS/free" ;;
esac
SMI
chmod +x "$DS/nvidia-smi"
cw() { CALLWATCH_DEVS="$C/video9" CALLWATCH_PAUSE="$C/pause" CALLWATCH_STATE="$C/state" CALLWATCH_LOG="$C/log" \
       CALLWATCH_CALM_S=0 CALLWATCH_DOCKER="$DS/docker" CALLWATCH_NVIDIA_SMI="$DS/nvidia-smi" CALLWATCH_CGROUP_ROOT="$C/proc" \
       bash "$CW" --once; }
# the stand-in OBS: ONE process whose comm is "obs" holding the device (prctl PR_SET_NAME). A copy of
# sleep named obs does not work here: sleep is a multi-call coreutils binary, and `obs` exits at once
# with "unknown program" -- which made this negative control vacuous until it was perturbed (2026-09-29).
python3 -c 'import ctypes, sys, time; ctypes.CDLL(None).prctl(15, b"obs", 0, 0, 0); f = open(sys.argv[1]); time.sleep(60)' "$C/video9" & OBSP=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ "$(cat /proc/$OBSP/comm 2>/dev/null)" = obs ] && break; sleep 0.1; done
[ "$(cat /proc/$OBSP/comm 2>/dev/null)" = obs ] && pass "callwatch fixture: the stand-in OBS runs, holding the device, comm obs" || fail "stand-in OBS did not start"
cw; [ ! -e "$C/pause" ] && pass "callwatch: OBS alone holding the camera is NOT a call (no pause)" || fail "callwatch paused on OBS alone"
sleep 60 3<"$C/video9" & CALLP=$!; sleep 0.3
cw; head -c 9 "$C/pause" 2>/dev/null | grep -qx callwatch && pass "callwatch: a second, non-OBS reader is a call: the pause file appears (ours)" || fail "no pause on a call"
grep -qx "pause gpu-box" "$DREC" && ! grep -q "web-box" "$DREC" && pass "callwatch: only the GPU container is docker-paused" || fail "docker pause: $(cat "$DREC")"
grep -qx "kill runtime-box" "$DREC" && ! grep -qx "pause runtime-box" "$DREC" && pass "callwatch: a container holding 6000 MiB (found via its pid, no DeviceRequests) is KILLED on a call: a paused one keeps its VRAM" || fail "heavy container not killed: $(cat "$DREC")"
kill $CALLP; wait $CALLP 2>/dev/null
cw; [ -e "$C/pause" ] && pass "callwatch: the call ended, but the pause holds for the calm period" || fail "cleared with no calm"
cw; [ ! -e "$C/pause" ] && pass "callwatch: after the calm period our pause file is removed" || fail "pause not cleared"
grep -qx "unpause gpu-box" "$DREC" && ! grep -qx "unpause runtime-box" "$DREC" && pass "callwatch: only the container it paused is unpaused (not the killed one)" || fail "docker unpause: $(cat "$DREC")"
echo "manual pause by the lead" > "$C/pause"; : > "$DREC"
sleep 60 3<"$C/video9" & CALLP=$!; sleep 0.3; cw; kill $CALLP; wait $CALLP 2>/dev/null; cw; cw
[ "$(cat "$C/pause")" = "manual pause by the lead" ] && pass "callwatch: a pause file it did not write is never touched or removed" || fail "foreign pause file changed"
kill $OBSP; wait $OBSP 2>/dev/null
: > "$DREC"; rm -f "$C/state" "$C/state.containers" "$C/pause"; echo 300 > "$DS/free"
cw; grep -qx "kill runtime-box" "$DREC" && pass "callwatch: with no call, free VRAM 300 < 512 MiB kills the biggest GPU container (JP's desktop first)" || fail "low-VRAM kill: $(cat "$DREC")"
: > "$DREC"; echo 4000 > "$DS/free"
cw; [ ! -s "$DREC" ] && pass "callwatch: ample free VRAM and no call touch nothing (negative control)" || fail "acted with no call: $(cat "$DREC")"

echo ""
echo "test-gpu: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
