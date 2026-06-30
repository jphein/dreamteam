---
description: Show the dreamteam memory budget, live agent count, and recent spawn footprint.
---

Run the memory budget reporter and the recent footprint trace. Use this before sizing a
spawn wave and any time you suspect memory pressure.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/mem-budget.sh"
echo "--- footprint trace (last 8 spawns) ---"
tail -n 8 "${CLAUDE_PLUGIN_ROOT}/state/dreamteam.log" 2>/dev/null || echo "no spawns logged yet"
```

Report the MAX-agents number, the room-for-N-more figure, whether the host is below
the floor, and any Waydroid warning. If the footprint trace shows total RSS climbing
toward the budget, freeze spawns and let in-flight agents finish + merge before adding
more (see the degradation tiers in the dreamteam skill).
