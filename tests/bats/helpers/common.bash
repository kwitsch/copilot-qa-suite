#!/usr/bin/env bash
# Shared bats helpers for copilot-qa-suite.
#
# Each test calls `qa_setup_env` in setup() to:
#   - point CLAUDE_PLUGIN_ROOT at the repo root
#   - place CLAUDE_PROJECT_DIR, CLAUDE_PLUGIN_DATA, XDG_CONFIG_HOME,
#     XDG_CACHE_HOME, TMPDIR under $BATS_TEST_TMPDIR
#   - prepend $BATS_TEST_TMPDIR/bin to PATH so binary stubs win
#   - clear COPILOT_QA_* env so layer-precedence tests start clean

qa_repo_root() {
  # tests/bats/helpers -> repo root
  cd "${BATS_TEST_DIRNAME}/../../.." && pwd
}

qa_setup_env() {
  export CLAUDE_PLUGIN_ROOT
  CLAUDE_PLUGIN_ROOT="$(qa_repo_root)"

  # NOTE: bats sets BATS_TEST_TMPDIR=$BATS_RUN_TMPDIR/test/<n>, which
  # contains the literal "/test/" substring. dispatch.sh's is_test_file
  # routes any path matching */test/* to the doc hook only, so placing
  # CLAUDE_PROJECT_DIR under BATS_TEST_TMPDIR breaks source-routing
  # tests. Use a sibling path that does NOT contain "/test/".
  export CLAUDE_PROJECT_DIR
  CLAUDE_PROJECT_DIR="$(mktemp -d "${BATS_RUN_TMPDIR:-/tmp}/qa-proj.XXXXXX")"

  export CLAUDE_PLUGIN_DATA="$BATS_TEST_TMPDIR/data"
  export XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/xdg-config"
  export XDG_CACHE_HOME="$BATS_TEST_TMPDIR/xdg-cache"
  export TMPDIR="$BATS_TEST_TMPDIR/tmp"
  export HOME="$BATS_TEST_TMPDIR/home"

  mkdir -p "$CLAUDE_PROJECT_DIR/.claude" \
           "$CLAUDE_PLUGIN_DATA/session" \
           "$XDG_CONFIG_HOME/copilot-qa-suite" \
           "$XDG_CACHE_HOME" \
           "$TMPDIR" \
           "$HOME" \
           "$BATS_TEST_TMPDIR/bin"

  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"

  unset COPILOT_QA_MODEL COPILOT_QA_LOG_LEVEL COPILOT_QA_TIMEOUT \
        COPILOT_QA_MAX_CONTEXT COPILOT_QA_MAX_COMBINED \
        COPILOT_QA_SPILL_THRESHOLD COPILOT_QA_SPILL_TO_FILE \
        COPILOT_QA_FALLBACK_ENABLED COPILOT_QA_FALLBACK_PATTERNS \
        COPILOT_QA_DOC_LANGUAGE COPILOT_QA_MAX_FINDINGS \
        COPILOT_QA_CONFIG_DIR COPILOT_QA_COPILOT_TOKEN \
        COPILOT_GITHUB_TOKEN
  local v
  for v in $(compgen -e | grep -E '^COPILOT_QA_' || true); do
    unset "$v"
  done
}

# Source the shared config library. Tests that just want CFG_* vars.
qa_source_config() {
  # shellcheck disable=SC1091
  source "$CLAUDE_PLUGIN_ROOT/hooks/lib/config.sh"
}

# Write a project-level config JSON.
qa_write_project_config() {
  local json="$1"
  printf '%s\n' "$json" >"$CLAUDE_PROJECT_DIR/.claude/copilot-qa-suite.json"
}

# Write a user-level config JSON.
qa_write_user_config() {
  local json="$1"
  printf '%s\n' "$json" >"$XDG_CONFIG_HOME/copilot-qa-suite/config.json"
}

# Install a stub binary on $PATH that prints args + stdin + canned stdout.
# Usage: qa_install_stub <name> <stdout-text> [<exit-code>]
qa_install_stub() {
  local name="$1" out="$2" rc="${3:-0}"
  local path="$BATS_TEST_TMPDIR/bin/$name"
  cat >"$path" <<EOF
#!/usr/bin/env bash
# auto-generated bats stub for $name
mkdir -p "\$BATS_TEST_TMPDIR/calls"
{
  printf 'cmd=%s\n' "$name"
  printf 'argv='
  printf '%q ' "\$@"
  printf '\n'
  printf 'stdin<<<\n'
  cat
  printf '\n>>>stdin\n'
} >>"\$BATS_TEST_TMPDIR/calls/$name.log"
printf '%s' '$out'
exit $rc
EOF
  chmod +x "$path"
}

# Same as qa_install_stub but writes a stub that emits stderr + exit-code
# to simulate a Copilot token-limit response.
qa_install_stub_with_stderr() {
  local name="$1" stdout="$2" stderr="$3" rc="${4:-0}"
  local path="$BATS_TEST_TMPDIR/bin/$name"
  cat >"$path" <<EOF
#!/usr/bin/env bash
mkdir -p "\$BATS_TEST_TMPDIR/calls"
{
  printf 'cmd=%s\n' "$name"
  printf 'argv='
  printf '%q ' "\$@"
  printf '\n'
} >>"\$BATS_TEST_TMPDIR/calls/$name.log"
printf '%s' '$stdout'
printf '%s' '$stderr' >&2
exit $rc
EOF
  chmod +x "$path"
}

qa_stub_calls_log() {
  local name="$1"
  local f="$BATS_TEST_TMPDIR/calls/$name.log"
  [[ -f "$f" ]] && cat "$f"
}

qa_stub_call_count() {
  local name="$1"
  local f="$BATS_TEST_TMPDIR/calls/$name.log"
  [[ -f "$f" ]] || { echo 0; return; }
  grep -c '^cmd=' "$f"
}
