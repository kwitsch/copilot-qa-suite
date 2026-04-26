#!/usr/bin/env bats
# Tests for hooks/lib/config.sh — the shared configuration library.
#
# Covers:
#   - default values (no overrides)
#   - layered precedence: env > project > user > defaults
#   - per-hook ENV beats global ENV beats per-hook JSON beats global JSON
#   - fast path (compiled session env-file) parity with slow path
#   - hash helpers (sha256_str / sha256_stdin)
#   - compute_range single-line + multi-line + missing-file failure
#   - spill_or_inline inline / truncate / spill behaviour
#   - validate_file_path traversal + absolute + symlink-escape rejection
#   - file_extension_allowed whitelist matching
#   - require_enabled exits 0 on disabled hook

load ../helpers/common

setup() { qa_setup_env; }

# ---------- defaults ----------

@test "load_config doc returns hardcoded defaults when no JSON layers exist" {
  rm -rf "$CLAUDE_PROJECT_DIR/.claude/copilot-qa-suite.json" \
         "$XDG_CONFIG_HOME/copilot-qa-suite/config.json"
  qa_source_config
  load_config doc
  [ "$CFG_MODEL" = "auto" ]
  [ "$CFG_TIMEOUT" = "90" ]
  [ "$CFG_HOOK_ENABLED" = "true" ]
  [ "$CFG_LOG_LEVEL" = "error" ]
  [ "$CFG_MAX_CONTEXT" = "8000" ]
  [ "$CFG_MAX_COMBINED" = "24000" ]
  [ "$CFG_SPILL_THRESHOLD" = "7000" ]
  [ "$CFG_SPILL_ENABLED" = "true" ]
  [ "$CFG_DOC_LANGUAGE" = "English" ]
  [ "$CFG_FALLBACK_ENABLED" = "true" ]
}

@test "load_config no longer exports CFG_FALLBACK_MODEL or CFG_FALLBACK_TIMEOUT" {
  qa_source_config
  load_config doc
  # These were removed when the fallback switched from `claude -p`
  # subprocess to context-instruction. Their continued presence would
  # indicate dead config drift.
  [ -z "${CFG_FALLBACK_MODEL:-}" ]
  [ -z "${CFG_FALLBACK_TIMEOUT:-}" ]
}

@test "load_config picks per-hook timeout from defaults.json (not the global default)" {
  qa_source_config
  load_config unittest
  [ "$CFG_TIMEOUT" = "120" ]
  load_config doc
  [ "$CFG_TIMEOUT" = "90" ]
}

@test "CFG_MAX_FINDINGS is set only for code_review" {
  qa_source_config
  load_config code_review
  [ "$CFG_MAX_FINDINGS" = "5" ]
  load_config doc
  [ -z "$CFG_MAX_FINDINGS" ]
}

@test "CFG_DOC_LANGUAGE is set only for doc" {
  qa_source_config
  load_config doc
  [ "$CFG_DOC_LANGUAGE" = "English" ]
  load_config code_review
  [ -z "$CFG_DOC_LANGUAGE" ]
}

# ---------- precedence ----------

@test "user JSON beats defaults" {
  qa_write_user_config '{"copilot":{"model":"gpt-5"}}'
  qa_source_config
  load_config doc
  [ "$CFG_MODEL" = "gpt-5" ]
}

@test "project JSON beats user JSON" {
  qa_write_user_config '{"copilot":{"model":"gpt-5"}}'
  qa_write_project_config '{"copilot":{"model":"sonnet"}}'
  qa_source_config
  load_config doc
  [ "$CFG_MODEL" = "sonnet" ]
}

@test "COPILOT_QA_MODEL env beats project JSON" {
  qa_write_project_config '{"copilot":{"model":"sonnet"}}'
  export COPILOT_QA_MODEL=opus
  qa_source_config
  load_config doc
  [ "$CFG_MODEL" = "opus" ]
}

@test "per-hook env COPILOT_QA_MODEL_DOC beats global COPILOT_QA_MODEL" {
  export COPILOT_QA_MODEL=opus
  export COPILOT_QA_MODEL_DOC=haiku
  qa_source_config
  load_config doc
  [ "$CFG_MODEL" = "haiku" ]
  load_config code_review
  [ "$CFG_MODEL" = "opus" ]
}

@test "per-hook JSON .doc.model beats global .copilot.model" {
  qa_write_project_config '{"copilot":{"model":"sonnet"},"doc":{"model":"opus"}}'
  qa_source_config
  load_config doc
  [ "$CFG_MODEL" = "opus" ]
  load_config code_review
  [ "$CFG_MODEL" = "sonnet" ]
}

@test "COPILOT_QA_ENABLED_CODE_REVIEW=false disables code_review only" {
  export COPILOT_QA_ENABLED_CODE_REVIEW=false
  qa_source_config
  load_config code_review
  [ "$CFG_HOOK_ENABLED" = "false" ]
  load_config doc
  [ "$CFG_HOOK_ENABLED" = "true" ]
}

