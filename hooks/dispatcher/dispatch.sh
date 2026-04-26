#!/usr/bin/env bash
# PostToolUse dispatcher (c1 fix).
#
# Replaces the four parallel hooks with a single entry that routes to the
# relevant reviewer based on file extension and project signals. Each
# reviewer still runs as a sub-shell with the same hard read-only Copilot
# invocation; only the fan-out is gone.
#
# Decisions:
#   - File path absent / invalid          -> exit 0 silently
#   - Generated/build path                -> exit 0 silently
#   - Gradle file (build.gradle*, libs.versions.toml, settings.gradle*)
#                                         -> proguard hook (only)
#   - Test file                           -> doc hook (only, tests need
#                                            comments after creation)
#   - Source file in a recognized lang    -> doc + code-review + unittest
#                                            run sequentially (NOT in parallel)
#   - Anything else                       -> exit 0 silently
#
# Sequential execution preserves per-hook independence (each can short-
# circuit on cache hit / rate limit) while eliminating the four-fold
# parallel cost.

set -euo pipefail

# Lib handles bash version re-exec internally
source "${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}/hooks/lib/config.sh"

INPUT="$(cat)"
TOOL_NAME="$(jq -r '.tool_name // empty' <<<"$INPUT")"
FILE_PATH="$(jq -r '.tool_input.file_path // empty' <<<"$INPUT")"

[[ -z "$FILE_PATH" ]] && exit 0
validate_file_path "$FILE_PATH" || exit 0

# Skip generated / build paths — same list as the per-hook scripts had.
case "$FILE_PATH" in
  */node_modules/*|*/build/*|*/dist/*|*/target/*|*/.next/*|*/vendor/*|*/generated/*) exit 0 ;;
  *.generated.*|*.g.dart|*_pb2.py|*.pb.go|*.min.js|*.bundle.js) exit 0 ;;
esac

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

# Forward stdin to a sub-hook by replaying the captured INPUT.
run_hook() {
  local script="$1"
  [[ -x "$script" ]] || return 0
  printf '%s' "$INPUT" | "$script" || true
}

is_gradle_file() {
  case "$FILE_PATH" in
    */build.gradle|*/build.gradle.kts) return 0 ;;
    */settings.gradle|*/settings.gradle.kts) return 0 ;;
    */libs.versions.toml|*/versions.toml) return 0 ;;
  esac
  return 1
}

