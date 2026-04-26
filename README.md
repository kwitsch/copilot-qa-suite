# copilot-qa-suite

A Claude Code plugin that runs five quality-assurance hooks around your
edits. Each hook uses the GitHub Copilot CLI as a **hard-enforced
read-only analyst** — Copilot reads and reasons, but never writes.
Claude is the only agent with write access and applies the suggestions.

| Hook              | Event          | Trigger                          | Purpose                                                       |
|-------------------|----------------|----------------------------------|---------------------------------------------------------------|
| **check-copilot** | SessionStart   | every session start              | Verify Copilot availability, auth, and trust; warn early      |
| **doc**           | PostToolUse    | Kotlin, Java, JS, TS, Go, Rust   | Language-specific doc comments in your configured language    |
| **code-review**   | PostToolUse    | 15+ languages                    | Bugs, security, error handling, performance, maintainability  |
| **unittest**      | PostToolUse    | 15+ languages, no test files     | Test-coverage analysis with framework detection               |
| **proguard**      | PostToolUse    | Gradle files                     | Validate ProGuard/R8 rules against dependencies               |

All hooks emit structured findings with severity (CRITICAL / WARNING / INFO)
and an `auto_fix` flag. Claude only applies `auto_fix=YES` automatically
for risk-free changes; everything else is reported and the user decides.

