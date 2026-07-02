---
description: One-command OOM/incident forensics — oomd kills, plugin traces, roster, scope, memory.
argument-hint: "[--since \"24 hours ago\"]"
---

Run the incident forensics bundle and interpret it:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/incident-report.sh" $ARGUMENTS
```

Read the output as a timeline: systemd-oomd kills (the usual killer — cgroup-level,
absent from `journalctl -k`), then the plugin's own pre-crash traces (dreamteam.log
footprints and events.log lifecycle events narrow the window), then current state
(roster liveness, containment scope, crash marker, memory). Lead your summary with
WHAT killed WHAT and WHEN; map the pre-kill spawn/growth sequence against the
admission gate's decisions; flag any crash marker (means recovery steps in
`docs/postmortem-2026-06-30.md` §5 apply — check worktrees for uncommitted work
before touching branches).
