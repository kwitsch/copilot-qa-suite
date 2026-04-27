#!/usr/bin/env bash
# Shared configuration library for all copilot-qa-suite hooks.
#
# IMPORTANT: This file should be sourced AFTER 'set -euo pipefail' but
# BEFORE any other logic, because it self-checks bash version and may
# require a re-exec under a newer bash (a15 fix on macOS bash 3.2).
#
# Re-exec under bash 4.4+ if needed (a15 fix). On macOS the system bash
# is 3.2 which silently no-ops `shopt -s inherit_errexit`, defeating the
# purpose of `set -euo pipefail`.
if ! shopt -s inherit_errexit 2>/dev/null; then
  for _qa_candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    if [[ -x "$_qa_candidate" ]]; then
      # Caller-provided BASH_SOURCE[1] is the script that sourced us
      _qa_caller="${BASH_SOURCE[1]:-$0}"
      exec "$_qa_candidate" "$_qa_caller" "$@"
    fi
  done
  echo "copilot-qa-suite: bash 4.4+ required (got ${BASH_VERSION:-unknown})." >&2
  echo "  Install via: brew install bash" >&2
  exit 0
fi
unset _qa_candidate _qa_caller
#
# Usage:
#   source "$(dirname "$0")/../lib/config.sh"
#   load_config "doc"            # load plugin-default + user + project + env
#   echo "$CFG_MODEL"             # model name (per-hook override or global)
#   echo "$CFG_TIMEOUT"           # timeout for THIS hook
#   echo "$CFG_LOG_LEVEL"
#   echo "$CFG_MAX_CONTEXT"       # per-hook char budget for additionalContext
#   echo "$CFG_MAX_COMBINED"      # aggregate cap across all sub-hook outputs (dispatcher)
#   echo "$CFG_SPILL_THRESHOLD"   # body size at which spill_or_inline writes to disk
#   echo "$CFG_SPILL_ENABLED"     # "true" enables file spill; "false" plain truncate
#   echo "$CFG_HOOK_ENABLED"      # "true" or "false"
#   echo "$CFG_RATE_LIMIT"        # only for code_review/unittest/proguard
#   echo "$CFG_DOC_LANGUAGE"      # only for the doc hook
#   echo "$CFG_MAX_FINDINGS"      # only for the code_review hook
#   echo "$CFG_CONFIG_DIR"        # plugin-private Copilot config dir
#   echo "$CFG_COPILOT_TOKEN"     # GitHub PAT (config-supplied; empty if env-only)
#   echo "$CFG_FALLBACK_ENABLED"  # "true"/"false" — context-instruction fallback on token-limit
#   echo "$CFG_FALLBACK_PATTERNS" # ERE regex; case-insensitive match on Copilot output
#
# Precedence (highest first):
#   1. Environment variable COPILOT_QA_<KEY> (e.g. COPILOT_QA_MODEL=gpt-5)
#   2. $CLAUDE_PROJECT_DIR/.claude/copilot-qa-suite.json (project override)
#   3. ~/.config/copilot-qa-suite/config.json (user override)
#   4. $CLAUDE_PLUGIN_ROOT/config/defaults.json (plugin default)
#
# When jq is missing, only plugin defaults and environment variables are
# evaluated (project/user JSON overrides require jq).

set -euo pipefail

_CFG_PLUGIN_ROOT_DEFAULT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Returns the effective plugin root: env var beats source location.
_cfg_plugin_root() {
  echo "${CLAUDE_PLUGIN_ROOT:-$_CFG_PLUGIN_ROOT_DEFAULT}"
}

# Returns the path to the plugin's default config.
_cfg_default_file() {
  echo "$(_cfg_plugin_root)/config/defaults.json"
}

# Returns the path to the user-level config (XDG_CONFIG_HOME or ~/.config).
_cfg_user_file() {
  echo "${XDG_CONFIG_HOME:-$HOME/.config}/copilot-qa-suite/config.json"
}

# Returns the cache dir for a given hook (a8/b3 fix).
# Prefers ${CLAUDE_PLUGIN_DATA} (per docs); falls back to a UID-namespaced
# /tmp path for symlink-attack resistance on multi-user systems.
_cfg_cache_dir() {
  local hook="${1:?hook-name required}"
  local base
  if [[ -n "${CLAUDE_PLUGIN_DATA:-}" ]]; then
    base="${CLAUDE_PLUGIN_DATA}/cache"
  elif [[ -n "${XDG_CACHE_HOME:-}" ]]; then
    base="${XDG_CACHE_HOME}/copilot-qa-suite"
  else
    base="${TMPDIR:-/tmp}/copilot-qa-$(id -u 2>/dev/null || echo nobody)"
  fi
  echo "$base/$hook"
}

