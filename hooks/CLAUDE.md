# CLAUDE.md — hooks/

PostToolUse / SessionStart / SessionEnd hook scripts. Parent
`CLAUDE.md` covers the read-only invariant + cross-cutting
architecture; this file documents the sub-hook contract.

## Sub-hook contract

Every PostToolUse hook MUST:

1. `set -euo pipefail` first.
2. Source `lib/config.sh` (handles bash 4.4+ re-exec — do not
   re-implement).
3. `load_config "<hook>"` then `require_enabled`.
4. Read full stdin once: `INPUT="$(cat)"`. Parse with `jq <<<"$INPUT"`.
5. Validate `tool_input.file_path` via `validate_file_path` BEFORE any
   FS op (defends against traversal + symlink escape).
6. Skip generated/build paths — same list as `dispatch.sh`. If you add
   a pattern, update both.
7. Cache + rate-limit under `_cfg_cache_dir "<hook>"`. Hash key =
   `sha256_str "$FILE_PATH"`. Two shards: `<key>.sha256` + `<key>.timestamp`.
8. Exit 0 silently on cache hit, missing `copilot` binary, empty or
   `NO_FINDINGS` Copilot output. Hooks never block tool execution.
9. Pipe the Copilot/Claude body through
   `spill_or_inline "<hook>" "$FILE_PATH" "$BODY"` before splicing it
   into `additionalContext`. The helper writes oversize bodies
   (>= `$CFG_SPILL_THRESHOLD`) to
   `<cache>/<hook>/<sha256(path)>.findings.txt` and replaces them
   with a one-paragraph reference; smaller bodies are returned as-is
   (with the legacy `$CFG_MAX_CONTEXT` truncate as a fallback when
   `$CFG_SPILL_ENABLED=false`).
10. Frame behavioural notes for Claude as a **factual schema
    description** (`DOC SUGGESTION SCHEMA`, `CODE-REVIEW FINDING
    SCHEMA`, ...), not as imperative `INSTRUCTIONS FOR CLAUDE`.
    Imperative phrasing risks being routed through Claude's
    prompt-injection defence and surfaced to the user verbatim instead
    of acted on (per Claude Code hooks docs).
11. Emit one JSON object on success:

```json
{ "hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": "..."
} }
```

The dispatcher merges multiple sub-hook outputs into one combined
response and applies a separate `$CFG_MAX_COMBINED` aggregate cap
(spilling the concatenation to `<cache>/dispatcher/*.combined.txt`
when exceeded). Plain-text stdout is NOT a viable fallback for
PostToolUse — only `SessionStart`, `UserPromptSubmit`, and
`UserPromptExpansion` treat stdout as injected context.

## Dispatcher routing (dispatch.sh)

Authoritative classifier. Sub-hooks must not re-classify — extend
`dispatch.sh` instead.

| Class      | Patterns                                                              | Routes to                                |
|------------|-----------------------------------------------------------------------|------------------------------------------|
| Gradle     | `build.gradle[.kts]`, `settings.gradle[.kts]`, `libs.versions.toml`, `versions.toml` | `proguard/validate.sh`                   |
| Test file  | `*Test.kt`, `*Spec.kt`, `*.test.ts`, `*_test.py`, `*_test.go`, `*_spec.rb`, `*/tests/*`, `*/__tests__/*`, ... | `doc/analyze-doc.sh` only                |
| Source     | extension in `languages.code_review_extensions`                       | doc -> code-review -> unittest (sequential) |
| else       | —                                                                     | silent exit                               |

Sequential, not parallel — each sub-hook short-circuits via cache,
preserving rate-limit independence. Do not reintroduce parallel fan-out.

## Copilot invocation (read-only flag block)

Hooks no longer call `copilot` directly. They go through the wrapper
in `hooks/lib/copilot-call.sh`:

```bash
COPILOT_OUT="$(run_copilot_with_fallback \
  "$PROMPT" \
  "$(dirname "$0")/fallback-prompt.txt" \
  "$CONTEXT_TAIL")"
```

The wrapper assembles this Copilot call internally:

```
copilot \
  -p "$PROMPT" -s \
  --no-ask-user --no-auto-update --no-custom-instructions --no-alt-screen \
  --allow-all-paths \
  --config-dir="$CFG_CONFIG_DIR" \
  --available-tools='read' \
  --deny-tool='write' --deny-tool='shell' \
  --deny-tool='url'   --deny-tool='memory' \
  --disable-builtin-mcps \
  --model="$CFG_MODEL" --log-level="$CFG_LOG_LEVEL" \
  "${CFG_EXTRA_ARGS[@]}"
```

