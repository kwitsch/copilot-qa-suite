#!/usr/bin/env bats
# Sub-hook contract tests (hooks/CLAUDE.md §"Sub-hook contract").
#
# Verifies the structural rules every PostToolUse sub-hook must follow.
# These tests do NOT execute hooks; they check the source for the
# required patterns. This catches contract drift at PR time without
# needing a live Copilot/Claude binary.

load ../helpers/common

setup() { qa_setup_env; }

SUB_HOOKS=(
  hooks/doc/analyze-doc.sh
  hooks/code-review/review.sh
  hooks/unittest/unittest.sh
  hooks/proguard/validate.sh
)

@test "every sub-hook starts with 'set -euo pipefail'" {
  local root
  root="$(qa_repo_root)"
  for s in "${SUB_HOOKS[@]}"; do
    # Among the first 30 non-comment, non-empty lines.
    grep -vE '^[[:space:]]*(#|$)' "$root/$s" | head -30 \
      | grep -qE '^set -euo pipefail$'
  done
}

@test "every sub-hook sources hooks/lib/config.sh" {
  local root
  root="$(qa_repo_root)"
  for s in "${SUB_HOOKS[@]}"; do
    grep -q 'hooks/lib/config.sh' "$root/$s"
  done
}

@test "every sub-hook calls load_config" {
  local root
  root="$(qa_repo_root)"
  for s in "${SUB_HOOKS[@]}"; do
    grep -qE 'load_config[[:space:]]+["a-z_]' "$root/$s"
  done
}

@test "every sub-hook calls require_enabled" {
  local root
  root="$(qa_repo_root)"
  for s in "${SUB_HOOKS[@]}"; do
    grep -q 'require_enabled' "$root/$s"
  done
}

@test "every sub-hook validates file_path before FS reads" {
  local root
  root="$(qa_repo_root)"
  for s in "${SUB_HOOKS[@]}"; do
    grep -q 'validate_file_path' "$root/$s"
  done
}

@test "every sub-hook routes oversize bodies through spill_or_inline" {
  local root
  root="$(qa_repo_root)"
  for s in "${SUB_HOOKS[@]}"; do
    grep -q 'spill_or_inline' "$root/$s"
  done
}

@test "every sub-hook ships a fallback-prompt.txt" {
  local root
  root="$(qa_repo_root)"
  for s in "${SUB_HOOKS[@]}"; do
    local dir
    dir="$(dirname "$root/$s")"
    [ -f "$dir/fallback-prompt.txt" ]
  done
}

@test "every sub-hook ships a copilot-prompt.txt" {
  local root
  root="$(qa_repo_root)"
  for s in "${SUB_HOOKS[@]}"; do
    local dir
    dir="$(dirname "$root/$s")"
    [ -f "$dir/copilot-prompt.txt" ]
  done
}

@test "hooks.json registers exactly one PostToolUse entry (single dispatcher invariant)" {
  local f="$(qa_repo_root)/hooks/hooks.json"
  local n
  n="$(jq '.PostToolUse | length' "$f")"
  [ "$n" = "1" ]
  jq -e '.PostToolUse[0].matcher == "Edit|Write|MultiEdit"' "$f" >/dev/null
  jq -e '.PostToolUse[0].hooks[0].command | endswith("dispatcher/dispatch.sh")' "$f" >/dev/null
}

@test "hooks.json registers compile-config + check-copilot SessionStart hooks in order" {
  local f="$(qa_repo_root)/hooks/hooks.json"
  jq -e '.SessionStart[0].hooks[0].command | endswith("compile-config/compile.sh")' "$f" >/dev/null
  jq -e '.SessionStart[0].hooks[1].command | endswith("check-copilot/check.sh")' "$f" >/dev/null
}