When the GitHub Copilot CLI hits a token / quota / rate / usage limit,
the plugin transparently falls back to a **context-instruction** flow:
the per-hook fallback prompt is spliced directly into
`additionalContext` and the parent Claude session performs the
read-only analysis itself with its existing Read/Glob/Grep tools. No
second model is invoked, no second `--tools` whitelist to drift. See
[Engine fallback](#engine-fallback) below.

## Requirements

| Component       | Minimum             | Install                                          |
|-----------------|---------------------|--------------------------------------------------|
| Claude Code     | current             | https://docs.claude.com/claude-code              |
| Node.js         | 22+                 | via `nvm`, Homebrew, etc.                        |
| Copilot CLI     | current             | `npm install -g @github/copilot`                 |
| `jq`            | any                 | Linux: `apt install jq` · macOS: `brew install jq`|
| `timeout`       | GNU coreutils       | Linux: present · macOS: `brew install coreutils` |
| GitHub PAT      | Copilot scope       | Fine-grained token with "Copilot Requests" scope |

The PAT can be supplied in any of three places (highest priority first):

1. `COPILOT_GITHUB_TOKEN` env var — Copilot CLI's native auth variable.
   Always wins; the plugin never overwrites an existing value.
2. `COPILOT_QA_COPILOT_TOKEN` env var — plugin-scoped, exported into
   `COPILOT_GITHUB_TOKEN` for the duration of each Copilot call.
3. `copilot.github_token` in user config (`~/.config/copilot-qa-suite/config.json`).
   Convenient for laptops where you do not want a long-lived
   `COPILOT_GITHUB_TOKEN` in shell profile.

```bash
# Option 1 (most common — set before Claude Code starts)
export COPILOT_GITHUB_TOKEN=ghp_...

# Option 3 (~/.config/copilot-qa-suite/config.json, chmod 600)
{ "copilot": { "github_token": "ghp_..." } }
```

> ⚠️ Never commit a `github_token` value to a project-level
> `.claude/copilot-qa-suite.json`. Keep it in user config or env vars.

You also need to start `copilot` once interactively and trust your
working directory (`/login`, confirm trust dialog) — or set
`check_copilot.auto_trust_folder: true` and let the plugin do it
automatically (see below).

## Installation

Install via the Claude Code plugin marketplace:

```bash
claude plugin install kwitsch/copilot-qa-suite
```

See the
[Claude Code plugin marketplace documentation](https://code.claude.com/docs/en/plugin-marketplaces).

## Verifying

In a running Claude Code session:

```
/hooks
```

You should see one SessionStart hook plus four PostToolUse hooks, all
under `${CLAUDE_PLUGIN_ROOT}` paths.

Then edit any source file and wait. The first call may take 10–30
seconds while Copilot warms up. Findings appear as additional context
in Claude's next reply.

## What each hook does

### hooks/check-copilot — setup validation at session start

Runs at every session start (startup, resume, compact). Pure filesystem
checks, well under 100 ms. No Copilot call. Verifies in order:

1. **System dependencies** (`jq`, `timeout`) are installed
2. **`copilot` binary** is on PATH
3. **Authentication** present — either `COPILOT_GITHUB_TOKEN` /
   `GH_TOKEN` / `GITHUB_TOKEN` env var, or `~/.copilot/settings.json`
   (or `config.json` for older installs) exists, indicating that login
   ran at least once
4. **Working directory** is in `~/.copilot/{settings,config}.json` under
   `trusted_folders[]`, or is a child path of an entry there

When `check_copilot.auto_trust_folder: true` is set in your config,
step 4 fixes itself — the hook adds the working directory to
`trusted_folders` automatically (atomic temp+mv, mode 0600 on
fresh files). Default is `false` because granting trust is a security
decision the user should make consciously.

On problems: `additionalContext` with instructions for Claude to show
the warning in its very first reply, plus `systemMessage` as a banner
hint for Claude Code versions that render it. On automatic actions
without problems: short info note instead of a warning. When all clean:
silent `{}`.

### hooks/doc — language-specific doc maintenance

Triggers on edits to source files in six supported languages. The
source language is detected by file extension and the matching format
template is appended to the Copilot prompt:

| Extension                      | Source     | Doc format                       |
|--------------------------------|------------|----------------------------------|
| `.kt`, `.kts`                  | Kotlin     | KDoc                             |
| `.java`                        | Java       | Javadoc                          |
| `.ts`, `.tsx`                  | TypeScript | TSDoc (no types in tags!)        |
| `.js`, `.jsx`, `.mjs`, `.cjs`  | JavaScript | JSDoc                            |
| `.go`                          | Go         | godoc (prose, no tags)           |
| `.rs`                          | Rust       | rustdoc (Markdown + sections)    |

Copilot finds the enclosing symbol for each changed line, analyzes the
logic, and produces a complete doc comment in the **configured natural
language** (`doc.comment_language`, see "Configuration" below) using the
language's native format — correct tag order, format-specific quirks
(TSDoc forbids type annotations in tags, godoc requires the symbol name
as the first word with no blank line before the declaration, rustdoc
uses `# Errors` / `# Panics` / `# Safety` sections, with `Safety` being
required for `unsafe fn`), and no hallucinations. Claude inserts on
`action=NEW`, replaces on `UPDATE`, and preserves manually added tags
like `@see` / `@sample` (Kotlin/Java/TS) or `# Examples` blocks (Rust).

### hooks/code-review — code review

Triggers on edits across 15+ languages (Kotlin, Java, Scala, Groovy,
TS/JS including JSX/TSX/MJS/CJS, Python, Ruby, PHP, Go, Rust, C/C++,
Swift). Skips generated paths and build artifacts. Copilot inspects
the changed lines for bugs, security issues, error handling,
concurrency, performance, resource leaks, and maintainability —
conservatively, with severity classification. Claude fixes
CRITICAL+`auto_fix=YES` immediately, asks on CRITICAL+NO, reports
WARNING/INFO only.

### hooks/unittest — test-coverage analysis

Triggers on edits to production source — **test files themselves are
excluded** to prevent recursion. Copilot detects the test framework
from build/config files (JUnit5, Kotest, pytest, Jest, Vitest,
go-test, rust-test, PHPUnit, RSpec, etc.), determines the project's
test-file convention, and checks coverage. On CRITICAL+`auto_fix=YES`
Claude creates new test files or appends tests to existing ones.

### hooks/proguard — ProGuard/R8 rule validation

Triggers on edits to `build.gradle`, `build.gradle.kts`,
`settings.gradle[.kts]`, `libs.versions.toml`, or `versions.toml`.
The hook walks up to find the project root (via
`settings.gradle[.kts]` or `.git`) and gathers all ProGuard files in
the project (`proguard-*.pro`, `proguard-rules.pro`,
`consumer-rules.pro`, `consumer-proguard-rules.pro`, excluding `build/`
and `.gradle/`). If none exist, the hook is silent — the project does
not use ProGuard/R8.

Copilot reads the changed Gradle file, extracts dependencies (including
version-catalog references), checks whether minification is active
(`minifyEnabled` / `isMinifyEnabled = true`), and compares against an
internal catalog of well-known libraries that need consumer-side keep
rules (Retrofit, Gson, Jackson, Moshi, Kotlin Serialization, Room,
Firebase, Protobuf, Epoxy, Navigation Args, etc.). Findings are
categorized:

- `MISSING_RULE` (typically CRITICAL): library needs a rule, rule absent
- `OBSOLETE_RULE` (typically WARNING): rule exists, library no longer does
- `REDUNDANT_RULE` (INFO): shadowed by a broader rule
- `MISCONFIG` (typically CRITICAL): conflicting configuration

Claude applies findings with `auto_fix=YES` via the `action` field
(`APPEND` / `REMOVE` / `REPLACE`), always in the named `target_file`
only — **never in the Gradle file itself**.

## Loop prevention

The unittest hook creates test files which can themselves be reviewed
by code-review and (for `.kt`) doc. The proguard hook writes to `.pro`
files which themselves do not trigger any hook, but their changes are
detected via the combined content hash if a Gradle edit follows. Three
mechanisms keep this from looping:

1. **Content hash** per file (or combined for ProGuard) under
   `${CLAUDE_PLUGIN_DATA}/cache/{code-review,unittest,proguard}/` (or `${XDG_CACHE_HOME}/copilot-qa-suite/...` outside Claude Code). Identical
   content since the last run -> skip.
2. **Rate limit** per file — configurable. Defaults: code-review 15 s,
   unittest 20 s, proguard 30 s.
3. **Test-file exclusion** in the unittest hook.

## Read-only enforcement on Copilot

Each hook calls Copilot with this flag combination:

```
--available-tools='read,view,glob,grep'   # whitelist
--deny-tool='write'                       # hard block
--deny-tool='shell'
--deny-tool='url'
--deny-tool='memory'
--disable-builtin-mcps                    # blocks GitHub MCP server
--allow-all-paths --no-ask-user           # headless
```

In the Copilot CLI, deny rules always override allow rules — even
`--yolo`. Two independent defenses are active: the whitelist hides
write tools at selection time, and the deny list blocks them hard if
ever requested.

## Engine fallback

Each Copilot-driven hook (doc, code-review, unittest, proguard) routes
its call through `hooks/lib/copilot-call.sh::run_copilot_with_fallback`.
The wrapper:

1. Invokes `copilot` with the read-only flag block above, capturing
   stdout and stderr separately.
2. Inspects the combined output against `fallback.detection_patterns`
   (ERE, case-insensitive). Default patterns cover the common
   token / quota / rate / usage-limit phrasings: `rate.?limit`,
   `quota`, `premium request`, `monthly limit`, `usage limit`,
   `too many requests`, `429`, `exceeded.*limit`, `limit.*exceeded`.
3. On a match, the wrapper does **not** start a second model. It
   prefixes the per-hook `fallback-prompt.txt` (Anthropic-style
   XML-tagged template, identical output schema) plus the CONTEXT
   block tail with the sentinel `__COPILOT_QA_FALLBACK_INSTRUCTION__`
   and prints the lot on stdout.
4. The sub-hook calls `copilot_call_split` to derive
   `$QA_ENGINE` / `$QA_BODY` / `$QA_REASON`, splices the instruction
   directly into `additionalContext` (engine label
   `Context-fallback (Copilot quota exhausted)`), and emits a one-line
   `systemMessage` so the user sees that fallback fired.
5. The parent Claude session — the same one that triggered the hook —
   reads the instruction and performs the read-only analysis itself
   with its existing Read/Glob/Grep tools.

A pure timeout (`timeout` exit code 124) is **not** treated as a
limit — fallback would amplify load instead of dampen it.

### Why context-instruction (and not `claude -p`)

Earlier versions of the plugin spun up a fresh `claude -p` subprocess
on every fallback, paying for an inner model and round-tripping its
output back through the hook parser. The current flow keeps the work
inside the parent Claude session:

- One Claude session, one bill.
- One `--tools` whitelist to keep aligned with the read-only invariant
  (Copilot's deny list); the previous Claude path had its own
  `--tools "Read,Glob,Grep"` block to maintain.
- Recursion safety is structural: the parent already enforces its own
  read-only contract for hook contexts.

### Disabling the fallback

Both globally and per hook. Disable via JSON…

```json
{
  "fallback": { "enabled": false }
}
```

…or per hook…

```json
{
  "doc": { "fallback": { "enabled": false } }
}
```

…or via env vars (top-level + per-hook beat JSON):

```bash
# globally
export COPILOT_QA_FALLBACK_ENABLED=false

# only for one hook
export COPILOT_QA_FALLBACK_ENABLED_DOC=false
```

When disabled, a Copilot token-limit hit is treated as a silent miss
(no findings, hook exits 0), identical to pre-fallback behaviour.

## Configuration

All hooks share a central configuration layer. Values are resolved in
this precedence order (highest priority first):

1. **Environment variables** (`COPILOT_QA_*`) — per-invocation, ideal
   for experiments and CI
2. **Project config** at `$CLAUDE_PROJECT_DIR/.claude/copilot-qa-suite.json`
   — team-specific, commit it to the repo
3. **User config** at `~/.config/copilot-qa-suite/config.json` (or
   `$XDG_CONFIG_HOME/copilot-qa-suite/config.json`) — personal defaults
   across all projects
4. **Plugin defaults** in `config/defaults.json` — fallback

Each layer overrides only the fields it explicitly sets; everything
else falls through to the next layer.

### All config options

| JSON path                              | Type    | Default                    | Effect                                                                                                          |
|----------------------------------------|---------|----------------------------|-----------------------------------------------------------------------------------------------------------------|
| `copilot.model`                        | string  | `auto`               | Global default Copilot model used by every hook unless overridden per hook.                                     |
| `copilot.config_dir`                   | string? | `null`                     | Plugin-private Copilot config directory. When `null`, defaults to `${CLAUDE_PLUGIN_DATA}/copilot` — isolates trusted_folders and model state from your interactive Copilot. |
| `copilot.log_level`                    | string  | `error`                    | Copilot CLI log level. One of `error`, `warn`, `info`, `debug`.                                                 |
| `copilot.github_token`                 | string? | `null`                     | GitHub PAT (Copilot Requests scope). Exported into `COPILOT_GITHUB_TOKEN` for each Copilot call, **only if** the env var is unset. Keep this in user config (`chmod 600`) — never commit it to project config. |
| `copilot.extra_args`                   | array   | `[]`                       | Additional flags forwarded to every `copilot` invocation. Strings.                                              |
| `fallback.enabled`                     | boolean | `true`                     | Master switch for the context-instruction fallback. When `false`, a Copilot token/quota limit is treated as silent miss. |
| `fallback.detection_patterns`          | string  | (see defaults.json)        | ERE regex (case-insensitive) matched against Copilot stdout+stderr. On hit the wrapper emits the instruction.   |
| `<hook>.fallback.enabled`              | bool?   | `null`                     | Per-hook override for `fallback.enabled` (`null` inherits global).                                              |
| `timeouts.default`                     | int     | `90`                       | Fallback timeout (seconds) for hooks that don't set their own.                                                  |
| `timeouts.doc`                         | int     | `90`                       | Doc hook Copilot call timeout in seconds.                                                                       |
| `timeouts.code_review`                 | int     | `90`                       | Code-review hook timeout in seconds.                                                                            |
| `timeouts.unittest`                    | int     | `120`                      | Unit-test hook timeout in seconds (longer because Copilot may need to read more files).                         |
| `timeouts.proguard`                    | int     | `120`                      | ProGuard hook timeout in seconds (reads Gradle plus all `.pro` files).                                          |
| `rate_limits.code_review_seconds`      | int     | `15`                       | Minimum seconds between two reviews of the same file. Dampens edit-fix-edit loops.                              |
| `rate_limits.unittest_seconds`         | int     | `20`                       | Minimum seconds between two unit-test analyses of the same file.                                                |
| `rate_limits.proguard_seconds`         | int     | `30`                       | Minimum seconds between two ProGuard validations against the same Gradle+pro set.                               |
| `limits.max_context_chars`             | int     | `8000`                     | Per-hook char budget for `additionalContext`. Sits 2K below Claude Code's 10 000-char hook-injection cap.       |
| `limits.max_combined_chars`            | int     | `24000`                    | Aggregate cap across all sub-hook outputs concatenated by the dispatcher. Overflow is spilled to a cache file.  |
| `limits.spill_threshold_chars`         | int     | `7000`                     | Body size at which a sub-hook writes the full Copilot output to `<cache>/<hook>/*.findings.txt` and references it inline. |
| `limits.spill_to_file`                 | boolean | `true`                     | Master switch for the file-spill behaviour. `false` reverts to plain truncation at `max_context_chars`.         |
| `languages.code_review_extensions`     | array   | `[kt, java, ts, ...]`      | File extensions (without leading dot) that trigger the code-review hook. 24 entries by default.                 |
| `languages.unittest_extensions`        | array   | `[kt, java, ts, ...]`      | File extensions that trigger the unit-test hook. Same default list as code-review.                              |
| `hooks_enabled.doc`                    | boolean | `true`                     | Enables/disables the doc hook entirely.                                                                         |
| `hooks_enabled.code_review`            | boolean | `true`                     | Enables/disables the code-review hook entirely.                                                                 |
| `hooks_enabled.unittest`               | boolean | `true`                     | Enables/disables the unit-test hook entirely.                                                                   |
| `hooks_enabled.proguard`               | boolean | `true`                     | Enables/disables the ProGuard hook entirely.                                                                    |
| `hooks_enabled.check_copilot`          | boolean | `true`                     | Enables/disables the SessionStart setup-check hook.                                                             |
| `doc.model`                            | string? | `null`                     | Per-hook model override. When `null`, falls back to `copilot.model`.                                            |
| `doc.comment_language`                 | string  | `English`                  | Natural language for the generated doc comments. Use any name Copilot understands (`German`, `French`, etc.).   |
| `code_review.model`                    | string? | `null`                     | Per-hook model override for the code-review hook.                                                               |
| `code_review.max_findings`             | int     | `5`                        | Caps the number of findings Copilot may emit per file. Keeps `additionalContext` small and fix-fatigue down.    |
| `unittest.model`                       | string? | `null`                     | Per-hook model override for the unit-test hook. Note: tests are emitted **without comments** by design.         |
| `proguard.model`                       | string? | `null`                     | Per-hook model override for the ProGuard hook.                                                                  |
| `check_copilot.auto_trust_folder`      | boolean | `false`                    | When `true`, the SessionStart hook adds the working directory to Copilot's `trusted_folders` automatically.     |

### Environment variables

Every JSON path has a corresponding env var. Per-hook env vars beat per-hook config; global env vars beat global config.

| Variable                                | Overrides                                | Notes                                                          |
|-----------------------------------------|------------------------------------------|----------------------------------------------------------------|
| `COPILOT_QA_MODEL`                      | `copilot.model`                          | Global model fallback                                          |
| `COPILOT_QA_MODEL_DOC`                  | `doc.model`                              | Per-hook model for doc                                         |
| `COPILOT_QA_MODEL_CODE_REVIEW`          | `code_review.model`                      | Per-hook model for code-review                                 |
| `COPILOT_QA_MODEL_UNITTEST`             | `unittest.model`                         | Per-hook model for unit-test                                   |
| `COPILOT_QA_MODEL_PROGUARD`             | `proguard.model`                         | Per-hook model for ProGuard                                    |
| `COPILOT_QA_LOG_LEVEL`                  | `copilot.log_level`                      | `error` / `warn` / `info` / `debug`                            |
| `COPILOT_QA_COPILOT_TOKEN`              | `copilot.github_token`                   | GitHub PAT. Plugin-scoped — exported into `COPILOT_GITHUB_TOKEN` per Copilot call when the latter is unset. |
| `COPILOT_QA_TIMEOUT_DOC`                | `timeouts.doc`                           | Seconds                                                        |
| `COPILOT_QA_TIMEOUT_CODE_REVIEW`        | `timeouts.code_review`                   | Seconds                                                        |
| `COPILOT_QA_TIMEOUT_UNITTEST`           | `timeouts.unittest`                      | Seconds                                                        |
| `COPILOT_QA_TIMEOUT_PROGUARD`           | `timeouts.proguard`                      | Seconds                                                        |
| `COPILOT_QA_RATE_CODE_REVIEW`           | `rate_limits.code_review_seconds`        | Rate-limit window in seconds                                   |
| `COPILOT_QA_RATE_UNITTEST`              | `rate_limits.unittest_seconds`           | Rate-limit window in seconds                                   |
| `COPILOT_QA_RATE_PROGUARD`              | `rate_limits.proguard_seconds`           | Rate-limit window in seconds                                   |
| `COPILOT_QA_MAX_CONTEXT`                | `limits.max_context_chars`               | Per-hook char cap                                              |
| `COPILOT_QA_MAX_COMBINED`               | `limits.max_combined_chars`              | Aggregate cap in dispatcher                                    |
| `COPILOT_QA_SPILL_THRESHOLD`            | `limits.spill_threshold_chars`           | Body size that triggers file spill                             |
| `COPILOT_QA_SPILL_TO_FILE`              | `limits.spill_to_file`                   | `true` / `false`                                               |
| `COPILOT_QA_DOC_LANGUAGE`               | `doc.comment_language`                   | Comment language for doc hook                                  |
| `COPILOT_QA_MAX_FINDINGS`               | `code_review.max_findings`               | Findings cap for code-review hook                              |
| `COPILOT_QA_ENABLED_DOC`                | `hooks_enabled.doc`                      | `true` / `false`                                               |
| `COPILOT_QA_ENABLED_CODE_REVIEW`        | `hooks_enabled.code_review`              | `true` / `false`                                               |
| `COPILOT_QA_ENABLED_UNITTEST`           | `hooks_enabled.unittest`                 | `true` / `false`                                               |
| `COPILOT_QA_ENABLED_PROGUARD`           | `hooks_enabled.proguard`                 | `true` / `false`                                               |
| `COPILOT_QA_ENABLED_CHECK_COPILOT`      | `hooks_enabled.check_copilot`            | `true` / `false`                                               |
| `COPILOT_QA_FALLBACK_ENABLED`           | `fallback.enabled`                       | Global on/off for the context-instruction fallback             |
| `COPILOT_QA_FALLBACK_ENABLED_<HOOK>`    | `<hook>.fallback.enabled`                | Per-hook override (`DOC` / `CODE_REVIEW` / `UNITTEST` / `PROGUARD`) |
| `COPILOT_QA_FALLBACK_PATTERNS`          | `fallback.detection_patterns`            | ERE regex (case-insensitive) for the token-limit signal        |

### Notes on selected fields

**`doc.comment_language`** — controls the natural language of generated
doc comments. The doc-format syntax stays native (KDoc, Javadoc, JSDoc,
TSDoc, godoc, rustdoc) — only the prose changes. Identifiers, types,
and code snippets always remain in the source language. Tested values
include `English` (default), `German` / `Deutsch`, `French`, `Spanish`,
`Italian`, `Portuguese`, `Japanese`, `Chinese`, `Korean`. Other
languages work as long as Copilot understands the name.

**`code_review.max_findings`** — Copilot is instructed to prioritize
by severity (CRITICAL > WARNING > INFO) and within the same severity
by likelihood of real-world impact when the limit forces it to drop
candidates. The remainder is dropped silently — re-running after fixing
the top ones surfaces the next batch.

**`unittest.model`** — the unit-test hook is configured to emit tests
**without any comments**. Documentation is added afterwards by the doc
hook when it fires on the newly created test file. This avoids
duplicate (and likely worse) doc generation, and keeps Copilot's
output within the 10 KB `additionalContext` budget.

**Engine fallback** — see the [Engine fallback](#engine-fallback)
section above for the full picture (detection, claude-side read-only
flags, recursion safety, auth). The fallback is enabled by default
with model `haiku`. Per-hook overrides exist under `<hook>.fallback`
and via `COPILOT_QA_FALLBACK_*[_<HOOK>]` env vars; precedence matches
`CFG_MODEL`. A pure `timeout` (exit 124) is not treated as a limit
and does not trigger the fallback.

**Per-hook model precedence** — for a given hook, the model is
resolved as: `COPILOT_QA_MODEL_<HOOK>` env var → `<hook>.model` config
field → `COPILOT_QA_MODEL` env var → `copilot.model` config field →
hardcoded fallback `auto`. Setting `<hook>.model: null` (the
default) falls through to the global model. This lets you run a small
fast model for code review and a beefier one for unit-test generation
without duplicating other config:

```json
{
  "copilot": { "model": "auto" },
  "unittest": { "model": "claude-opus-4.7" }
}
```

**`check_copilot.auto_trust_folder`** — when `true`, the SessionStart
hook adds the working directory to Copilot's `trusted_folders` in the
**plugin-private** config dir (`${CLAUDE_PLUGIN_DATA}/copilot/settings.json`
by default) if it isn't there yet. Saves the one-time manual
confirmation per new project. Default is intentionally `false`, because
granting trust is a security decision — once trusted, Copilot can act
in that directory without further prompting. The hook writes
atomically (temp + mv) and creates new files with `0600` permissions.

**`check_copilot.inherit_user_trust`** — when `true`, on first run per
project the SessionStart hook copies matching `trusted_folders` from
`~/.copilot/{settings,config}.json` into the plugin-private config dir
(filtered to entries that actually contain the current project path).
This is a **one-time** action, recorded via
`${CLAUDE_PLUGIN_DATA}/copilot/inherit_consent.marker`. Useful when
migrating an existing trusted setup into the plugin's isolated config.
Default `false`.

**`cleanup.*`** — controls the `SessionEnd` cleanup hook.
`cache_max_age_days` (default 7) prunes file-content cache shards;
`copilot_logs_max_age_days` (default 14) prunes Copilot CLI's own
session logs in the plugin-private config dir. Set either to `0` to
disable that pruning step.

**`hooks_enabled.*`** — each hook can be turned off independently. A
disabled hook exits with status 0 immediately on invocation; no
Copilot call, no log noise.

### Examples

**Use a different model for one project:**

```json
// $PROJECT/.claude/copilot-qa-suite.json
{ "copilot": { "model": "claude-opus-4.7" } }
```

**Cheap model for code review, premium for tests:**

```json
{
  "copilot": { "model": "auto" },
  "unittest": { "model": "claude-opus-4.7" }
}
```

**Disable code review locally, keep doc:**

```json
{ "hooks_enabled": { "code_review": false } }
```

**Enable only doc and check_copilot, disable everything else:**

```json
{
  "hooks_enabled": {
    "doc": true,
    "code_review": false,
    "unittest": false,
    "proguard": false,
    "check_copilot": true
  }
}
```

**Quickly skip the doc hook (e.g. during refactoring):**

```bash
COPILOT_QA_ENABLED_DOC=false claude
```

**German doc comments for a specific repo:**

```json
{ "doc": { "comment_language": "German" } }
```

**Three findings instead of five:**

```json
{ "code_review": { "max_findings": 3 } }
```

**Restrict code review to a few languages:**

```json
{
  "languages": {
    "code_review_extensions": ["kt", "java", "ts", "go"]
  }
}
```

## Troubleshooting

**"copilot CLI not found" in stderr**: `copilot` is not on PATH. Run
`which copilot`; reinstall with `npm install -g @github/copilot` or fix
your Node PATH.

**Copilot hangs for 90+ seconds**: timeout fires, hook exits silently.
Often missing authentication — start `copilot` interactively once and
go through `/login`.

**Hook fires but no output appears in Claude**: either Copilot returned
`NO_FINDINGS` (clean code, intentionally silent) or the hash cache says
"already reviewed". Clear the cache:
`rm -rf ${CLAUDE_PLUGIN_DATA}/cache`.

**Repeating false-positive loops in code review**: the built-in
instruction to Claude usually catches this ("ignore findings you
already fixed in this same turn"). For stubborn cases: increase the
rate limit to 30 s in your config.

**Context output limit exceeded**: Claude Code hard-caps each hook
injection at 10 000 characters. The suite stays under that with
`limits.max_context_chars` (default 8000) per sub-hook and
`limits.max_combined_chars` (default 24000) across the dispatcher's
concatenation. Bodies above `limits.spill_threshold_chars` (default
7000) are written to `<cache>/<hook>/<sha256(file)>.findings.txt` and
referenced inline; aggregate overflow goes to
`<cache>/dispatcher/*.combined.txt`. Set
`COPILOT_QA_SPILL_TO_FILE=false` to fall back to plain truncation,
or tighten the prompt with `code_review.max_findings` / `extra_args`
if the spill files grow noisy.

**SessionStart warning does not show as a banner, but Claude mentions
it**: since Claude Code 2.1.0 `additionalContext` is injected as a
system reminder, not rendered as a UI banner. The check hook also sets
`systemMessage` as best-effort. Depending on your Claude Code version
you see the banner directly or only via Claude's first reply. Both are
intended behavior.

**SessionStart warning is in the way (offline / fallback usage)**:
remove the `SessionStart` block from `hooks.json`, or set
`COPILOT_QA_ENABLED_CHECK_COPILOT=false`. The PostToolUse hooks still
run and exit silently when `copilot` is missing.

## Architecture

> Claude says what changed -> Copilot checks whether/what needs updating
> -> Claude updates per Copilot's findings.

A single PostToolUse **dispatcher** at `hooks/dispatcher/dispatch.sh`
routes incoming Edit/Write/MultiEdit events to the appropriate
sub-hook(s) based on file type:

- **Gradle file** (`build.gradle*`, `settings.gradle*`, `libs.versions.toml`)
  -> proguard hook only
- **Test file** (`*Test.kt`, `*.spec.ts`, `*_test.py`, paths under
  `tests/`, `__tests__/`, etc.) -> doc hook only (adds comments after
  the unittest hook creates the file later)
- **Source file** in a recognized language -> doc + code-review +
  unittest, **sequentially** (not in parallel)
- **Anything else** -> silent exit

Sequential execution preserves per-hook independence (each can
short-circuit on cache hit / rate limit) while eliminating the
four-fold parallel cost from earlier versions. A `SessionEnd` hook
prunes aged cache and Copilot-log entries.

No hook calls Claude. No hook writes to source. Copilot has no write
tools. Claude receives every finding via `additionalContext` and
decides based on the embedded rules — always asking for `y/n`
confirmation on CRITICAL findings. This split is intentionally
conservative: when in doubt, the user wins, not the agent.

### Plugin-private state

State lives under `${CLAUDE_PLUGIN_DATA}` (or
`${XDG_CACHE_HOME}/copilot-qa-suite` / `${TMPDIR}/copilot-qa-$(id -u)`
as fallbacks):

- `${CLAUDE_PLUGIN_DATA}/copilot/` — plugin-private Copilot CLI config
  dir, isolating `trusted_folders` and session logs from the user's
  interactive `~/.copilot/`. Configurable via `copilot.config_dir`.
- `${CLAUDE_PLUGIN_DATA}/cache/{code-review,unittest,proguard}/` —
  file-content hash and rate-limit timestamp shards. Pruned at
  `SessionEnd` per `cleanup.cache_max_age_days`.

## License

MIT.