is_test_file() {
  case "$FILE_PATH" in
    *Test.kt|*Tests.kt|*Spec.kt|*IT.kt) return 0 ;;
    *Test.java|*Tests.java|*IT.java) return 0 ;;
    *Test.scala|*Spec.scala) return 0 ;;
    *.test.ts|*.test.tsx|*.spec.ts|*.spec.tsx) return 0 ;;
    *.test.js|*.test.jsx|*.spec.js|*.spec.jsx) return 0 ;;
    */test_*.py|*_test.py) return 0 ;;
    *_test.go) return 0 ;;
    *_test.rs) return 0 ;;
    *Test.php|*Tests.php) return 0 ;;
    *_spec.rb|*_test.rb) return 0 ;;
    */tests/*|*/test/*|*/__tests__/*|*/spec/*) return 0 ;;
  esac
  return 1
}

# Concatenate JSON outputs from sub-hooks. Each sub-hook may emit either
# nothing, "{}", or a hookSpecificOutput object. We merge non-empty
# additionalContext blobs into a single combined response.
COMBINED_CTX=""
COMBINED_MSG=""

collect() {
  local out="$1" ctx msg
  [[ -z "$out" ]] && return 0
  ctx="$(jq -r '.hookSpecificOutput.additionalContext // empty' <<<"$out" 2>/dev/null || true)"
  msg="$(jq -r '.systemMessage // empty' <<<"$out" 2>/dev/null || true)"
  if [[ -n "$ctx" ]]; then
    COMBINED_CTX="${COMBINED_CTX:+$COMBINED_CTX

============================================================

}$ctx"
  fi
  if [[ -n "$msg" ]]; then
    COMBINED_MSG="${COMBINED_MSG:+$COMBINED_MSG · }$msg"
  fi
}

# Routing
if is_gradle_file; then
  collect "$(run_hook "$PLUGIN_ROOT/hooks/proguard/validate.sh")"
elif is_test_file; then
  # Tests: only the doc hook runs (adds comments after test creation)
  collect "$(run_hook "$PLUGIN_ROOT/hooks/doc/analyze-doc.sh")"
else
  # Source file: doc, then code-review, then unittest (sequential)
  collect "$(run_hook "$PLUGIN_ROOT/hooks/doc/analyze-doc.sh")"
  collect "$(run_hook "$PLUGIN_ROOT/hooks/code-review/review.sh")"
  collect "$(run_hook "$PLUGIN_ROOT/hooks/unittest/unittest.sh")"
fi

# Emit combined response (or silent {} if everything was empty)
if [[ -z "$COMBINED_CTX" && -z "$COMBINED_MSG" ]]; then
  printf '{}\n'
  exit 0
fi

# Aggregate cap. Each sub-hook already spills its own oversized output;
# this guards against the cumulative concatenation (3 hooks × CFG_MAX_CONTEXT
# headers, behavioural notes and inline references) crowding out the
# 200K model-context window. The cap and spill toggle live in
# .limits.max_combined_chars and .limits.spill_to_file respectively.
MAX_COMBINED="${COPILOT_QA_MAX_COMBINED:-$(_cfg_layered_get '.limits.max_combined_chars')}"
MAX_COMBINED="${MAX_COMBINED:-24000}"
SPILL_ENABLED="${COPILOT_QA_SPILL_TO_FILE:-$(_cfg_layered_get '.limits.spill_to_file')}"
SPILL_ENABLED="${SPILL_ENABLED:-true}"

if (( ${#COMBINED_CTX} > MAX_COMBINED )); then
  if [[ "$SPILL_ENABLED" == "true" ]]; then
    DISP_DIR="$(_cfg_cache_dir "dispatcher")"
    _cfg_cache_dir_init "$DISP_DIR"
    DISP_KEY="$(sha256_str "${FILE_PATH}|$(date +%s%N 2>/dev/null || date +%s)")"
    DISP_PATH="$DISP_DIR/${DISP_KEY}.combined.txt"
    ( umask 077; printf '%s' "$COMBINED_CTX" >"$DISP_PATH" ) 2>/dev/null \
      || printf '%s' "$COMBINED_CTX" >"$DISP_PATH"
    chmod 600 "$DISP_PATH" 2>/dev/null || true
    COMBINED_CTX="$(printf 'Combined sub-hook output for %s exceeded the aggregate budget (%d chars > %s). Full concatenation saved to %s. Per-hook section separators (============================================================) are preserved at file head; the file is read-only via the Read tool and persists for cache_max_age_days (default 7).' \
      "$FILE_PATH" "${#COMBINED_CTX}" "$MAX_COMBINED" "$DISP_PATH")"
  else
    COMBINED_CTX="${COMBINED_CTX:0:$MAX_COMBINED}
[... truncated due to max_combined_chars=$MAX_COMBINED ...]"
  fi
fi

if [[ -n "$COMBINED_MSG" ]]; then
  jq -n \
    --arg ctx "$COMBINED_CTX" \
    --arg msg "$COMBINED_MSG" \
    '{
      hookSpecificOutput: {
        hookEventName: "PostToolUse",
        additionalContext: $ctx
      },
      systemMessage: $msg
    }'
else
  jq -n \
    --arg ctx "$COMBINED_CTX" \
    '{
      hookSpecificOutput: {
        hookEventName: "PostToolUse",
        additionalContext: $ctx
      }
    }'
fi
