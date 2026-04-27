#!/usr/bin/env bash
# Copilot invocation wrapper with context-instruction fallback on
# token / quota / rate / usage limits.
#
# IMPORTANT: source AFTER lib/config.sh and AFTER load_config "<hook>".
# Reads CFG_* exported by config.sh.
#
# Public API:
#   run_copilot_with_fallback "$COPILOT_PROMPT" "$FALLBACK_TEMPLATE" "$CONTEXT_TAIL"
#     Stdout, two shapes:
#       1. Copilot output (verbatim) on the success path.
#       2. Fallback path: a sentinel line followed by the assembled
#          instruction (`fallback-prompt.txt` + `CONTEXT_TAIL`). The
#          parent Claude session receives this through `additionalContext`
#          and performs the analysis itself with its own read-only tools.
#
#     Sentinel: "__COPILOT_QA_FALLBACK_INSTRUCTION__\n"
#     Sub-hooks detect the sentinel, strip it, and emit the remainder as
#     the body. No globals are required — the sentinel survives the
#     `COPILOT_OUT="$(...)"` subshell, while bash function-locals would
#     not.
#
# Why context-instruction (and not `claude -p`)?
#   - One Claude session, one bill. The earlier Claude-subprocess fallback
#     spun up a fresh `claude -p` per token-limit hit, paying the inner
#     model and round-tripping its output back through the hook parser.
#   - The parent Claude already has Read/Glob/Grep and the same
#     additionalContext budget — it can run the read-only analysis from
#     the instruction directly.
#   - Smaller attack surface: no second `--tools` whitelist to keep in
#     sync with the read-only invariant.
#
# This file is sourced — do NOT call `set -euo pipefail` here; that
# would mutate the caller's shell options.

# Sentinel that flags the stdout body as a fallback instruction rather
# than Copilot output. Sub-hooks must recognize this exact string at the
# start of the wrapper's stdout.
COPILOT_QA_FALLBACK_SENTINEL="__COPILOT_QA_FALLBACK_INSTRUCTION__"

# Match Copilot output (stdout + stderr) against the configured ERE
# regex (case-insensitive). 2>/dev/null suppresses grep noise on a
# user-supplied bad regex.
_copilot_signal_token_limit() {
  local blob="$1"
  [[ -z "$blob" || -z "${CFG_FALLBACK_PATTERNS:-}" ]] && return 1
  printf '%s' "$blob" | grep -E -i -q -- "$CFG_FALLBACK_PATTERNS" 2>/dev/null
}

# Pure timeouts (exit 124 from `timeout`) are NOT a token-limit signal —
# they are an unrelated failure. Treating them as one would amplify
# load instead of dampening it.
_copilot_should_fallback() {
  local exit_code="$1" combined="$2"
  [[ "$exit_code" == "124" ]] && return 1
  _copilot_signal_token_limit "$combined"
}

# Build the read-only Copilot flag list into the global array
# `_COPILOT_RO_FLAGS`. Both the primary call and any future helper
# share this single source of truth — protects the core read-only
# invariant from drift.
_copilot_readonly_flags() {
  _COPILOT_RO_FLAGS=(
    -s
    --no-ask-user
    --no-auto-update
    --no-custom-instructions
    --no-alt-screen
    --allow-all-paths
    "--config-dir=$CFG_CONFIG_DIR"
    --available-tools=read
    --deny-tool=write
    --deny-tool=shell
    --deny-tool=url
    --deny-tool=memory
    --disable-builtin-mcps
    "--model=$CFG_MODEL"
    "--log-level=$CFG_LOG_LEVEL"
  )
}

# Assemble the instruction the parent Claude session will receive.
# Same content the previous `claude -p` invocation would have read on
# stdin: the hook's fallback-prompt.txt followed by the CONTEXT block
# tail. Returns empty string if the template is missing.
_copilot_build_fallback_instruction() {
  local template="$1" tail="$2"
  [[ -f "$template" ]] || return 0
  printf '%s\n%s\n' "$(cat -- "$template")" "$tail"
}

