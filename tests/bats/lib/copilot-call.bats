#!/usr/bin/env bats
# Tests for hooks/lib/copilot-call.sh — the Copilot wrapper with
# context-instruction fallback on token-limit signals.
#
# Strategy:
#   Stub `copilot` on $PATH and drive run_copilot_with_fallback through:
#     1. Copilot succeeds      -> stdout = copilot output, no sentinel
#     2. Copilot signals limit -> stdout starts with the sentinel
#                                 followed by the assembled instruction
#     3. Pure timeout (rc=124) -> NO fallback even if regex would match
#     4. CFG_FALLBACK_ENABLED=false -> no sentinel even on hit
#     5. Missing fallback template -> no sentinel
#
# Also unit-tests _copilot_signal_token_limit / _copilot_should_fallback,
# the read-only flag block, and copilot_call_split.

load ../helpers/common

setup() {
  qa_setup_env
  qa_source_config
  load_config doc
  # shellcheck disable=SC1091
  source "$CLAUDE_PLUGIN_ROOT/hooks/lib/copilot-call.sh"
}

# ---------- regex / signal helpers ----------

@test "_copilot_signal_token_limit matches default fallback patterns" {
  run _copilot_signal_token_limit "you have hit the monthly limit"
  [ "$status" -eq 0 ]
  run _copilot_signal_token_limit "rate limit reached, retry later"
  [ "$status" -eq 0 ]
  run _copilot_signal_token_limit "HTTP 429 too many requests"
  [ "$status" -eq 0 ]
}

@test "_copilot_signal_token_limit ignores unrelated errors" {
  run _copilot_signal_token_limit "syntax error in file"
  [ "$status" -ne 0 ]
}

@test "_copilot_should_fallback returns false for pure timeout (exit 124)" {
  run _copilot_should_fallback 124 "rate limit hit"
  [ "$status" -ne 0 ]
}

@test "_copilot_should_fallback returns true for non-124 + signal in output" {
  run _copilot_should_fallback 1 "quota exceeded"
  [ "$status" -eq 0 ]
}

# ---------- read-only flag block ----------

@test "_copilot_readonly_flags assembles the full deny + allow list" {
  CFG_CONFIG_DIR="$BATS_TEST_TMPDIR/cfgdir"
  CFG_MODEL=auto
  CFG_LOG_LEVEL=error
  _copilot_readonly_flags
  local joined=" ${_COPILOT_RO_FLAGS[*]} "
  [[ "$joined" == *" --available-tools=read "* ]]
  [[ "$joined" == *" --deny-tool=write "* ]]
  [[ "$joined" == *" --deny-tool=shell "* ]]
  [[ "$joined" == *" --deny-tool=url "* ]]
  [[ "$joined" == *" --deny-tool=memory "* ]]
  [[ "$joined" == *" --disable-builtin-mcps "* ]]
  [[ "$joined" == *" --no-ask-user "* ]]
  [[ "$joined" == *" --allow-all-paths "* ]]
  [[ "$joined" == *" --config-dir=$CFG_CONFIG_DIR "* ]]
}

# ---------- run_copilot_with_fallback (sentinel-based) ----------

@test "run_copilot_with_fallback returns Copilot output on success (no sentinel)" {
  qa_install_stub copilot "FINDING: looks fine"

  local out
  out="$(run_copilot_with_fallback "PROMPT" "/dev/null" "TAIL")"
  [ "$out" = "FINDING: looks fine" ]
  [[ "$out" != "${COPILOT_QA_FALLBACK_SENTINEL}"* ]]
}

@test "run_copilot_with_fallback emits sentinel + instruction on token-limit stderr" {
  qa_install_stub_with_stderr copilot "" "Error: rate limit exceeded" 1

  local tpl="$BATS_TEST_TMPDIR/fallback.txt"
  printf 'fallback prompt template body\n' >"$tpl"

  local out
  out="$(run_copilot_with_fallback "PROMPT" "$tpl" "CTX_TAIL_VALUE")"
  [[ "$out" == "${COPILOT_QA_FALLBACK_SENTINEL}"* ]]
  [[ "$out" == *"fallback prompt template body"* ]]
  [[ "$out" == *"CTX_TAIL_VALUE"* ]]
}

@test "run_copilot_with_fallback does NOT emit sentinel on pure timeout (exit 124)" {
  qa_install_stub_with_stderr copilot "" "rate limit hit" 124

  local tpl="$BATS_TEST_TMPDIR/fallback.txt"
  printf 'tpl\n' >"$tpl"

  local out
  out="$(run_copilot_with_fallback "PROMPT" "$tpl" "TAIL")"
  [[ "$out" != "${COPILOT_QA_FALLBACK_SENTINEL}"* ]]
}

@test "run_copilot_with_fallback respects CFG_FALLBACK_ENABLED=false" {
  qa_install_stub_with_stderr copilot "" "rate limit reached" 1

  CFG_FALLBACK_ENABLED=false
  local tpl="$BATS_TEST_TMPDIR/fallback.txt"
  printf 'tpl\n' >"$tpl"

  local out
  out="$(run_copilot_with_fallback "PROMPT" "$tpl" "TAIL")"
  [[ "$out" != "${COPILOT_QA_FALLBACK_SENTINEL}"* ]]
}

