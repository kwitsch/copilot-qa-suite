#!/usr/bin/env bash
# SessionStart hook: compile layered JSON config to a session env-file.
#
# Reads defaults.json + user config.json + project copilot-qa-suite.json,
# resolves all CFG_* values per hook (excluding ENV-var overrides — those
# stay dynamic at hook-runtime), and writes a sourceable bash env-file
# under ${CLAUDE_PLUGIN_DATA}/session/<project-sha>.env.
#
# PostToolUse hooks then `source` this file (cheap) instead of forking jq
# 60-180× per Edit.
#
# Atomic write via mktemp+mv. Re-run on every SessionStart; load_config
# additionally compares source mtimes at hook-runtime and falls back to
# the slow jq-layered path on staleness.
#
# Always exits 0 — SessionStart must not block startup.

set -euo pipefail

source "${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}/hooks/lib/config.sh"

# Function provided by config.sh. Returns 0 on success, 1 on any error
# (silent — slow path will pick up the slack on next load_config).
if compile_session_env 2>/dev/null; then
  printf '{}\n'
else
  printf '{}\n'
fi
exit 0