Wrap with `timeout "$CFG_TIMEOUT"`. `--config-dir` (not `COPILOT_HOME`
env) is the mechanism that isolates the plugin's `trusted_folders`
and session logs from the user's interactive Copilot.

When the wrapper detects a token / quota / rate / usage signal in
Copilot's stdout+stderr (regex `CFG_FALLBACK_PATTERNS`), it does NOT
spin up a second model. It emits the sentinel
`__COPILOT_QA_FALLBACK_INSTRUCTION__` (defined as
`COPILOT_QA_FALLBACK_SENTINEL` in `copilot-call.sh`) followed by
the assembled fallback prompt (`fallback-prompt.txt` + the CONTEXT
block tail) on stdout. The parent Claude session reads that
instruction through `additionalContext` and runs the analysis
itself with its existing read-only tools.

Sub-hooks call `copilot_call_split` to get the engine label, body,
and systemMessage reason without relying on globals (globals do not
propagate across the `COPILOT_OUT="$(...)"` subshell). Canonical
emit:

```bash
COPILOT_OUT="$(run_copilot_with_fallback "$PROMPT" "$FALLBACK_TEMPLATE" "$CONTEXT_TAIL")"
eval "$(copilot_call_split "$COPILOT_OUT")"
# now: $QA_ENGINE  $QA_BODY  $QA_REASON

if [[ "$QA_ENGINE" == "Copilot" ]]; then
  if [[ -z "${QA_BODY// }" ]] || [[ "$QA_BODY" == *"NO_FINDINGS"* ]]; then
    exit 0
  fi
fi
QA_BODY="$(spill_or_inline "<hook>" "$FILE_PATH" "$QA_BODY")"

jq -n --arg engine "$QA_ENGINE" \
      --arg body   "$QA_BODY" \
      --arg sysmsg "$QA_REASON" \
      …
      '{ hookSpecificOutput: { … } }
       + (if $sysmsg == "" then {} else {systemMessage: $sysmsg} end)'
```

Empty body / `NO_FINDINGS` only collapses the Copilot path; on the
context-fallback path `$QA_BODY` is the instruction prompt for the
parent Claude and must always be emitted.

## Finding text format (Copilot -> Claude)

Copilot emits `--- FINDING ---` blocks (text, not JSON). Each block
carries:

- `severity`: `CRITICAL` | `WARNING` | `INFO`
- `auto_fix`: `YES` | `NO`
- `action` (where applicable): `NEW` | `UPDATE` | `APPEND` | `REMOVE` | `REPLACE`
- `target_file`: absolute path Claude must edit (proguard hook NEVER
  names the Gradle file — only `.pro` files)
- `line_range`, `title`, `description`, `suggestion`

Hook-contract semantics are appended to `additionalContext` as a
factual `<HOOK> SCHEMA` block (e.g. `DOC SUGGESTION SCHEMA`,
`CODE-REVIEW FINDING SCHEMA`, `PROGUARD/R8 FINDING SCHEMA`). Keep that
block in sync when finding semantics change, and keep the wording
declarative — see Sub-hook contract item 10 for why.

## Loop-prevention contract

Three layers, all required when adding a hook:

1. **Content hash** under `cache/<hook>/<sha256(path)>.sha256` — skip
   when unchanged.
2. **Rate-limit timestamp** under `cache/<hook>/<sha256(path)>.timestamp`
   (defaults: review 15 s, unittest 20 s, proguard 30 s). Emit a brief
   skip notice rather than silent exit so Claude understands the gap.
3. **Recursion guard** — dispatcher routes test files to `doc` only.
   Proguard combines Gradle + all `*.pro` into a single hash; copy
   that pattern when state spans multiple files.

## When adding a new hook

1. New dir `hooks/<name>/` with executable script, `copilot-prompt.txt`,
   and `fallback-prompt.txt` (Anthropic-style XML-tagged template that
   emits the same output schema as the Copilot prompt).
2. Add routing in `dispatch.sh` (do NOT register a new top-level
   PostToolUse entry in `hooks.json` — single dispatcher only).
3. Add defaults under `timeouts.<name>`, `rate_limits.<name>_seconds`,
   `hooks_enabled.<name>`, `<name>.model`, and
   `<name>.fallback.enabled` in `config/defaults.json`.
4. Document new env vars in README (incl.
   `COPILOT_QA_FALLBACK_ENABLED_<HOOK>`).
5. Replicate all three loop-prevention layers.
6. Source `lib/copilot-call.sh`, call `run_copilot_with_fallback`,
   then `eval "$(copilot_call_split "$COPILOT_OUT")"` to derive
   `$QA_ENGINE` / `$QA_BODY` / `$QA_REASON`. Mirror the emit pattern
   in `code-review/review.sh` so engine switches surface in
   `additionalContext` and `systemMessage`.
