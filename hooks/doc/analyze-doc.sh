#!/usr/bin/env bash
# PostToolUse hook: documentation maintenance via Copilot CLI (read-only).
# Supports Kotlin, Java, JavaScript, TypeScript, Go, Rust.
# The source language is detected from the file extension; per language a
# format template is appended to the Copilot prompt.
#
# The natural language of the generated comments is configurable via
# `doc.comment_language` (or env var COPILOT_QA_DOC_LANGUAGE). Default: English.
#
# Claude is the only writer; Copilot may only read and reason.
set -euo pipefail

# ---------- Load config ----------
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
source "$PLUGIN_ROOT/hooks/lib/config.sh"
source "$PLUGIN_ROOT/hooks/lib/copilot-call.sh"
load_config "doc"
require_enabled

# ---------- 0. Copilot CLI available? Otherwise exit early. ----------
if ! command -v copilot >/dev/null 2>&1; then
  >&2 echo "copilot CLI not found - skipping doc analysis."
  exit 0
fi

# ---------- 1. Parse hook input ----------
INPUT="$(cat)"
TOOL_NAME="$(jq -r '.tool_name' <<<"$INPUT")"
FILE_PATH="$(jq -r '.tool_input.file_path // empty' <<<"$INPUT")"

# Validate file_path (a18) — silently exit on suspicious paths
validate_file_path "$FILE_PATH" || exit 0

# ---------- 2. Detect source language + format template by extension ----------
TEMPLATE_DIR="$(dirname "$0")/templates"
case "$FILE_PATH" in
  *.kt|*.kts)              SRC_LANG="Kotlin";     TEMPLATE="$TEMPLATE_DIR/kotlin.txt" ;;
  *.java)                  SRC_LANG="Java";       TEMPLATE="$TEMPLATE_DIR/java.txt" ;;
  *.ts|*.tsx)              SRC_LANG="TypeScript"; TEMPLATE="$TEMPLATE_DIR/typescript.txt" ;;
  *.js|*.jsx|*.mjs|*.cjs)  SRC_LANG="JavaScript"; TEMPLATE="$TEMPLATE_DIR/javascript.txt" ;;
  *.go)                    SRC_LANG="Go";         TEMPLATE="$TEMPLATE_DIR/go.txt" ;;
  *.rs)                    SRC_LANG="Rust";       TEMPLATE="$TEMPLATE_DIR/rust.txt" ;;
  *) exit 0 ;;
esac