# Creates a cache dir with restricted permissions (umask 077).
_cfg_cache_dir_init() {
  local d="$1"
  ( umask 077; mkdir -p "$d" ) 2>/dev/null || mkdir -p "$d"
  chmod 700 "$d" 2>/dev/null || true
}

# Returns the path to the project-level config.
_cfg_project_file() {
  echo "${CLAUDE_PROJECT_DIR:-$PWD}/.claude/copilot-qa-suite.json"
}

# Returns the persistent per-plugin data directory (b3 fix).
# Per Claude Code docs, ${CLAUDE_PLUGIN_DATA} is the recommended location for
# plugin state. Fallback to XDG cache for direct invocation outside Claude Code.
_cfg_plugin_data() {
  echo "${CLAUDE_PLUGIN_DATA:-${XDG_CACHE_HOME:-$HOME/.cache}/copilot-qa-suite}"
}

# Returns the plugin-private Copilot config dir (a4/a5/a26/b21 fix).
# Isolates trusted_folders and model state from the user's interactive Copilot.
# Resolution: env > config > default ($plugin_data/copilot).
_cfg_copilot_config_dir() {
  local d
  d="${COPILOT_QA_CONFIG_DIR:-}"
  [[ -z "$d" ]] && d="$(_cfg_layered_get '.copilot.config_dir')"
  [[ -z "$d" ]] && d="$(_cfg_plugin_data)/copilot"
  echo "$d"
}