@test "run_copilot_with_fallback skips fallback when template file is missing" {
  qa_install_stub_with_stderr copilot "" "quota exceeded" 1

  local out
  out="$(run_copilot_with_fallback "PROMPT" "/no/such/template" "TAIL")"
  [[ "$out" != "${COPILOT_QA_FALLBACK_SENTINEL}"* ]]
}

@test "run_copilot_with_fallback works without claude binary on PATH" {
  # The new fallback path must not invoke claude. Removing claude from
  # PATH (it is not even installed in the bats env) must NOT break the
  # context-instruction fallback.
  qa_install_stub_with_stderr copilot "" "rate limit reached" 1
  local tpl="$BATS_TEST_TMPDIR/fallback.txt"
  printf 'tpl-body\n' >"$tpl"

  local out
  out="$(run_copilot_with_fallback "PROMPT" "$tpl" "TAIL")"
  [[ "$out" == "${COPILOT_QA_FALLBACK_SENTINEL}"* ]]
  [[ "$out" == *"tpl-body"* ]]
}

# ---------- copilot_call_split ----------

@test "copilot_call_split classifies plain Copilot output as engine=Copilot" {
  eval "$(copilot_call_split "FINDING: x")"
  [ "$QA_ENGINE" = "Copilot" ]
  [ "$QA_BODY" = "FINDING: x" ]
  [ -z "$QA_REASON" ]
}

@test "copilot_call_split strips the sentinel and returns Context-fallback" {
  local raw="${COPILOT_QA_FALLBACK_SENTINEL}"$'\n'"INSTRUCTION_BODY"
  eval "$(copilot_call_split "$raw")"
  [[ "$QA_ENGINE" == "Context-fallback"* ]]
  [ "$QA_BODY" = "INSTRUCTION_BODY" ]
  [ -n "$QA_REASON" ]
}

@test "copilot_call_split preserves multi-line bodies via printf %q" {
  local body=$'line one\nline two\nline three'
  local raw="${COPILOT_QA_FALLBACK_SENTINEL}"$'\n'"$body"
  eval "$(copilot_call_split "$raw")"
  [ "$QA_BODY" = "$body" ]
}

# ---------- COPILOT_GITHUB_TOKEN injection from CFG ----------
#
# The Copilot CLI authenticates via COPILOT_GITHUB_TOKEN. The wrapper
# only exports the config-resolved token when the env var is unset —
# an existing env var must always win, since it represents the user's
# explicit out-of-band setup.

@test "wrapper exports COPILOT_GITHUB_TOKEN from CFG_COPILOT_TOKEN when env unset" {
  unset COPILOT_GITHUB_TOKEN
  CFG_COPILOT_TOKEN="ghp_from_cfg"
  # The stub captures the env it was called under by reading
  # COPILOT_GITHUB_TOKEN; the wrapper must export it before invoking copilot.
  cat >"$BATS_TEST_TMPDIR/bin/copilot" <<'EOF'
#!/usr/bin/env bash
mkdir -p "$BATS_TEST_TMPDIR/calls"
printf 'token=%s\n' "${COPILOT_GITHUB_TOKEN:-<unset>}" \
  >"$BATS_TEST_TMPDIR/calls/copilot.token"
exit 0
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/copilot"

  run_copilot_with_fallback "PROMPT" "/dev/null" "TAIL" >/dev/null
  [ "$(cat "$BATS_TEST_TMPDIR/calls/copilot.token")" = "token=ghp_from_cfg" ]
}

@test "existing COPILOT_GITHUB_TOKEN env beats CFG_COPILOT_TOKEN" {
  export COPILOT_GITHUB_TOKEN="ghp_user_setup"
  CFG_COPILOT_TOKEN="ghp_from_cfg"
  cat >"$BATS_TEST_TMPDIR/bin/copilot" <<'EOF'
#!/usr/bin/env bash
mkdir -p "$BATS_TEST_TMPDIR/calls"
printf 'token=%s\n' "${COPILOT_GITHUB_TOKEN:-<unset>}" \
  >"$BATS_TEST_TMPDIR/calls/copilot.token"
exit 0
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/copilot"

  run_copilot_with_fallback "PROMPT" "/dev/null" "TAIL" >/dev/null
  [ "$(cat "$BATS_TEST_TMPDIR/calls/copilot.token")" = "token=ghp_user_setup" ]
}

@test "wrapper does not export COPILOT_GITHUB_TOKEN when both env and CFG empty" {
  unset COPILOT_GITHUB_TOKEN
  CFG_COPILOT_TOKEN=""
  cat >"$BATS_TEST_TMPDIR/bin/copilot" <<'EOF'
#!/usr/bin/env bash
mkdir -p "$BATS_TEST_TMPDIR/calls"
printf 'token=%s\n' "${COPILOT_GITHUB_TOKEN:-<unset>}" \
  >"$BATS_TEST_TMPDIR/calls/copilot.token"
exit 0
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/copilot"

  run_copilot_with_fallback "PROMPT" "/dev/null" "TAIL" >/dev/null
  [ "$(cat "$BATS_TEST_TMPDIR/calls/copilot.token")" = "token=<unset>" ]
}
