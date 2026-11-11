# Tooling friction ledger (JP 2026-11-10: fix the tooling as we go, like any artefact)

One row per time a hook, gate, plugin, skill, cron or palace query misfired, blocked wrongly or needed a workaround.
The fix lands in the tool's own repo (branch, PR, red test, self-merge). `/housekeep` flags rows older than 7 days;
the lead's 08:11 daily pass reports "tooling fixes shipped".

| Date | Tool | What happened | Fix |
|---|---|---|---|
| 2026-11-10 11:0x | dreamteam `scripts/mem-gate.sh` | Block message printed `agents=?`: the agent count runs after the budget block and is never passed to `block` | dreamteam PR (Sen, fix/mem-gate-agent-count) |
| 2026-11-10 07:2x | realm-cloud honeypot harness | `HOME="%h"` unexpanded in a script, leaving literal `%h/` dirs in money and the plan repo | lucid-honeypot, 11:07 slot |
| 2026-11-10 03:2x | claude-config `uci-c-needs-P-guard.sh` | New guard; 9 security-review rounds to make it fail closed | claude-config #38–#48 (shipped) |
| 2026-11-10 10:3x | plan `.gitignore` | trailing `# comment` on a pattern line ignored nothing | plan 147759c (shipped) |
| 2026-11-10 22:4x | `~/.claude/scripts/xreview` | a 123-line guide fact-check came back as `model: gpt-6.1-sol` and nothing else, exit 0, twice: the 4,000-token budget went to reasoning (`finish_reason: length`, empty content), which reads as a clean review | fixed by luna, claude-config #54 (16k budget, `XREVIEW_MAX_TOKENS`; empty → exit 6, cut off → exit 7); live 22:55 |
