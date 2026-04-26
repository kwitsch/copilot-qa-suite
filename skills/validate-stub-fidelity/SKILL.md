---
name: validate-stub-fidelity
description: Validate that the Copilot and Claude binary stubs used in this plugin's bats tests emit output matching the schemas declared in the current prompt files and hook docs. Triggers when the user asks to "check stub fidelity", "validate test stubs", "sync stubs with prompts", "drift-check copilot/claude mocks", or after editing any `hooks/<hook>/copilot-prompt.txt`, `hooks/<hook>/fallback-prompt.txt`, or the `--- FINDING ---` / `--- SYMBOL ---` / `--- TEST_SUGGESTION ---` schema blocks. Also triggers when bats stubs are added or modified. Reports drift and rewrites stubs (test code only) to match — never modifies prompts, hooks, or production scripts.
---

# validate-stub-fidelity

Sole purpose: keep the bats `qa_install_stub copilot ...` / `qa_install_stub claude ...` outputs honest against the live Copilot/Claude output schemas declared in the prompt files. When schemas drift, this skill detects it and rewrites the stub strings — production code stays untouched.

## Scope

**In scope:**
- `tests/bats/**/*.bats` — every line that calls `qa_install_stub copilot|claude` or `qa_install_stub_with_stderr copilot|claude`
- `hooks/<hook>/copilot-prompt.txt` — declares Copilot's output schema per hook
- `hooks/<hook>/fallback-prompt.txt` — declares Claude fallback's output schema per hook
- `hooks/CLAUDE.md` — finding-text format reference (`--- FINDING ---` / severity / action / target_file / line_range)
- `hooks/lib/CLAUDE.md` — additionalContext sizing + `spill_or_inline` semantics
- `hooks/<hook>/CLAUDE.md` if present (per-language doc invariants etc.)

**Out of scope — do not touch:**
- Anything under `hooks/` (production scripts and prompts)
- `config/defaults.json`
- `.claude-plugin/plugin.json`
- `tools/` (excluded from test scope)
- The bats `helpers/common.bash` plumbing — only the stub *string arguments* in `@test` bodies

If a fix would require changing a prompt or a hook, STOP and report the drift to the user. The user, not this skill, decides whether the spec or the test is wrong.

## Schemas to enforce

Each hook has a fixed output schema in its `copilot-prompt.txt`. These are the canonical shapes the parser in the sub-hooks expects:

| Hook         | Block opener            | Required keys                                                  | Empty signal  |
|--------------|-------------------------|----------------------------------------------------------------|---------------|
| `code-review`| `--- FINDING ---`       | `line_range`, `severity`, `auto_fix`, `title`, `description`, `suggestion` | `NO_FINDINGS` |
| `doc`        | `--- SYMBOL ---`        | `line_range`, `action`, `title`, `description`, `suggestion`   | `NO_FINDINGS` |
| `unittest`   | `--- TEST_SUGGESTION ---` | `severity`, `auto_fix`, `title`, `description`, `suggestion` | `NO_FINDINGS` |
| `proguard`   | `--- FINDING ---`       | `target_file`, `action`, `line_range`, `severity`, `title`, `description`, `suggestion` | `NO_FINDINGS` |

Every block ends with `--- END ---`. Severity ∈ {`CRITICAL`, `WARNING`, `INFO`}. Auto-fix ∈ {`YES`, `NO`}. Action depends on hook (see prompt files for the exact union).

The `fallback-prompt.txt` template MUST emit the same schema — re-verify by reading both files for the same hook before fixing a stub.

`NO_FINDINGS` is the documented "nothing to report" sentinel. A stub that returns the empty string is also valid (sub-hook contract item 8: empty Copilot output is treated as a no-op).

## Procedure

1. **Enumerate stubs.**
   ```bash
   grep -nE 'qa_install_stub(_with_stderr)?[[:space:]]+(copilot|claude)' \
     tests/bats -r
   ```
   Each hit names the test file, line, target binary, and the stdout argument.

2. **Classify each stub by intent.** A stub falls into one of three buckets:
   - **Sentinel**: empty output, `NO_FINDINGS`, or text that no parser would inspect (`"should not be called"`, `"claude must not be called"`). These are fine — keep as-is.
   - **Schema-bearing**: output that names a finding/symbol/test-suggestion. The string contains `FINDING`, `SYMBOL`, `TEST_SUGGESTION`, `severity`, `action`, `auto_fix`, `target_file`, or `line_range`. These MUST match the schema for the hook the test exercises.
   - **Free-form**: output that the test itself asserts on (e.g., `"FINDING: looks fine"` checked via `[ "$out" = "..." ]`). If the assertion treats the string as opaque, the stub is fine. If the assertion parses the string, fall through to schema-bearing rules.

3. **For each schema-bearing stub:**
   - Read the matching `hooks/<hook>/copilot-prompt.txt` (and the fallback template if the stub is for `claude`).
   - Confirm the stub's opener matches the table above for that hook.
   - Confirm every required key is present, with the documented value union.
   - Confirm the closer `--- END ---` is present.
   - If a sub-hook downstream of the stub will pipe the output through `spill_or_inline`, the stub need not satisfy size constraints — that path is exercised by `lib/config.bats`, not by integration stubs.

4. **Report findings before rewriting.** Print one line per drift, in this shape:
   ```
   tests/bats/<file>:<line>  <hook>  <severity>  <one-line summary>
   ```
   Then ask the user to confirm before editing any test file.

5. **Rewrite the stub string** when the user approves. Use the minimal valid block that satisfies the schema for the test's intent. Example template for `code-review`:
   ```
   --- FINDING ---
   line_range: 1-1
   severity: INFO
   auto_fix: NO
   title: stub finding
   description: synthetic block emitted by a bats stub
   suggestion: none
   --- END ---
   ```
   Keep the test's *assertion* in sync — if the test currently does `[ "$out" = "FINDING: looks fine" ]` and the new stub returns a multi-line block, switch the assertion to a `grep`/`jq`/substring check that captures the test's actual intent.

6. **Re-run bats.** After every batch of edits:
   ```bash
   bats -r tests/bats
   ```
   If any test fails, undo the edit and re-report — drift may indicate the prompt itself is stale, which is out of scope to fix.

7. **Update `tests/README.md` only if the validation procedure changes.** Do not log routine fix runs there.

## Constraints

- Never change `hooks/` files. Drift between prompt and stub is fixed on the test side; if the prompt is wrong, only the user can authorize that.
- Never change `helpers/common.bash` to relax assertions. If the stub now emits a multi-line block, fix the *test's* assertion, not the helper.
- Never silence a contract test (`tests/bats/contract/*.bats`) to make a fix go through.
- Always run `bats -r tests/bats` after a fix and report the count to the user.
- Do not re-classify stubs across runs without the user's approval — sentinel ↔ schema-bearing reclassification is an intent change, not a drift fix.

## When the prompt itself looks wrong

If the schema in `copilot-prompt.txt` and the parser in the sub-hook script disagree, the right fix is on the production side, not in tests. Stop, surface the discrepancy to the user with file:line on both sides, and do not edit anything.