# Reads a path from a JSON file. Returns empty string if the file is
# missing or the path is absent. Uses jq.
#
# Important: '// empty' would swallow false and 0 because jq treats them
# as falsy. Instead we explicitly check whether the path exists, so
# false/0 are returned faithfully.
_cfg_jq_get() {
  local file="$1" path="$2"
  [[ -f "$file" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  jq -r "if (try ($path) catch null) == null then empty else ($path) end" "$file" 2>/dev/null || true
}

# Layered read with project > user > default precedence. The first non-empty
# value wins. Environment overrides are checked separately by load_config.
_cfg_layered_get() {
  local path="$1" val
  for f in "$(_cfg_project_file)" "$(_cfg_user_file)" "$(_cfg_default_file)"; do
    val="$(_cfg_jq_get "$f" "$path")"
    if [[ -n "$val" && "$val" != "null" ]]; then
      printf '%s' "$val"
      return
    fi
  done
}

# Resolves a 4-layer chain in precedence order:
#   1. ${ENV_PER_HOOK} env var       (skipped when arg is "")
#   2. PATH_PER_HOOK   JSON path     (skipped when arg is "")
#   3. ${ENV_GLOBAL}   env var       (skipped when arg is "")
#   4. PATH_GLOBAL     JSON path     (skipped when arg is "")
#   5. DEFAULT
# First non-empty wins. _cfg_layered_get is only invoked when its
# higher-priority layers come back empty (preserves the original
# short-circuit behaviour, no extra jq forks).
_cfg_resolve_layered() {
  local env_h="$1" path_h="$2" env_g="$3" path_g="$4" default="$5" v
  if [[ -n "$env_h" ]]; then v="${!env_h:-}"; [[ -n "$v" ]] && { printf '%s' "$v"; return; }; fi
  if [[ -n "$path_h" ]]; then v="$(_cfg_layered_get "$path_h")"; [[ -n "$v" ]] && { printf '%s' "$v"; return; }; fi
  if [[ -n "$env_g" ]]; then v="${!env_g:-}"; [[ -n "$v" ]] && { printf '%s' "$v"; return; }; fi
  if [[ -n "$path_g" ]]; then v="$(_cfg_layered_get "$path_g")"; [[ -n "$v" ]] && { printf '%s' "$v"; return; }; fi
  printf '%s' "$default"
}

# Layered array read (newline-separated output). Same precedence as above.
_cfg_layered_get_array() {
  local path="$1" val
  for f in "$(_cfg_project_file)" "$(_cfg_user_file)" "$(_cfg_default_file)"; do
    [[ -f "$f" ]] || continue
    command -v jq >/dev/null 2>&1 || continue
    val="$(jq -r "$path // [] | .[]" "$f" 2>/dev/null || true)"
    if [[ -n "$val" ]]; then
      printf '%s\n' "$val"
      return
    fi
  done
}

# ---------- Session env-file (fast path) ----------
#
# The compile-config SessionStart hook resolves the JSON layer once per
# session and writes a sourceable bash env-file. PostToolUse hooks then
# `source` it (cheap stat+read) instead of forking jq 60-180× per Edit.
#
# ENV-var precedence is preserved by re-applying COPILOT_QA_* AFTER source.
# Arrays use plain assignment (NOT `declare -a`) so they remain global
# even when sourced inside a function.

# Per-project env-file path (sha-prefix of CLAUDE_PROJECT_DIR).
_cfg_session_env_file() {
  local proj="${CLAUDE_PROJECT_DIR:-$PWD}"
  local key; key="$(sha256_str "$proj" | cut -c1-16)"
  printf '%s/session/%s.env' "$(_cfg_plugin_data)" "$key"
}

# Stable identity of the three JSON sources (path:mtime:size or :absent).
_cfg_session_source_stamp() {
  local f st parts=()
  for f in "$(_cfg_default_file)" "$(_cfg_user_file)" "$(_cfg_project_file)"; do
    if [[ -f "$f" ]]; then
      st="$(stat -c '%Y:%s' "$f" 2>/dev/null || stat -f '%m:%z' "$f" 2>/dev/null || echo unknown)"
      parts+=("$f:$st")
    else
      parts+=("$f:absent")
    fi
  done
  printf '%s\n' "${parts[@]}" | sha256_stdin
}

# JSON-only resolver (skips ENV layer — ENV stays dynamic at hook-runtime).
_cfg_compile_get() {
  local path_h="$1" path_g="$2" default="$3" v
  if [[ -n "$path_h" ]]; then v="$(_cfg_layered_get "$path_h")"; [[ -n "$v" ]] && { printf '%s' "$v"; return; }; fi
  if [[ -n "$path_g" ]]; then v="$(_cfg_layered_get "$path_g")"; [[ -n "$v" ]] && { printf '%s' "$v"; return; }; fi
  printf '%s' "$default"
}

# Compile JSON state into env-file. Atomic write. No-op when source-stamp
# matches (re-running this hook on every SessionStart costs ~1ms then).
# Returns 1 only on hard failure (no jq, write error). Hooks treat any
# return as silent — the slow path catches missing/stale env-files.
compile_session_env() {
  command -v jq >/dev/null 2>&1 || return 1

  local out stamp current
  out="$(_cfg_session_env_file)"
  stamp="$(_cfg_session_source_stamp)"

  if [[ -f "$out" ]]; then
    current="$(awk '/^# source-stamp:/{print $3; exit}' "$out" 2>/dev/null || true)"
    [[ "$current" == "$stamp" ]] && return 0
  fi

  mkdir -p "$(dirname "$out")" 2>/dev/null || return 1
  local tmp; tmp="$(mktemp "$out.XXXXXX")" || return 1

  {
    printf '# copilot-qa-suite session env (auto-generated, do not edit)\n'
    printf '# source-stamp: %s\n' "$stamp"
    printf '# generated: %s\n' "$(date +%s 2>/dev/null || echo 0)"
    printf '\n'

    # Globals
    printf '__CFG_LOG_LEVEL=%q\n'         "$(_cfg_compile_get '' '.copilot.log_level' 'error')"
    printf '__CFG_MAX_CONTEXT=%q\n'       "$(_cfg_compile_get '' '.limits.max_context_chars' '8000')"
    printf '__CFG_MAX_COMBINED=%q\n'      "$(_cfg_compile_get '' '.limits.max_combined_chars' '24000')"
    printf '__CFG_SPILL_THRESHOLD=%q\n'   "$(_cfg_compile_get '' '.limits.spill_threshold_chars' '7000')"
    printf '__CFG_SPILL_ENABLED=%q\n'     "$(_cfg_compile_get '' '.limits.spill_to_file' 'true')"
    printf '__CFG_FALLBACK_PATTERNS=%q\n' "$(_cfg_compile_get '' '.fallback.detection_patterns' 'rate.?limit|quota|premium request|monthly limit|usage limit|too many requests|429|exceeded.*limit|limit.*exceeded')"
    printf '__CFG_CONFIG_DIR_DEFAULT=%q\n' "$(_cfg_compile_get '' '.copilot.config_dir' '')"
    printf '__CFG_COPILOT_TOKEN=%q\n'      "$(_cfg_compile_get '' '.copilot.github_token' '')"
    printf '__CFG_DOC_LANGUAGE=%q\n'      "$(_cfg_compile_get '' '.doc.comment_language' 'English')"
    printf '__CFG_MAX_FINDINGS=%q\n'      "$(_cfg_compile_get '' '.code_review.max_findings' '5')"

    # Global arrays — plain assignment so source-in-function stays global
    local x extra=()
    while IFS= read -r x; do [[ -n "$x" ]] && extra+=("$x"); done < <(_cfg_layered_get_array '.copilot.extra_args')

    printf '__CFG_EXTRA_ARGS=('
    for x in "${extra[@]+"${extra[@]}"}"; do printf '%q ' "$x"; done
    printf ')\n'

    printf '\n'

    # Per-hook
    local hook
    for hook in doc code_review unittest proguard check_copilot; do
      printf '__CFG_MODEL_%s=%q\n'             "$hook" "$(_cfg_compile_get ".${hook}.model"               '.copilot.model'    'auto')"
      printf '__CFG_TIMEOUT_%s=%q\n'           "$hook" "$(_cfg_compile_get ".timeouts.${hook}"            '.timeouts.default' '90')"
      printf '__CFG_HOOK_ENABLED_%s=%q\n'      "$hook" "$(_cfg_compile_get ".hooks_enabled.${hook}"       ''                  'true')"
      printf '__CFG_RATE_LIMIT_%s=%q\n'        "$hook" "$(_cfg_compile_get ".rate_limits.${hook}_seconds" ''                  '0')"
      printf '__CFG_FALLBACK_ENABLED_%s=%q\n'  "$hook" "$(_cfg_compile_get ".${hook}.fallback.enabled"    '.fallback.enabled' 'true')"
    done

    printf '\n'

    # Extension lists
    local h ext
    for h in code_review unittest; do
      printf '__CFG_EXT_%s=(' "$h"
      while IFS= read -r ext; do [[ -n "$ext" ]] && printf '%q ' "$ext"; done < <(_cfg_layered_get_array ".languages.${h}_extensions")
      printf ')\n'
    done
  } >"$tmp" || { rm -f "$tmp"; return 1; }

  chmod 600 "$tmp" 2>/dev/null || true
  mv "$tmp" "$out" || { rm -f "$tmp"; return 1; }
  return 0
}

# Try the env-file fast path. Sets all CFG_* on success, returns 0; on
# any failure (missing file, stale stamp, source error) returns 1 so
# the caller falls through to the slow jq-layered path.
_cfg_try_fast_path() {
  local hook="${1:?}" H="${1^^}"
  local f; f="$(_cfg_session_env_file)"
  [[ -f "$f" ]] || return 1

  local cached current
  cached="$(awk '/^# source-stamp:/{print $3; exit}' "$f" 2>/dev/null || true)"
  current="$(_cfg_session_source_stamp)"
  [[ -n "$cached" && "$cached" == "$current" ]] || return 1

  # shellcheck disable=SC1090
  source "$f" || return 1

  local mvar="__CFG_MODEL_${hook}"        tvar="__CFG_TIMEOUT_${hook}"
  local evar="__CFG_HOOK_ENABLED_${hook}" rvar="__CFG_RATE_LIMIT_${hook}"
  local fevar="__CFG_FALLBACK_ENABLED_${hook}"

  local em="COPILOT_QA_MODEL_${H}"   et="COPILOT_QA_TIMEOUT_${H}"
  local ee="COPILOT_QA_ENABLED_${H}" er="COPILOT_QA_RATE_${H}"
  local efe="COPILOT_QA_FALLBACK_ENABLED_${H}"

  CFG_MODEL="${!em:-${COPILOT_QA_MODEL:-${!mvar:-auto}}}"
  CFG_TIMEOUT="${!et:-${!tvar:-90}}"
  CFG_HOOK_ENABLED="${!ee:-${!evar:-true}}"
  CFG_RATE_LIMIT="${!er:-${!rvar:-0}}"

  CFG_LOG_LEVEL="${COPILOT_QA_LOG_LEVEL:-${__CFG_LOG_LEVEL:-error}}"
  CFG_MAX_CONTEXT="${COPILOT_QA_MAX_CONTEXT:-${__CFG_MAX_CONTEXT:-8000}}"
  CFG_MAX_COMBINED="${COPILOT_QA_MAX_COMBINED:-${__CFG_MAX_COMBINED:-24000}}"
  CFG_SPILL_THRESHOLD="${COPILOT_QA_SPILL_THRESHOLD:-${__CFG_SPILL_THRESHOLD:-7000}}"
  CFG_SPILL_ENABLED="${COPILOT_QA_SPILL_TO_FILE:-${__CFG_SPILL_ENABLED:-true}}"

  if [[ "$hook" == "doc" ]]; then
    CFG_DOC_LANGUAGE="${COPILOT_QA_DOC_LANGUAGE:-${__CFG_DOC_LANGUAGE:-English}}"
  else
    CFG_DOC_LANGUAGE=""
  fi
  if [[ "$hook" == "code_review" ]]; then
    CFG_MAX_FINDINGS="${COPILOT_QA_MAX_FINDINGS:-${__CFG_MAX_FINDINGS:-5}}"
  else
    CFG_MAX_FINDINGS=""
  fi

  CFG_CONFIG_DIR="${COPILOT_QA_CONFIG_DIR:-${__CFG_CONFIG_DIR_DEFAULT:-}}"
  [[ -z "$CFG_CONFIG_DIR" ]] && CFG_CONFIG_DIR="$(_cfg_plugin_data)/copilot"
  mkdir -p "$CFG_CONFIG_DIR" 2>/dev/null || true

  CFG_COPILOT_TOKEN="${COPILOT_QA_COPILOT_TOKEN:-${__CFG_COPILOT_TOKEN:-}}"

  CFG_EXTRA_ARGS=("${__CFG_EXTRA_ARGS[@]+"${__CFG_EXTRA_ARGS[@]}"}")

  CFG_FALLBACK_ENABLED="${!efe:-${COPILOT_QA_FALLBACK_ENABLED:-${!fevar:-true}}}"
  CFG_FALLBACK_PATTERNS="${COPILOT_QA_FALLBACK_PATTERNS:-${__CFG_FALLBACK_PATTERNS:-rate.?limit|quota|premium request|monthly limit|usage limit|too many requests|429|exceeded.*limit|limit.*exceeded}}"

  export CFG_MODEL CFG_LOG_LEVEL CFG_TIMEOUT CFG_MAX_CONTEXT \
         CFG_MAX_COMBINED CFG_SPILL_THRESHOLD CFG_SPILL_ENABLED \
         CFG_HOOK_ENABLED CFG_RATE_LIMIT CFG_DOC_LANGUAGE CFG_MAX_FINDINGS \
         CFG_CONFIG_DIR CFG_COPILOT_TOKEN \
         CFG_FALLBACK_ENABLED CFG_FALLBACK_PATTERNS
  return 0
}

# Main entry point: loads all values for a given hook and exports them as
# CFG_* variables.
#
# Argument: hook-name (doc|code_review|unittest|proguard|check_copilot)
load_config() {
  local hook="${1:?hook-name required}" H="${1^^}"

  # Fast path: session env-file (compiled by SessionStart hook).
  _cfg_try_fast_path "$hook" && return 0

  # Per-hook env > per-hook json > global env > global json > default.
  # See _cfg_resolve_layered for the precedence helper.
  CFG_MODEL="$(_cfg_resolve_layered "COPILOT_QA_MODEL_${H}"      ".${hook}.model"               "COPILOT_QA_MODEL"      '.copilot.model'      'auto')"
  CFG_TIMEOUT="$(_cfg_resolve_layered "COPILOT_QA_TIMEOUT_${H}"  ".timeouts.${hook}"            ""                      '.timeouts.default'   '90')"
  CFG_HOOK_ENABLED="$(_cfg_resolve_layered "COPILOT_QA_ENABLED_${H}" ".hooks_enabled.${hook}"   ""                      ""                    'true')"
  CFG_RATE_LIMIT="$(_cfg_resolve_layered "COPILOT_QA_RATE_${H}"  ".rate_limits.${hook}_seconds" ""                      ""                    '0')"

  # 2-layer resolutions stay inline (no per-hook JSON section).
  CFG_LOG_LEVEL="${COPILOT_QA_LOG_LEVEL:-$(_cfg_layered_get '.copilot.log_level')}"
  CFG_LOG_LEVEL="${CFG_LOG_LEVEL:-error}"
  CFG_MAX_CONTEXT="${COPILOT_QA_MAX_CONTEXT:-$(_cfg_layered_get '.limits.max_context_chars')}"
  CFG_MAX_CONTEXT="${CFG_MAX_CONTEXT:-8000}"
  CFG_MAX_COMBINED="${COPILOT_QA_MAX_COMBINED:-$(_cfg_layered_get '.limits.max_combined_chars')}"
  CFG_MAX_COMBINED="${CFG_MAX_COMBINED:-24000}"
  CFG_SPILL_THRESHOLD="${COPILOT_QA_SPILL_THRESHOLD:-$(_cfg_layered_get '.limits.spill_threshold_chars')}"
  CFG_SPILL_THRESHOLD="${CFG_SPILL_THRESHOLD:-7000}"
  CFG_SPILL_ENABLED="${COPILOT_QA_SPILL_TO_FILE:-$(_cfg_layered_get '.limits.spill_to_file')}"
  CFG_SPILL_ENABLED="${CFG_SPILL_ENABLED:-true}"

  if [[ "$hook" == "doc" ]]; then
    CFG_DOC_LANGUAGE="${COPILOT_QA_DOC_LANGUAGE:-$(_cfg_layered_get '.doc.comment_language')}"
    CFG_DOC_LANGUAGE="${CFG_DOC_LANGUAGE:-English}"
  else
    CFG_DOC_LANGUAGE=""
  fi

  if [[ "$hook" == "code_review" ]]; then
    CFG_MAX_FINDINGS="${COPILOT_QA_MAX_FINDINGS:-$(_cfg_layered_get '.code_review.max_findings')}"
    CFG_MAX_FINDINGS="${CFG_MAX_FINDINGS:-5}"
  else
    CFG_MAX_FINDINGS=""
  fi

  # Plugin-private Copilot config dir (b21)
  CFG_CONFIG_DIR="$(_cfg_copilot_config_dir)"
  mkdir -p "$CFG_CONFIG_DIR" 2>/dev/null || true

  # GitHub PAT for Copilot CLI. Env var beats JSON; both layers may be
  # empty (the user may have COPILOT_GITHUB_TOKEN set out-of-band, in
  # which case the wrapper leaves it alone).
  CFG_COPILOT_TOKEN="${COPILOT_QA_COPILOT_TOKEN:-$(_cfg_layered_get '.copilot.github_token')}"

  # Extra copilot args (array). Not via env var because escaping JSON
  # arrays in env vars is fragile.
  CFG_EXTRA_ARGS=()
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    CFG_EXTRA_ARGS+=("$line")
  done < <(_cfg_layered_get_array '.copilot.extra_args')

  # ---------- Fallback (context-instruction) configuration ----------
  # Token-limit/quota/rate signals from Copilot trigger the wrapper to
  # emit the fallback prompt as additionalContext for the parent Claude
  # session. No second model is invoked, hence no model/timeout settings.
  CFG_FALLBACK_ENABLED="$(_cfg_resolve_layered "COPILOT_QA_FALLBACK_ENABLED_${H}" ".${hook}.fallback.enabled" "COPILOT_QA_FALLBACK_ENABLED" '.fallback.enabled' 'true')"
  CFG_FALLBACK_PATTERNS="${COPILOT_QA_FALLBACK_PATTERNS:-$(_cfg_layered_get '.fallback.detection_patterns')}"
  CFG_FALLBACK_PATTERNS="${CFG_FALLBACK_PATTERNS:-rate.?limit|quota|premium request|monthly limit|usage limit|too many requests|429|exceeded.*limit|limit.*exceeded}"

  export CFG_MODEL CFG_LOG_LEVEL CFG_TIMEOUT CFG_MAX_CONTEXT \
         CFG_MAX_COMBINED CFG_SPILL_THRESHOLD CFG_SPILL_ENABLED \
         CFG_HOOK_ENABLED CFG_RATE_LIMIT CFG_DOC_LANGUAGE CFG_MAX_FINDINGS \
         CFG_CONFIG_DIR CFG_COPILOT_TOKEN \
         CFG_FALLBACK_ENABLED CFG_FALLBACK_PATTERNS
}

# Consistency check: is the hook enabled? Otherwise exit 0.
require_enabled() {
  if [[ "${CFG_HOOK_ENABLED,,}" != "true" ]]; then
    exit 0
  fi
}

# Reads the file extension whitelist for a hook. Newline-separated output.
# Fast path: load_config has already sourced the session env-file, so the
# array `__CFG_EXT_<hook>` is in scope. Falls back to jq-layered read when
# the array is unset (slow path or hook outside the compiled set).
load_extensions() {
  local hook="${1:?hook-name required}"
  local var="__CFG_EXT_${hook}"
  if declare -p "$var" 2>/dev/null | grep -q '^declare -a'; then
    local -n _ext_arr="$var"
    printf '%s\n' "${_ext_arr[@]+"${_ext_arr[@]}"}"
    return 0
  fi
  _cfg_layered_get_array ".languages.${hook}_extensions"
}

# SHA-256 helpers (a23 fix — portable Linux/macOS).
# Prefers sha256sum (Linux), falls back to shasum -a 256 (macOS), then
# openssl dgst (universal). Use sha256_file for files, sha256_str for strings.
sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    openssl dgst -sha256 "$1" | awk '{print $NF}'
  fi
}
sha256_str() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  else
    printf '%s' "$1" | openssl dgst -sha256 | awk '{print $NF}'
  fi
}
sha256_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    openssl dgst -sha256 | awk '{print $NF}'
  fi
}

