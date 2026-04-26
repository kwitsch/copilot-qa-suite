# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Claude Code plugin `copilot-qa-suite`. Pure Bash. No build, no tests,
no package manager. Runtime deps: bash 4.4+, `jq`, GNU `timeout`,
GitHub `copilot` CLI. Optional: `claude` CLI (the plugin's runtime
host) is also used as a token-limit fallback for the Copilot path.

## Core invariant

**Claude writes. Copilot only reads.** Every Copilot call MUST keep
the read-only flag combo intact:

```
--available-tools='read'
--deny-tool='write' --deny-tool='shell'
--deny-tool='url'   --deny-tool='memory'
--disable-builtin-mcps
--allow-all-paths --no-ask-user
--config-dir="$CFG_CONFIG_DIR"
```

Deny rules override allow rules in Copilot CLI even under `--yolo`.
Whitelist + denylist are intentionally redundant — keep both.

> Note: README mentions `read,view,glob,grep` in the whitelist for
> readability; actual hooks pass only `read`. Code wins.

## Engine fallback (context instruction)

When Copilot signals a token / quota / rate / usage limit, the wrapper
`hooks/lib/copilot-call.sh::run_copilot_with_fallback` does **not**
spin up a second model. It emits a sentinel
(`__COPILOT_QA_FALLBACK_INSTRUCTION__`) followed by the assembled
fallback prompt (`hooks/<hook>/fallback-prompt.txt` + the per-hook
CONTEXT block) on stdout. Sub-hooks detect the sentinel through
`copilot_call_split`, splice the instruction directly into
`additionalContext`, and the parent Claude session performs the
read-only analysis itself with its existing Read/Glob/Grep tools.
Single Claude session, single bill — and one less `--tools` whitelist
to keep aligned with the read-only invariant.

Pure timeouts (exit 124) do **not** trigger the fallback (would amplify
load). Detection regex `CFG_FALLBACK_PATTERNS` (ERE, case-insensitive,
matched against stdout+stderr). Configurable per hook through
`<hook>.fallback.enabled` and the `COPILOT_QA_FALLBACK_ENABLED[_<HOOK>]`
env vars. Hooks emit `systemMessage` when fallback fires so the user
sees the engine switch (`Context-fallback (Copilot quota exhausted)`).

`fallback-prompt.txt` is the per-hook instruction text the parent Claude
receives. Keep the documented output schema (`--- FINDING ---`,
`--- SYMBOL ---`, etc.) in sync with `copilot-prompt.txt` — both
templates feed the same downstream `additionalContext` reader.

## Architecture

Single-dispatcher PostToolUse design (no parallel fan-out):

```
PostToolUse (Edit|Write|MultiEdit)
  -> hooks/dispatcher/dispatch.sh
       Gradle file -> proguard/validate.sh
       Test file   -> doc/analyze-doc.sh   (only)
       Source file -> doc -> code-review -> unittest (sequential)
       else        -> silent {}
```

Sub-hooks never call Claude or write source. Findings flow back as
`additionalContext`; Claude decides what to apply. SessionStart runs
two hooks in order: `compile-config/compile.sh` (resolves the JSON
config layers into a sourceable env-file under
`${CLAUDE_PLUGIN_DATA}/session/<project-sha>.env`) and
`check-copilot/check.sh` (FS-only setup verification, no Copilot
call). SessionEnd (`cleanup/cleanup.sh`) prunes aged cache + logs.

Claude Code caps each hook injection at 10 000 characters; the
suite budgets 8K per sub-hook and 24K aggregate via
`limits.{max_context_chars,max_combined_chars}` and spills overflow
through `spill_or_inline` (per-hook) and
`<cache>/dispatcher/*.combined.txt` (aggregate) instead of relying
on the harness's undocumented preview format. Behavioural notes for
Claude are framed as **factual schema descriptions**, not imperative
instructions, so the prompt-injection defence does not surface them
to the user verbatim.

## Config layer

`hooks/lib/config.sh` is the single shared library. Precedence
(highest first):

1. `COPILOT_QA_*` env vars (incl. per-hook `COPILOT_QA_<KEY>_<HOOK>`)
2. `$CLAUDE_PROJECT_DIR/.claude/copilot-qa-suite.json`
3. `$XDG_CONFIG_HOME/copilot-qa-suite/config.json`
4. `config/defaults.json`

After `load_config "<hook>"`, use the `CFG_*` vars — never re-parse
JSON in hooks. Full API in `hooks/lib/CLAUDE.md`.

`load_config` has a fast path and a slow path. Fast path: source the
session env-file written by `compile-config/compile.sh` at
SessionStart, then re-apply ENV-var precedence on top. Slow path
(used when the env-file is missing or the source-stamp doesn't match
current JSON state): the original `_cfg_resolve_layered` chain that
forks `jq` per key. The fast path saves 60–180 `jq` forks per
PostToolUse Edit. The two paths share output semantics — same
`CFG_*` exports, same defaults — so callers don't branch.

Plugin-private state under `${CLAUDE_PLUGIN_DATA}` (fallbacks:
`${XDG_CACHE_HOME}/copilot-qa-suite`, `${TMPDIR}/copilot-qa-$(id -u)`).
Copilot CLI gets a private config dir (`$CFG_CONFIG_DIR`, default
`${CLAUDE_PLUGIN_DATA}/copilot/`) so `trusted_folders` stay isolated
from interactive `~/.copilot/`.

## Common tasks

Reload after editing a hook (no Claude restart):
```
/reload-plugins
```

Verify hooks register: `/hooks`

Manual hook test (replay a PostToolUse JSON event):
```bash
echo '{"tool_name":"Edit","tool_input":{"file_path":"/abs/path/file.kt","new_string":"x"}}' \
  | CLAUDE_PLUGIN_ROOT="$PWD" CLAUDE_PROJECT_DIR=/abs/proj \
    hooks/dispatcher/dispatch.sh
```

Clear cache:
```bash
rm -rf "${CLAUDE_PLUGIN_DATA:-$HOME/.cache/copilot-qa-suite}/cache"
```

Disable a hook for one run:
```bash
COPILOT_QA_ENABLED_CODE_REVIEW=false claude
```

## Where to find what

- Sub-hook contract, dispatcher routing table, finding schema:
  `hooks/CLAUDE.md`
- Public API of `config.sh`, `CFG_*` vars, hashing/range helpers:
  `hooks/lib/CLAUDE.md`
- Per-language doc-format invariants (TSDoc, godoc, rustdoc quirks):
  `hooks/doc/CLAUDE.md`
- User-facing config reference + env vars: `README.md`
