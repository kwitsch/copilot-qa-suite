#!/usr/bin/env bats
# Tests for hooks/dispatcher/dispatch.sh — the PostToolUse router.
#
# Strategy:
#   Build a fake CLAUDE_PLUGIN_ROOT under $BATS_TEST_TMPDIR with
#     - config/      symlinked to the real defaults
#     - hooks/lib/   symlinked to the real lib (config.sh, copilot-call.sh)
#     - hooks/dispatcher/dispatch.sh symlinked to the real dispatcher
#     - hooks/{doc,code-review,unittest,proguard}/<script> as stubs
#       that echo a sentinel JSON, so we can verify which were invoked
#       without firing real Copilot/Claude calls.

load ../helpers/common

setup() {
  qa_setup_env

  local real_root fake_root
  real_root="$(qa_repo_root)"
  fake_root="$BATS_TEST_TMPDIR/plugin"
  mkdir -p "$fake_root/hooks/dispatcher" \
           "$fake_root/hooks/doc" \
           "$fake_root/hooks/code-review" \
           "$fake_root/hooks/unittest" \
           "$fake_root/hooks/proguard"
  ln -s "$real_root/config"                              "$fake_root/config"
  ln -s "$real_root/hooks/lib"                           "$fake_root/hooks/lib"
  ln -s "$real_root/hooks/dispatcher/dispatch.sh"        "$fake_root/hooks/dispatcher/dispatch.sh"

  for entry in "doc:analyze-doc.sh" \
               "code-review:review.sh" \
               "unittest:unittest.sh" \
               "proguard:validate.sh"; do
    local dir="${entry%%:*}" name="${entry##*:}"
    cat >"$fake_root/hooks/$dir/$name" <<EOF
#!/usr/bin/env bash
mkdir -p "\$BATS_TEST_TMPDIR/calls"
echo "$dir" >>"\$BATS_TEST_TMPDIR/calls/dispatch-fired.log"
cat >/dev/null
printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"ctx-from-$dir"}}\n'
EOF
    chmod +x "$fake_root/hooks/$dir/$name"
  done

  export CLAUDE_PLUGIN_ROOT="$fake_root"
}

# Run the dispatcher with a fabricated PostToolUse event.
qa_run_dispatch() {
  local file_path="$1" tool="${2:-Edit}"
  local input
  input="$(jq -n --arg t "$tool" --arg fp "$file_path" \
              '{tool_name:$t, tool_input:{file_path:$fp}}')"
  printf '%s' "$input" | "$CLAUDE_PLUGIN_ROOT/hooks/dispatcher/dispatch.sh"
}

qa_fired() {
  local f="$BATS_TEST_TMPDIR/calls/dispatch-fired.log"
  [[ -f "$f" ]] || { echo ""; return; }
  sort -u "$f" | tr '\n' ' '
}

# ---------- routing ----------

@test "Gradle file routes to proguard only" {
  printf 'plugins {}\n' >"$CLAUDE_PROJECT_DIR/build.gradle.kts"
  run qa_run_dispatch "$CLAUDE_PROJECT_DIR/build.gradle.kts"
  [ "$status" -eq 0 ]
  [ "$(qa_fired)" = "proguard " ]
  [[ "$output" == *"ctx-from-proguard"* ]]
}

@test "Test file routes to doc only" {
  mkdir -p "$CLAUDE_PROJECT_DIR/src"
  printf 'class FooTest {}\n' >"$CLAUDE_PROJECT_DIR/src/FooTest.kt"
  run qa_run_dispatch "$CLAUDE_PROJECT_DIR/src/FooTest.kt"
  [ "$status" -eq 0 ]
  [ "$(qa_fired)" = "doc " ]
}

@test "Source .kt file routes to doc + code-review + unittest sequentially" {
  mkdir -p "$CLAUDE_PROJECT_DIR/src"
  printf 'class Foo {}\n' >"$CLAUDE_PROJECT_DIR/src/Foo.kt"
  run qa_run_dispatch "$CLAUDE_PROJECT_DIR/src/Foo.kt"
  [ "$status" -eq 0 ]
  [ "$(qa_fired)" = "code-review doc unittest " ]
}

@test "Generated path is silently skipped" {
  mkdir -p "$CLAUDE_PROJECT_DIR/build/generated"
  printf 'x\n' >"$CLAUDE_PROJECT_DIR/build/generated/Foo.kt"
  run qa_run_dispatch "$CLAUDE_PROJECT_DIR/build/generated/Foo.kt"
  [ "$status" -eq 0 ]
  [ -z "$(qa_fired)" ]
  [ "$output" = "" ]
}

@test "node_modules path is silently skipped" {
  mkdir -p "$CLAUDE_PROJECT_DIR/node_modules/lib"
  printf 'x\n' >"$CLAUDE_PROJECT_DIR/node_modules/lib/x.ts"
  run qa_run_dispatch "$CLAUDE_PROJECT_DIR/node_modules/lib/x.ts"
  [ "$status" -eq 0 ]
  [ -z "$(qa_fired)" ]
}

@test "Missing file_path emits no JSON and exits 0" {
  run bash -c "echo '{}' | '$CLAUDE_PLUGIN_ROOT/hooks/dispatcher/dispatch.sh'"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "File outside CLAUDE_PROJECT_DIR is rejected by validate_file_path" {
  printf 'x\n' >"$BATS_TEST_TMPDIR/outside.kt"
  run qa_run_dispatch "$BATS_TEST_TMPDIR/outside.kt"
  [ "$status" -eq 0 ]
  [ -z "$(qa_fired)" ]
}

# ---------- combined output ----------

@test "Source-file routing produces a single combined hookSpecificOutput JSON" {
  mkdir -p "$CLAUDE_PROJECT_DIR/src"
  printf 'class Bar {}\n' >"$CLAUDE_PROJECT_DIR/src/Bar.kt"
  run qa_run_dispatch "$CLAUDE_PROJECT_DIR/src/Bar.kt"
  [ "$status" -eq 0 ]
  # Must be valid JSON.
  printf '%s' "$output" | jq -e '.hookSpecificOutput.hookEventName == "PostToolUse"' >/dev/null
  printf '%s' "$output" | jq -e '.hookSpecificOutput.additionalContext | contains("ctx-from-doc")' >/dev/null
  printf '%s' "$output" | jq -e '.hookSpecificOutput.additionalContext | contains("ctx-from-code-review")' >/dev/null
  printf '%s' "$output" | jq -e '.hookSpecificOutput.additionalContext | contains("ctx-from-unittest")' >/dev/null
}

@test "All-empty sub-hook output collapses to {}" {
  # Replace stubs with empty-output stubs.
  for entry in "doc:analyze-doc.sh" \
               "code-review:review.sh" \
               "unittest:unittest.sh" \
               "proguard:validate.sh"; do
    local dir="${entry%%:*}" name="${entry##*:}"
    cat >"$CLAUDE_PLUGIN_ROOT/hooks/$dir/$name" <<EOF
#!/usr/bin/env bash
cat >/dev/null
exit 0
EOF
    chmod +x "$CLAUDE_PLUGIN_ROOT/hooks/$dir/$name"
  done
  mkdir -p "$CLAUDE_PROJECT_DIR/src"
  printf 'class C {}\n' >"$CLAUDE_PROJECT_DIR/src/C.kt"
  run qa_run_dispatch "$CLAUDE_PROJECT_DIR/src/C.kt"
  [ "$status" -eq 0 ]
  [ "$output" = "{}" ]
}