# compute_range: robust line-range derivation from a "new_string" needle (a11/a12).
# - a12: empty needle -> return failure (don't pass empty to grep -F)
# - a11: multi-line needle -> match against the FIRST line only, then the
#   length is computed from the full needle
# Returns "start-end" on stdout, returns 1 on failure (caller should treat
# the resulting range as ambiguous).
compute_range() {
  local new="$1" file="$2"
  [[ -z "$new" ]] && { echo "1-1"; return 1; }
  [[ -f "$file" ]] || { echo "1-1"; return 1; }

  # First line of the needle (multi-line safe)
  local first
  first="$(printf '%s' "$new" | head -n1)"
  [[ -z "$first" ]] && { echo "1-1"; return 1; }

  # Length of the needle in lines
  local len
  len="$(printf '%s' "$new" | awk 'END{print NR==0?1:NR}')"

  # Find the byte offset of the first occurrence of the first line
  local offset
  offset="$(grep -boF -- "$first" "$file" 2>/dev/null | head -1 | cut -d: -f1 || true)"
  [[ -z "$offset" ]] && { echo "1-1"; return 1; }

  # Convert byte offset to line number
  local start
  start="$(head -c "$offset" "$file" | wc -l | awk '{print $1+1}')"
  echo "$start-$((start + len - 1))"
}