@test "fallback enabled per-hook env beats global env beats JSON" {
  qa_write_project_config '{"fallback":{"enabled":true},"doc":{"fallback":{"enabled":true}}}'
  export COPILOT_QA_FALLBACK_ENABLED=false
  export COPILOT_QA_FALLBACK_ENABLED_DOC=true
  qa_source_config
  load_config doc
  [ "$CFG_FALLBACK_ENABLED" = "true" ]
  load_config code_review
  [ "$CFG_FALLBACK_ENABLED" = "false" ]
}

@test "global JSON fallback.enabled=false disables every hook without per-hook override" {
  qa_write_project_config '{"fallback":{"enabled":false}}'
  qa_source_config
  for h in doc code_review unittest proguard; do
    load_config "$h"
    [ "$CFG_FALLBACK_ENABLED" = "false" ]
  done
}

@test "per-hook fallback.enabled=false disables only that hook" {
  qa_write_project_config '{"doc":{"fallback":{"enabled":false}}}'
  qa_source_config
  load_config doc
  [ "$CFG_FALLBACK_ENABLED" = "false" ]
  load_config code_review
  [ "$CFG_FALLBACK_ENABLED" = "true" ]
}

# ---------- copilot github_token ----------

@test "CFG_COPILOT_TOKEN defaults to empty when neither env nor JSON sets it" {
  qa_source_config
  load_config doc
  [ -z "${CFG_COPILOT_TOKEN:-}" ]
}

@test "CFG_COPILOT_TOKEN reads from project JSON .copilot.github_token" {
  qa_write_project_config '{"copilot":{"github_token":"ghp_from_project"}}'
  qa_source_config
  load_config doc
  [ "$CFG_COPILOT_TOKEN" = "ghp_from_project" ]
}

@test "COPILOT_QA_COPILOT_TOKEN env beats project JSON" {
  qa_write_project_config '{"copilot":{"github_token":"ghp_from_project"}}'
  export COPILOT_QA_COPILOT_TOKEN=ghp_from_env
  qa_source_config
  load_config doc
  [ "$CFG_COPILOT_TOKEN" = "ghp_from_env" ]
}

@test "CFG_COPILOT_TOKEN survives the fast path round-trip" {
  qa_write_project_config '{"copilot":{"github_token":"ghp_round_trip"}}'
  qa_source_config
  compile_session_env
  unset CFG_COPILOT_TOKEN
  load_config doc
  [ "$CFG_COPILOT_TOKEN" = "ghp_round_trip" ]
}

# ---------- fast path / slow path parity ----------

