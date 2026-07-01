#!/usr/bin/env bash
# Sync dreamteam source to the plugin cache.
# Run after editing plugin files so the next Claude Code session picks up changes.
set -euo pipefail

SRC="$HOME/Projects/dreamteam"
DST="$HOME/.claude/plugins/cache/dreamteam/dreamteam/1.0.0"

if [ ! -d "$SRC" ]; then
  echo "ERROR: source not found: $SRC" >&2
  exit 1
fi

mkdir -p "$DST"
rsync -a --delete --exclude='.git' --exclude='state/' --exclude='.claude-plugin/' \
  "$SRC/" "$DST/"

echo "Synced dreamteam plugin → $DST"