# additionalContext spill (10K-cap mitigation).
# Claude Code caps each hook injection at 10000 characters and spills
# overflow to disk with an undocumented preview format. spill_or_inline
# pre-empts that by writing oversized bodies to a controlled cache file
# and emitting a factual reference instead.
#
# Usage: BODY="$(spill_or_inline "<hook>" "$FILE_PATH" "$RAW_BODY")"
#
# Behaviour:
#   - $CFG_SPILL_ENABLED=true AND ${#RAW_BODY} >= $CFG_SPILL_THRESHOLD
#     -> writes RAW_BODY to <cache>/<hook>/<sha256(FILE_PATH)>.findings.txt
#        (chmod 600), echoes a one-paragraph reference (size, path,
#        cache-lifetime hint).
#   - Otherwise, applies the existing CFG_MAX_CONTEXT truncate and
#     echoes the (possibly truncated) body unchanged.
#
# The factual reference is intentionally short (~400 chars) so the
# combined additionalContext stays well under the 10K hard cap even
# after the per-hook header and behavioural notes are added.
spill_or_inline() {
  local hook="${1:?hook required}" fp="${2:?file_path required}" body="${3-}"
  local size="${#body}"

  if [[ "${CFG_SPILL_ENABLED:-true}" == "true" ]] \
      && (( size >= ${CFG_SPILL_THRESHOLD:-7000} )); then
    local dir key path
    dir="$(_cfg_cache_dir "$hook")"
    _cfg_cache_dir_init "$dir"
    key="$(sha256_str "$fp")"
    path="$dir/${key}.findings.txt"
    ( umask 077; printf '%s' "$body" >"$path" ) 2>/dev/null \
      || printf '%s' "$body" >"$path"
    chmod 600 "$path" 2>/dev/null || true
    printf 'Findings body exceeded inline budget (%d chars). Full content saved to %s. The file persists for cache_max_age_days (default 7) and is read-only via the Read tool.' \
      "$size" "$path"
    return 0
  fi

  if (( size > ${CFG_MAX_CONTEXT:-8000} )); then
    printf '%s\n[... truncated due to max_context_chars=%s ...]' \
      "${body:0:${CFG_MAX_CONTEXT:-8000}}" "${CFG_MAX_CONTEXT:-8000}"
    return 0
  fi
  printf '%s' "$body"
}

