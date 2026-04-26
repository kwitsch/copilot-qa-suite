#!/usr/bin/env bash
# SessionEnd hook: prune aged cache entries (b16/SessionEnd missing fix).
#
# Both cache and Copilot config dir grow unbounded otherwise:
#   - $CFG_CACHE_BASE/<hook>/*.{sha256,timestamp}: file-content shards
#   - $CFG_CONFIG_DIR/logs/: Copilot's own session logs
#
# Configurable via cleanup.cache_max_age_days (default 7) and
# cleanup.copilot_logs_max_age_days (default 14). Set to 0 to disable.
#
# Always exits 0 — session end must not be blocked.

set -euo pipefail

# Lib handles bash version re-exec internally
source "${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}/hooks/lib/config.sh"

# Load config to get the same paths the other hooks use
load_config "cleanup" 2>/dev/null || true

CACHE_AGE="$(_cfg_layered_get '.cleanup.cache_max_age_days' 2>/dev/null || true)"
CACHE_AGE="${CACHE_AGE:-7}"

LOGS_AGE="$(_cfg_layered_get '.cleanup.copilot_logs_max_age_days' 2>/dev/null || true)"
LOGS_AGE="${LOGS_AGE:-14}"

# Prune cache shards
if [[ "$CACHE_AGE" != "0" ]]; then
  for hook in code-review unittest proguard; do
    cache_dir="$(_cfg_cache_dir "$hook")"
    if [[ -d "$cache_dir" ]]; then
      find "$cache_dir" -type f \( -name '*.sha256' -o -name '*.timestamp' \) \
        -mtime "+$CACHE_AGE" -delete 2>/dev/null || true
    fi
  done
fi

# Prune Copilot's own logs in the plugin-private config dir
if [[ "$LOGS_AGE" != "0" ]]; then
  copilot_dir="$(_cfg_copilot_config_dir)"
  if [[ -d "$copilot_dir/logs" ]]; then
    find "$copilot_dir/logs" -type f -mtime "+$LOGS_AGE" -delete 2>/dev/null || true
  fi
fi

# Always silent — SessionEnd has no UI surface for status messages
printf '{}\n'
exit 0