# Main entry. See header for arg / global contract.
run_copilot_with_fallback() {
  local copilot_prompt="$1"
  local fallback_template="$2"
  local context_tail="$3"

  local err_file
  err_file="$(mktemp 2>/dev/null || mktemp -p "${TMPDIR:-/tmp}" copilot-qa-err.XXXXXX)"
  # Two subtleties packed into one line:
  #   1. RETURN traps persist in the caller's shell after the function
  #      unwinds and re-fire on the next unrelated function exit. EXIT
  #      is scoped to the (sub)shell, which is the lifetime we want.
  #   2. err_file is function-local — by the time the trap fires the
  #      local has gone out of scope, so a single-quoted body would
  #      trip `set -u` with "err_file: unbound variable". Double-quote
  #      so the path is baked into the trap command at install time.
  # shellcheck disable=SC2064
  trap "rm -f -- '$err_file'" EXIT

  _copilot_readonly_flags

  # Plugin-config-supplied GitHub PAT. The Copilot CLI authenticates via
  # COPILOT_GITHUB_TOKEN. If the user has it in scope already, leave it
  # alone — the existing env var wins. Only when the env is unset and
  # the config supplies a token do we export it for this invocation.
  if [[ -z "${COPILOT_GITHUB_TOKEN:-}" ]] && [[ -n "${CFG_COPILOT_TOKEN:-}" ]]; then
    export COPILOT_GITHUB_TOKEN="$CFG_COPILOT_TOKEN"
  fi

  local cp_out cp_exit
  cp_out="$(timeout "$CFG_TIMEOUT" copilot \
    -p "$copilot_prompt" \
    "${_COPILOT_RO_FLAGS[@]}" \
    "${CFG_EXTRA_ARGS[@]}" \
    2>"$err_file")" || cp_exit=$?
  cp_exit="${cp_exit:-0}"

  local cp_err
  cp_err="$(cat -- "$err_file" 2>/dev/null || true)"

  if [[ "${CFG_FALLBACK_ENABLED,,}" == "true" ]] \
     && _copilot_should_fallback "$cp_exit" "$cp_err
$cp_out" \
     && [[ -f "$fallback_template" ]]; then
    local instruction
    instruction="$(_copilot_build_fallback_instruction "$fallback_template" "$context_tail")"
    if [[ -n "${instruction// }" ]]; then
      printf '%s\n%s' "$COPILOT_QA_FALLBACK_SENTINEL" "$instruction"
      return 0
    fi
  fi

  printf '%s' "$cp_out"
  return 0
}

# Helper sub-hooks call after capturing the wrapper's stdout. Splits the
# captured blob into the engine label, the body, and the systemMessage
# reason. No globals — the sentinel is the single transport channel.
#
# Usage:
#   COPILOT_OUT="$(run_copilot_with_fallback ...)"
#   eval "$(copilot_call_split "$COPILOT_OUT")"
#   # exposes: $QA_ENGINE  $QA_BODY  $QA_REASON
#
# `eval` with `printf %q` keeps multi-line bodies safe.
copilot_call_split() {
  local raw="$1"
  local sentinel="${COPILOT_QA_FALLBACK_SENTINEL}"$'\n'
  local engine reason body
  if [[ "$raw" == "${COPILOT_QA_FALLBACK_SENTINEL}"* ]]; then
    body="${raw#${sentinel}}"
    engine="Context-fallback (Copilot quota exhausted)"
    reason="copilot token/quota limit hit, instruction routed to parent claude session"
  else
    body="$raw"
    engine="Copilot"
    reason=""
  fi
  printf 'QA_ENGINE=%q\nQA_BODY=%q\nQA_REASON=%q\n' \
    "$engine" "$body" "$reason"
}