# Validates a file_path from hook input (a18 fix) and protects against
# symlink-based escapes from CLAUDE_PROJECT_DIR.
#
# Returns 0 if path is safe to read/hash; 1 otherwise.
# Checks: non-empty, absolute, no newlines/CR, no parent-traversal segments,
# regular file exists, and the *resolved* path (via realpath) is inside
# $CLAUDE_PROJECT_DIR. The realpath check defeats symlinks pointing outside
# the project (e.g. /tmp/proj/secret -> /etc/shadow).
validate_file_path() {
  local fp="$1"
  [[ -n "$fp" ]] || return 1
  [[ "$fp" == /* ]] || return 1
  [[ "$fp" != *$'\n'* && "$fp" != *$'\r'* ]] || return 1
  # Note: bash strings cannot contain NUL bytes (parser truncates at NUL),
  # so an explicit NUL check is impossible and unnecessary.
  # Reject parent-traversal segments (literal ".."). Glob '*..*' is wildcard-
  # greedy and would match ANY two chars, so use specific patterns.
  if [[ "$fp" == *"/../"* || "$fp" == */.. || "$fp" == "../"* || "$fp" == ".." ]]; then
    return 1
  fi
  [[ -f "$fp" ]] || return 1

  if [[ -n "${CLAUDE_PROJECT_DIR:-}" ]]; then
    # Resolve symlinks and ".." in the path. Prefer GNU coreutils realpath;
    # fall back to a Python one-liner if absent (BSD realpath has different
    # flags).
    local resolved=""
    if command -v realpath >/dev/null 2>&1; then
      resolved="$(realpath -e "$fp" 2>/dev/null || true)"
    fi
    if [[ -z "$resolved" ]] && command -v python3 >/dev/null 2>&1; then
      resolved="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$fp" 2>/dev/null || true)"
    fi
    if [[ -z "$resolved" ]]; then
      # No way to resolve safely — refuse rather than trust the unresolved path
      return 1
    fi

    # Resolve project dir too, for canonical comparison
    local proj_resolved=""
    if command -v realpath >/dev/null 2>&1; then
      proj_resolved="$(realpath -e "$CLAUDE_PROJECT_DIR" 2>/dev/null || true)"
    fi
    if [[ -z "$proj_resolved" ]] && command -v python3 >/dev/null 2>&1; then
      proj_resolved="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$CLAUDE_PROJECT_DIR" 2>/dev/null || true)"
    fi
    [[ -z "$proj_resolved" ]] && proj_resolved="$CLAUDE_PROJECT_DIR"

    case "$resolved" in
      "$proj_resolved"/*|"$proj_resolved") ;;
      *) return 1 ;;
    esac
  fi
  return 0
}

# Opens a file by descriptor for TOCTOU-safe reuse across multiple reads.
# After validate_file_path succeeds, callers should:
#   open_safe_fd "$FILE_PATH" || exit 0
#   # use $SAFE_FD for reads, e.g. cat <&$SAFE_FD or sha256_stdin <&$SAFE_FD
#   close_safe_fd
# This ensures all subsequent reads see the same inode that passed
# validation, even if the path is swapped between hook lifecycle stages.
open_safe_fd() {
  local fp="$1"
  exec {SAFE_FD}<"$fp" 2>/dev/null || return 1
  export SAFE_FD
}

close_safe_fd() {
  if [[ -n "${SAFE_FD:-}" ]]; then
    exec {SAFE_FD}<&-
    unset SAFE_FD
  fi
}

# Checks whether FILE_PATH has one of the whitelisted extensions for the
# given hook. Returns 0 (true) or 1 (false).
file_extension_allowed() {
  local file="$1" hook="$2"
  local ext="${file##*.}"
  [[ "$ext" == "$file" ]] && return 1   # no extension at all
  ext="${ext,,}"

  while IFS= read -r allowed; do
    [[ -z "$allowed" ]] && continue
    [[ "$ext" == "${allowed,,}" ]] && return 0
  done < <(load_extensions "$hook")
  return 1
}
