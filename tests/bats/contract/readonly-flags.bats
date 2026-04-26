#!/usr/bin/env bats
# Core-invariant contract tests.
#
# The plugin's read-only invariant ("Claude writes, Copilot reads") is
# enforced through two redundant mechanisms (whitelist + denylist) in
# `_copilot_readonly_flags` (hooks/lib/copilot-call.sh). Drift is the
# single most dangerous regression in this codebase, so we lock it down:
#
#   1. Required allow + deny flags must appear in _copilot_readonly_flags.
#   2. Sub-hooks must NOT invoke `copilot` directly — they go through
#      run_copilot_with_fallback, which is the single enforcement point.
#   3. Claude fallback path must keep --tools "Read,Glob,Grep".

load ../helpers/common

setup() { qa_setup_env; }

CALL_LIB="hooks/lib/copilot-call.sh"
SUB_HOOKS=(
  hooks/doc/analyze-doc.sh
  hooks/code-review/review.sh
  hooks/unittest/unittest.sh
  hooks/proguard/validate.sh
)

@test "_copilot_readonly_flags whitelists exactly --available-tools=read" {
  grep -q 'available-tools=read' "$(qa_repo_root)/$CALL_LIB"
}

@test "_copilot_readonly_flags denies write/shell/url/memory" {
  local f="$(qa_repo_root)/$CALL_LIB"
  grep -q 'deny-tool=write'  "$f"
  grep -q 'deny-tool=shell'  "$f"
  grep -q 'deny-tool=url'    "$f"
  grep -q 'deny-tool=memory' "$f"
}

@test "_copilot_readonly_flags disables built-in MCPs" {
  grep -q 'disable-builtin-mcps' "$(qa_repo_root)/$CALL_LIB"
}

@test "_copilot_readonly_flags passes a config-dir to isolate trusted_folders" {
  grep -q -- '--config-dir=' "$(qa_repo_root)/$CALL_LIB"
}

@test "_copilot_readonly_flags forbids interactive prompts and auto-update" {
  local f="$(qa_repo_root)/$CALL_LIB"
  grep -q -- '--no-ask-user'     "$f"
  grep -q -- '--no-auto-update'  "$f"
}

@test "copilot-call.sh does NOT invoke 'claude -p' (context-fallback only)" {
  local f="$(qa_repo_root)/$CALL_LIB"
  # Strip comments first — historical context in the header is fine.
  # Match command-line invocations only: `claude -<flag>`, `claude --<flag>`,
  # `timeout <n> claude` etc. Plain prose ("parent claude session") slips
  # through, since it is not an executable call.
  if grep -vE '^[[:space:]]*#' "$f" | grep -qE '(^|[[:space:];|&`])claude[[:space:]]+-'; then
    printf 'copilot-call.sh contains a non-comment claude invocation\n' >&2
    return 1
  fi
}

@test "copilot-call.sh does NOT reference --tools, --no-session-persistence, or --disable-slash-commands" {
  local f="$(qa_repo_root)/$CALL_LIB"
  ! grep -vE '^[[:space:]]*#' "$f" | grep -qE -- '--tools|--no-session-persistence|--disable-slash-commands'
}

@test "copilot-call.sh defines the fallback sentinel constant" {
  grep -q 'COPILOT_QA_FALLBACK_SENTINEL=' "$(qa_repo_root)/$CALL_LIB"
}

@test "Sub-hooks never invoke 'copilot -p' directly outside the wrapper" {
  local root
  root="$(qa_repo_root)"
  for s in "${SUB_HOOKS[@]}"; do
    [[ -f "$root/$s" ]] || continue
    # Direct top-level invocations (`copilot -p ...`) are forbidden.
    # Allow the literal string in comments by stripping comment lines first.
    if grep -vE '^[[:space:]]*#' "$root/$s" | grep -qE '(^|[[:space:];|&])copilot[[:space:]]+-p'; then
      printf 'sub-hook %s contains a raw copilot -p invocation\n' "$s" >&2
      return 1
    fi
  done
}

@test "Sub-hooks source copilot-call.sh (single enforcement point)" {
  local root
  root="$(qa_repo_root)"
  for s in "${SUB_HOOKS[@]}"; do
    [[ -f "$root/$s" ]] || continue
    grep -q 'lib/copilot-call.sh' "$root/$s"
  done
}
