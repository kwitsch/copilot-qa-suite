# CLAUDE.md — hooks/doc/

Doc-comment hook. Per-language template appended to
`copilot-prompt.txt` based on file extension. Templates encode
format-specific rules Copilot tends to violate without explicit
guardrails.

## Extension -> template mapping (analyze-doc.sh)

| Extension                        | Source     | Template                   |
|----------------------------------|------------|----------------------------|
| `.kt`, `.kts`                    | Kotlin     | `templates/kotlin.txt`     |
| `.java`                          | Java       | `templates/java.txt`       |
| `.ts`, `.tsx`                    | TypeScript | `templates/typescript.txt` |
| `.js`, `.jsx`, `.mjs`, `.cjs`    | JavaScript | `templates/javascript.txt` |
| `.go`                            | Go         | `templates/go.txt`         |
| `.rs`                            | Rust       | `templates/rust.txt`       |

Adding a language: extend the case block in `analyze-doc.sh`, add a
template, and add the extension to `languages.code_review_extensions`
+ `languages.unittest_extensions` if those hooks should also fire on
it.

## Format invariants (do not weaken)

Easy-to-miss rules each template enforces. Make them explicit when
editing — Copilot regresses fast otherwise.

- **TSDoc** (`typescript.txt`): NO `{type}` annotations in `@param` /
  `@returns`. Types come from the TS signature. Hyphen separator:
  `@param name - description`.
- **godoc** (`go.txt`): first sentence MUST start with the symbol
  name (`CalculateTotal returns ...`). NO blank line between comment
  and declaration. NO Markdown — backticks render literally.
  `Deprecated:` in own paragraph after a blank `//` line.
- **rustdoc** (`rust.txt`): `# Errors` / `# Panics` / `# Safety` /
  `# Examples` sections, in that order. `# Safety` REQUIRED for
  `unsafe fn`. Code blocks are doctests by default — mark `ignore`,
  `no_run`, or `text` to opt out. `///` for items, `//!` for
  containers.
- **JSDoc** (`javascript.txt`): types in `{Type}` ARE allowed (unlike
  TSDoc) — JS has no signature to fall back on.
- **KDoc / Javadoc**: Markdown allowed in KDoc, NOT in classic
  Javadoc. `@sample` (KDoc) and `@see` are preserved on UPDATE.

## Comment language vs. doc format

`doc.comment_language` (default `English`) controls only prose. Format
syntax stays native (KDoc, Javadoc, JSDoc, TSDoc, godoc, rustdoc).
Identifiers, types, and code samples ALWAYS in source language
regardless of comment language. Translation is a prompt-level concern
— do not push it into templates.

## Output actions

Each finding carries an `action`:

- `NEW`: insert new doc block above the symbol.
- `UPDATE`: replace existing doc block, preserving manually added
  tags (`@see`, `@sample` for KDoc/Java/TS; `# Examples` blocks for
  Rust).

Claude must NOT delete user-authored example blocks or `@see`
references during `UPDATE`. The Copilot prompt enforces this — keep
that instruction intact when editing `copilot-prompt.txt`.

## Test-file routing

Dispatcher routes test files to this hook ONLY (no code-review, no
unittest — would recurse). Doc hook treats them like any other source.
The unittest hook emits new tests without comments by design; this
hook adds them on the follow-up PostToolUse for the new test file.