# Skip generated / build paths
case "$FILE_PATH" in
  */node_modules/*|*/build/*|*/dist/*|*/target/*|*/.next/*|*/vendor/*|*/generated/*) exit 0 ;;
  *.generated.*|*.g.dart|*_pb2.py|*.pb.go|*.min.js|*.bundle.js) exit 0 ;;
esac

[[ -f "$FILE_PATH" ]] || exit 0
[[ -f "$TEMPLATE" ]] || { >&2 echo "Doc template missing: $TEMPLATE"; exit 0; }

RANGES=""
case "$TOOL_NAME" in
  Write)
    N="$(wc -l <"$FILE_PATH" | tr -d ' ')"
    RANGES="1-${N:-1}"
    ;;
  Edit)
    NEW="$(jq -r '.tool_input.new_string' <<<"$INPUT")"
    RANGES="$(compute_range "$NEW" "$FILE_PATH")"
    ;;
  MultiEdit)
    while IFS= read -r edit; do
      NEW="$(jq -r '.new_string' <<<"$edit")"
      R="$(compute_range "$NEW" "$FILE_PATH")"
      RANGES="${RANGES:+$RANGES,}$R"
    done < <(jq -c '.tool_input.edits[]' <<<"$INPUT")
    ;;
  *) exit 0 ;;
esac

[[ -z "$RANGES" ]] && exit 0

# ---------- 4. Call Copilot CLI (HARD read-only) with context-fallback ----------
# Both prompts (copilot-prompt.txt and fallback-prompt.txt) end with the
# "LANGUAGE SPECIFICATION" header. The per-language template + CONTEXT
# block is identical for both — it rides in CONTEXT_TAIL.
HEADER="$(dirname "$0")/copilot-prompt.txt"
FALLBACK_TEMPLATE="$(dirname "$0")/fallback-prompt.txt"
CONTEXT_TAIL="$(cat "$TEMPLATE")

============================================================
CONTEXT
============================================================
FILE: $FILE_PATH
SOURCE_LANGUAGE: $SRC_LANG
COMMENT_LANGUAGE: $CFG_DOC_LANGUAGE
CHANGED_LINES: $RANGES"
PROMPT="$(cat "$HEADER")
$CONTEXT_TAIL"

COPILOT_OUT="$(run_copilot_with_fallback "$PROMPT" "$FALLBACK_TEMPLATE" "$CONTEXT_TAIL")"
eval "$(copilot_call_split "$COPILOT_OUT")"

# ---------- 5. Empty / NO_FINDINGS only collapse the Copilot path ----------
if [[ "$QA_ENGINE" == "Copilot" ]]; then
  if [[ -z "${QA_BODY// }" ]] || [[ "$QA_BODY" == *"NO_FINDINGS"* ]]; then
    exit 0
  fi
fi

# Spill oversized output to a cache file or apply the inline truncate.
QA_BODY="$(spill_or_inline "doc" "$FILE_PATH" "$QA_BODY")"

# ---------- 6. Finding-format reference for Claude (factual) ----------
# Framed as documentation of the suggestion schema rather than imperative
# instructions. Per Claude Code hooks docs, factual context survives the
# prompt-injection defence; imperative phrasing risks being surfaced to
# the user instead of acted on.
INSTRUCTIONS="DOC SUGGESTION SCHEMA
========================
Each finding above carries an action and a per-language doc body.
Hook-contract semantics:

- action=NEW: doc block to insert immediately before the symbol
  declaration, above annotations / modifiers / visibility, with the
  symbol's indentation. Go format places no blank line between doc
  and declaration.
- action=UPDATE: replacement for the existing doc block. Manually
  added tags absent from the suggestion (@see, @sample, @deprecated
  for Kotlin/Java/TS; # Examples for Rust; 'Deprecated:' paragraph
  for Go) are preserved when not in conflict with the new logic.
- action=KEEP: existing block stays unchanged.

Per-language format:
- Kotlin / Java: /** ... */ with ' * ' line prefix.
- JavaScript:    /** ... */ with ' * ', types written as {Type}.
- TypeScript:    /** ... */ with ' * '; TSDoc forbids {Type} in tags.
- Go:            // per line, no blank line before the declaration.
- Rust:          /// for items, //! for containers, Markdown allowed.

Edits are scoped to the named symbols. MultiEdit is the natural fit
for >=2 symbols, Edit for a single symbol. The hook is read-only and
does not chain further Copilot calls. The session summary in
$CFG_DOC_LANGUAGE conventionally lists which symbols received
NEW / UPDATE / KEEP."

jq -n \
  --arg file "$FILE_PATH" \
  --arg src "$SRC_LANG" \
  --arg cmtlang "$CFG_DOC_LANGUAGE" \
  --arg ranges "$RANGES" \
  --arg engine "$QA_ENGINE" \
  --arg body "$QA_BODY" \
  --arg instr "$INSTRUCTIONS" \
  --arg sysmsg "$QA_REASON" \
  '{
    hookSpecificOutput: {
      hookEventName: "PostToolUse",
      additionalContext: ("DOC SUGGESTION (engine=\($engine), \($cmtlang), \($src) source) for \($file), changed lines \($ranges):\n\n\($body)\n\n\($instr)")
    }
  } + (if $sysmsg == "" then {} else {systemMessage: $sysmsg} end)'
