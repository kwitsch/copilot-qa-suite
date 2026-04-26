# CLAUDE.md — hooks/lib/

`config.sh` is the single shared Bash library. Sourced by every hook,
the dispatcher, and cleanup. Public API below — keep stable; breaking
changes ripple through every hook.

## Sourcing contract

Source AFTER `set -euo pipefail`, BEFORE any other logic. The lib
self-checks bash version and may re-exec via Homebrew bash on macOS
(system bash 3.2 silently no-ops `inherit_errexit`). Re-exec is
transparent — `$@` is preserved.

```bash
set -euo pipefail
source "${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}/hooks/lib/config.sh"
load_config "<hook>"
require_enabled
```

`$CLAUDE_PLUGIN_ROOT` env var beats the computed fallback — always
honor it first.

## Public API

### Config

| Function                         | Purpose                                                  |
|----------------------------------|----------------------------------------------------------|
| `load_config "<hook>"`           | Populates `CFG_*` vars for the named hook (fast path → slow path). |
| `require_enabled`                | Exits 0 if `CFG_HOOK_ENABLED != "true"`.                 |
| `load_extensions "<hook>"`       | Newline list from `languages.<hook>_extensions` (reads the compiled `__CFG_EXT_<hook>` array first; falls back to `_cfg_layered_get_array`). |
| `file_extension_allowed FP HOOK` | True if `FP`'s extension is whitelisted for the hook.    |
| `compile_session_env`            | Resolves all JSON layers into the per-project session env-file (`${CLAUDE_PLUGIN_DATA}/session/<sha>.env`). Called once by the `compile-config` SessionStart hook; no-op when the source-stamp matches. |
| `_cfg_layered_get '.path'`       | Read scalar across project > user > defaults.            |
| `_cfg_layered_get_array '.path'` | Read array across same precedence (newline-separated).   |

After `load_config`, exported vars:

`CFG_MODEL`, `CFG_LOG_LEVEL`, `CFG_TIMEOUT`, `CFG_MAX_CONTEXT`
(per-hook char budget, default 8000), `CFG_MAX_COMBINED` (aggregate
cap across all sub-hook outputs in dispatcher, default 24000),
`CFG_SPILL_THRESHOLD` (body size at which `spill_or_inline` writes to
disk, default 7000), `CFG_SPILL_ENABLED` (master switch for file
spill, default `true`), `CFG_HOOK_ENABLED`, `CFG_RATE_LIMIT`,
`CFG_DOC_LANGUAGE` (only for `doc`), `CFG_MAX_FINDINGS` (only for
`code_review`), `CFG_CONFIG_DIR` (plugin-private Copilot dir, already
mkdir-ed), `CFG_COPILOT_TOKEN` (GitHub PAT from
`COPILOT_QA_COPILOT_TOKEN` env or `.copilot.github_token` JSON;
empty when neither is set), `CFG_EXTRA_ARGS` (array),
`CFG_FALLBACK_ENABLED`, `CFG_FALLBACK_PATTERNS`.

`CFG_COPILOT_TOKEN` is consumed by `copilot-call.sh`, which exports
it into `COPILOT_GITHUB_TOKEN` for the Copilot invocation **only**
when the env var is unset — an existing `COPILOT_GITHUB_TOKEN`
always wins.

Model resolution chain (highest first):
`COPILOT_QA_MODEL_<HOOK>` -> `<hook>.model` -> `COPILOT_QA_MODEL` ->
`copilot.model` -> hardcoded `auto`. Per-hook always beats global.

Fallback resolution: only `enabled` is configurable
(`COPILOT_QA_FALLBACK_ENABLED_<HOOK>` -> `<hook>.fallback.enabled` ->
`COPILOT_QA_FALLBACK_ENABLED` -> `fallback.enabled` -> hardcoded
`true`). The context-instruction fallback does not invoke a second
model, so `model`, `timeout`, and `extra_args` no longer exist.

### Fast path vs. slow path

`load_config` first calls `_cfg_try_fast_path`, which sources the
compiled session env-file and re-applies `COPILOT_QA_*` env-vars on
top (env-vars stay highest precedence — they are NEVER baked at
compile time). On any miss (file absent, source-stamp mismatch
against current JSON mtimes/sizes, source error) it returns 1 and
the original layered jq logic runs unchanged.

The env-file uses plain assignment (`__CFG_FOO=bar`,
`__CFG_ARR=(a b)`) — never `declare -a`, so the variables remain
global when `source` is invoked from inside the
`_cfg_try_fast_path` function. Per-hook keys carry the hook name as
suffix (`__CFG_MODEL_doc`, `__CFG_TIMEOUT_code_review`, ...).
Globals (log_level, limits, fallback patterns, `__CFG_EXTRA_ARGS`)
have no suffix.

When editing config defaults or the resolver: re-run `compile.sh`
manually, or just bump `config/defaults.json`'s mtime — the
source-stamp check forces a rebuild. The slow path is the
self-healing fallback if you forget.

### Copilot wrapper (`copilot-call.sh`)

Sourced AFTER `config.sh` + `load_config`. Library file — does NOT
call `set -euo pipefail` (would mutate caller shell). Public API:

| Function                                    | Purpose                                                                                                                              |
|---------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------|
| `run_copilot_with_fallback PROMPT TPL TAIL` | Run copilot read-only; on token-limit signal, emit a sentinel + the assembled fallback instruction for the parent Claude session.    |
| `copilot_call_split RAW`                    | Parse the wrapper's stdout into `eval`-able `QA_ENGINE` / `QA_BODY` / `QA_REASON` assignments. No globals.                           |

Stdout from `run_copilot_with_fallback` carries one of two shapes:

1. Plain Copilot output, verbatim.
2. `__COPILOT_QA_FALLBACK_INSTRUCTION__\n` followed by
   `cat fallback-prompt.txt + CONTEXT_TAIL`. The constant
   `COPILOT_QA_FALLBACK_SENTINEL` exposes the marker.

The sentinel survives the `COPILOT_OUT="$(...)"` subshell that
sub-hooks use; bash function-locals would not. `copilot_call_split`
detects the prefix, strips it, and yields:

- `QA_ENGINE` — `"Copilot"` or `"Context-fallback (Copilot quota exhausted)"`.
- `QA_BODY`   — Copilot output, or the instruction prompt for the
  parent Claude.
- `QA_REASON` — empty on the Copilot path; one-line reason on the
  fallback path, suitable for `systemMessage`.

`PROMPT` is the full Copilot prompt. `TPL` is the absolute path to
the hook's `fallback-prompt.txt`. `TAIL` is the CONTEXT block tail
(the key/value lines after the `=== CONTEXT ===` header). For the doc
hook, `TAIL` also includes the per-language template because both
prompts end with the `LANGUAGE SPECIFICATION` header.

The hard read-only Copilot flag block is consolidated in the helper
`_copilot_readonly_flags` (single source of truth — keep both
whitelist and denylist intact, see core invariant in root
CLAUDE.md). Pure `timeout` exits (124) are NOT treated as token
limits and do not trigger fallback. The wrapper installs a
`trap "rm -f -- '$err_file'" EXIT` (path expanded at install time,
not via `$err_file` reference at trap-fire time) to clean up its
stderr-capture mktemp file. EXIT, not RETURN — RETURN traps persist
in the caller shell after the function unwinds and re-fire on the
next unrelated function exit, tripping `set -u` once the local has
gone out of scope.

### additionalContext sizing

| Function                                   | Purpose                                                                                              |
|--------------------------------------------|------------------------------------------------------------------------------------------------------|
| `spill_or_inline HOOK FILE_PATH BODY`      | Echoes BODY inline (with truncate) when small; spills to `<cache>/<hook>/<sha256(FILE)>.findings.txt` and echoes a factual reference when `${#BODY} >= CFG_SPILL_THRESHOLD` and `CFG_SPILL_ENABLED=true`. |

Why a controlled spill: Claude Code caps each hook injection at
10 000 characters and spills overflow to disk with an undocumented
preview format. Pre-empting it with a deterministic file path under
`_cfg_cache_dir` lets the model `Read` the full body when needed and
keeps the cache prunable via `cleanup.cache_max_age_days`. Sub-hooks
emit a per-finding header that stays inline; the bulky `--- FINDING
---` body is what spills.

The dispatcher applies a separate aggregate cap
(`CFG_MAX_COMBINED`, default 24000) over the concatenation of every
sub-hook's `additionalContext`. Overflow is written to
`<cache>/dispatcher/<sha256(path|ts)>.combined.txt`.

### Filesystem / safety

| Function                       | Notes                                                                 |
|--------------------------------|-----------------------------------------------------------------------|
| `validate_file_path "$fp"`     | Rejects empty, relative, newline/CR, `..` segments, missing files, and resolved paths outside `$CLAUDE_PROJECT_DIR` (realpath check). |
| `open_safe_fd "$fp"`           | Opens FD into `$SAFE_FD` for TOCTOU-safe multi-read.                  |
| `close_safe_fd`                | Closes `$SAFE_FD`, unsets it.                                         |
| `_cfg_cache_dir "<hook>"`      | `${CLAUDE_PLUGIN_DATA}/cache/<hook>` with sane fallbacks.             |
| `_cfg_cache_dir_init "$dir"`   | mkdir + chmod 700 (umask 077).                                         |
| `_cfg_copilot_config_dir`      | Plugin-private Copilot config dir (= `$CFG_CONFIG_DIR` post-load).    |
| `_cfg_plugin_data`             | Persistent state root (`$CLAUDE_PLUGIN_DATA` or fallback).            |

### Hashing (portable Linux/macOS)

| Function          | Input       |
|-------------------|-------------|
| `sha256_file F`   | file path   |
| `sha256_str S`    | string arg  |
| `sha256_stdin`    | stdin       |

Implementation prefers `sha256sum`, falls back to `shasum -a 256`,
finally `openssl dgst -sha256`. Do not call those utilities directly
— hooks would diverge on macOS.

### Range derivation

`compute_range NEW_STRING FILE` -> `start-end` on stdout. Multi-line
needles match against the first line; length comes from full needle.
Returns `1-1` + exit 1 on empty needle / missing file / no match
(treat as ambiguous).

## Path conventions

Never hardcode `/tmp` for cache — use `_cfg_cache_dir`. Resolution:
`$CLAUDE_PLUGIN_DATA` > `$XDG_CACHE_HOME/copilot-qa-suite` >
`${TMPDIR:-/tmp}/copilot-qa-$(id -u)`. UID-namespaced fallback
defends against symlink attacks on multi-user systems.

For Copilot calls, isolation is via `--config-dir="$CFG_CONFIG_DIR"`
flag (NOT `COPILOT_HOME` env var). The env var is consulted only by
`check-copilot/check.sh` to find the user's interactive Copilot for
auth detection.

## When editing this file

- Fix-tag references in comments (`a4`, `a8`, `a11`, `a12`, `a15`,
  `a18`, `a23`, `b3`, `b16`, `b21`) point to historical incidents.
  Preserve them — useful for git-blame archaeology.
- Functions prefixed `_cfg_` are internal; consumers use `CFG_*` vars
  or the wrapper helpers above.
- `// empty` in jq is forbidden where `false`/`0` are valid values —
  use `if (try ...) == null then empty else ...` (see `_cfg_jq_get`).