@test "compile_session_env writes a session env-file with a source-stamp" {
  qa_source_config
  compile_session_env
  local f="$CLAUDE_PLUGIN_DATA/session"/*.env
  # shellcheck disable=SC2086
  [ -f $f ]
  grep -q '^# source-stamp: ' $f
  grep -q '^__CFG_MAX_CONTEXT=' $f
  grep -q '^__CFG_MODEL_doc=' $f
}

@test "fast path produces same CFG_MODEL as slow path for project override" {
  qa_write_project_config '{"copilot":{"model":"opus"},"doc":{"model":"haiku"}}'

  # Slow path (no compiled env-file yet).
  qa_source_config
  load_config doc
  local slow_model="$CFG_MODEL"

  # Compile then run again — fast path should hit.
  compile_session_env
  unset CFG_MODEL
  load_config doc
  local fast_model="$CFG_MODEL"

  [ "$slow_model" = "$fast_model" ]
  [ "$fast_model" = "haiku" ]
}

@test "fast path re-applies COPILOT_QA_* env-vars on top" {
  qa_source_config
  compile_session_env
  export COPILOT_QA_MODEL_DOC=opus
  unset CFG_MODEL
  load_config doc
  [ "$CFG_MODEL" = "opus" ]
}

@test "fast path falls through to slow path when source-stamp is stale" {
  qa_source_config
  compile_session_env
  # Mutate JSON state; source-stamp must mismatch -> slow path.
  qa_write_project_config '{"copilot":{"model":"opus"}}'
  unset CFG_MODEL
  load_config doc
  [ "$CFG_MODEL" = "opus" ]
}

# ---------- hash helpers ----------

@test "sha256_str produces stable hex digest" {
  qa_source_config
  local h
  h="$(sha256_str "abc")"
  [ "$h" = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" ]
}

@test "sha256_stdin matches sha256_str for identical input" {
  qa_source_config
  local a b
  a="$(sha256_str "hello world")"
  b="$(printf '%s' "hello world" | sha256_stdin)"
  [ "$a" = "$b" ]
}

# ---------- compute_range ----------

@test "compute_range returns 1-1 + non-zero on missing file" {
  qa_source_config
  run compute_range "anything" "/nonexistent/path"
  [ "$status" -ne 0 ]
  [ "$output" = "1-1" ]
}

@test "compute_range single-line needle returns single-line range" {
  qa_source_config
  printf 'line one\nneedle here\nline three\n' >"$BATS_TEST_TMPDIR/f.txt"
  run compute_range "needle here" "$BATS_TEST_TMPDIR/f.txt"
  [ "$status" -eq 0 ]
  [ "$output" = "2-2" ]
}

@test "compute_range multi-line needle uses full needle length" {
  qa_source_config
  printf 'first line\nsecond line\nthird line\nfourth line\n' >"$BATS_TEST_TMPDIR/f.txt"
  run compute_range $'second line\nthird line' "$BATS_TEST_TMPDIR/f.txt"
  [ "$status" -eq 0 ]
  [ "$output" = "2-3" ]
}

# ---------- spill_or_inline ----------

@test "spill_or_inline returns body unchanged when below threshold" {
  qa_source_config
  load_config doc
  CFG_SPILL_THRESHOLD=1000
  CFG_SPILL_ENABLED=true
  local body="small body"
  run spill_or_inline doc "/proj/x.kt" "$body"
  [ "$status" -eq 0 ]
  [ "$output" = "$body" ]
}

@test "spill_or_inline writes oversize body to cache and emits a reference" {
  qa_source_config
  load_config doc
  CFG_SPILL_THRESHOLD=10
  CFG_SPILL_ENABLED=true
  local body
  body="$(printf 'x%.0s' {1..200})"
  run spill_or_inline doc "/proj/foo.kt" "$body"
  [ "$status" -eq 0 ]
  [[ "$output" == *"saved to "*"/cache/doc/"*".findings.txt"* ]]
  # File must actually exist.
  local cache_path
  cache_path="$(echo "$output" | grep -oE '[^ ]+\.findings\.txt')"
  [ -f "$cache_path" ]
  [ "$(wc -c <"$cache_path")" = "200" ]
}

@test "spill_or_inline truncates inline when CFG_SPILL_ENABLED=false" {
  qa_source_config
  load_config doc
  CFG_SPILL_ENABLED=false
  CFG_MAX_CONTEXT=20
  local body
  body="$(printf 'a%.0s' {1..100})"
  run spill_or_inline doc "/proj/x.kt" "$body"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[... truncated due to max_context_chars=20 ...]"* ]]
}

# ---------- validate_file_path ----------

@test "validate_file_path rejects relative path" {
  qa_source_config
  run validate_file_path "relative/x.kt"
  [ "$status" -ne 0 ]
}

@test "validate_file_path rejects parent-traversal segment" {
  qa_source_config
  run validate_file_path "/proj/../etc/passwd"
  [ "$status" -ne 0 ]
}

@test "validate_file_path rejects newline in path" {
  qa_source_config
  run validate_file_path $'/proj/with\nnewline.kt'
  [ "$status" -ne 0 ]
}

@test "validate_file_path accepts a regular file inside CLAUDE_PROJECT_DIR" {
  qa_source_config
  printf 'x\n' >"$CLAUDE_PROJECT_DIR/ok.kt"
  run validate_file_path "$CLAUDE_PROJECT_DIR/ok.kt"
  [ "$status" -eq 0 ]
}

@test "validate_file_path rejects symlink that resolves outside CLAUDE_PROJECT_DIR" {
  qa_source_config
  printf 'secret\n' >"$BATS_TEST_TMPDIR/outside.txt"
  ln -s "$BATS_TEST_TMPDIR/outside.txt" "$CLAUDE_PROJECT_DIR/escape.kt"
  run validate_file_path "$CLAUDE_PROJECT_DIR/escape.kt"
  [ "$status" -ne 0 ]
}

# ---------- file_extension_allowed ----------

@test "file_extension_allowed accepts kt for code_review" {
  qa_source_config
  load_config code_review
  run file_extension_allowed "/p/x.kt" code_review
  [ "$status" -eq 0 ]
}

@test "file_extension_allowed rejects .md for code_review" {
  qa_source_config
  load_config code_review
  run file_extension_allowed "/p/README.md" code_review
  [ "$status" -ne 0 ]
}

@test "file_extension_allowed is case-insensitive" {
  qa_source_config
  load_config code_review
  run file_extension_allowed "/p/Foo.KT" code_review
  [ "$status" -eq 0 ]
}

# ---------- require_enabled ----------

@test "require_enabled exits 0 when CFG_HOOK_ENABLED=false" {
  qa_source_config
  load_config doc
  CFG_HOOK_ENABLED=false
  # Run in subshell so the exit doesn't kill bats.
  run bash -c "
    set -euo pipefail
    source '$CLAUDE_PLUGIN_ROOT/hooks/lib/config.sh'
    CFG_HOOK_ENABLED=false
    require_enabled
    echo SHOULD_NOT_REACH
  "
  [ "$status" -eq 0 ]
  [[ "$output" != *"SHOULD_NOT_REACH"* ]]
}

@test "require_enabled does nothing when CFG_HOOK_ENABLED=true" {
  qa_source_config
  load_config doc
  run bash -c "
    set -euo pipefail
    source '$CLAUDE_PLUGIN_ROOT/hooks/lib/config.sh'
    CFG_HOOK_ENABLED=true
    require_enabled
    echo OK
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}
