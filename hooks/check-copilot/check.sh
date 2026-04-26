#!/usr/bin/env bash
# SessionStart hook: verify Copilot CLI is ready to use.
# - Binary on PATH?
# - Authenticated (env var OR ~/.copilot/{settings,config}.json)?
# - Current directory in trusted_folders?
#   - When check_copilot.auto_trust_folder=true: add it automatically
#     (atomic temp+mv) instead of warning.
#
# On problems: additionalContext with instructions for Claude to show
# the warning in the very first reply, plus systemMessage for direct
# UI banner where supported.
# On automatic actions without problems: short info note instead of warning.
#
# Always exit 0 - session start must not be blocked.
set -euo pipefail

# ---------- Load config ----------
# Not strictly required for SessionStart, but consistent with other hooks.
# Lets the user disable check_copilot entirely.
source "${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}/hooks/lib/config.sh"
load_config "check_copilot"
require_enabled

# ---------- 1. Parse hook input ----------
INPUT="$(cat 2>/dev/null || true)"
if command -v jq >/dev/null 2>&1 && [[ -n "$INPUT" ]]; then
  CWD="$(jq -r '.cwd // empty' <<<"$INPUT" 2>/dev/null || true)"
else
  CWD=""
fi
[[ -z "$CWD" ]] && CWD="$(pwd)"

# With b21, the plugin uses its own config dir for Copilot calls. Trust
# state must be checked AND maintained there, not in the user's ~/.copilot/.
# Auth detection still consults the user's ~/.copilot/ because Copilot CLI
# may share OAuth state across config dirs (the user only logs in once).
USER_COPILOT_HOME="${COPILOT_HOME:-$HOME/.copilot}"
PLUGIN_COPILOT_HOME="$CFG_CONFIG_DIR"
mkdir -p "$PLUGIN_COPILOT_HOME" 2>/dev/null || true

# Auth-detection file paths (user-side; auth is shared)
USER_AUTH_FILES=(
  "$USER_COPILOT_HOME/settings.json"
  "$USER_COPILOT_HOME/config.json"
)

# Trust state lives in the plugin-private config dir
if [[ -f "$PLUGIN_COPILOT_HOME/settings.json" ]]; then
  CONFIG_FILE="$PLUGIN_COPILOT_HOME/settings.json"
elif [[ -f "$PLUGIN_COPILOT_HOME/config.json" ]]; then
  CONFIG_FILE="$PLUGIN_COPILOT_HOME/config.json"
else
  CONFIG_FILE="$PLUGIN_COPILOT_HOME/settings.json"
fi

# Auto-trust flag from config (default false)
AUTO_TRUST="$(_cfg_layered_get '.check_copilot.auto_trust_folder' 2>/dev/null || true)"
AUTO_TRUST="${AUTO_TRUST:-false}"

# Atomic trust-add: reads config.json (or creates it), appends folder to
# trusted_folders, writes via temp+mv, returns 0 on success.
add_to_trusted_folders() {
  local cfg="$1" folder="$2" tmp
  command -v jq >/dev/null 2>&1 || return 1
  mkdir -p "$(dirname "$cfg")"
  tmp="$(mktemp "${cfg}.XXXXXX")" || return 1

  if [[ -f "$cfg" ]]; then
    # Existing file: add folder to the list if not present already.
    # try/catch handles missing trusted_folders -> created fresh.
    jq --arg f "$folder" '
      .trusted_folders = (
        ((.trusted_folders // []) + [$f]) | unique
      )
    ' "$cfg" >"$tmp" || { rm -f "$tmp"; return 1; }
  else
    # Create fresh with minimal structure
    jq -n --arg f "$folder" '{ "trusted_folders": [$f] }' >"$tmp" || {
      rm -f "$tmp"; return 1;
    }
  fi

  # Match permissions before moving (chmod). Reuse original perms if
  # present, otherwise default to 600 (token-adjacent file)
  if [[ -f "$cfg" ]]; then
    chmod --reference="$cfg" "$tmp" 2>/dev/null || chmod 600 "$tmp" 2>/dev/null || true
  else
    chmod 600 "$tmp" 2>/dev/null || true
  fi

  mv "$tmp" "$cfg"
}

ISSUES=()
ACTIONS=()  # things we performed automatically (visible to user)

# ---------- 2. System dependencies (used by the PostToolUse hooks) ----------
MISSING_DEPS=()
command -v jq >/dev/null 2>&1 || MISSING_DEPS+=("jq")
command -v timeout >/dev/null 2>&1 || MISSING_DEPS+=("timeout (GNU coreutils)")
if (( ${#MISSING_DEPS[@]} > 0 )); then
  DEPS_LIST=$(IFS=', '; echo "${MISSING_DEPS[*]}")
  ISSUES+=("Missing system tools: ${DEPS_LIST}. Install on Linux: \`apt install jq coreutils\`. macOS: \`brew install jq coreutils\`.")
fi

# ---------- 3. Copilot binary available? ----------
if ! command -v copilot >/dev/null 2>&1; then
  ISSUES+=("copilot CLI is not on PATH. Install: \`npm install -g @github/copilot\` (Node 22+)")
else
  # ---------- 4. Authentication present? ----------
  # Auth is shared across config dirs — only need to find evidence in any
  # known user-side location.
  AUTH_OK=0
  if [[ -n "${COPILOT_GITHUB_TOKEN:-}" ]] \
     || [[ -n "${GH_TOKEN:-}" ]] \
     || [[ -n "${GITHUB_TOKEN:-}" ]]; then
    AUTH_OK=1
  else
    for auth_f in "${USER_AUTH_FILES[@]}"; do
      if [[ -f "$auth_f" ]]; then
        AUTH_OK=1
        break
      fi
    done
  fi
  if (( AUTH_OK == 0 )); then
    ISSUES+=("Copilot CLI is not authenticated. Either set \`export COPILOT_GITHUB_TOKEN=ghp_...\` (fine-grained PAT with the 'Copilot Requests' scope), or run \`copilot\` interactively once and complete \`/login\`.")
  fi

  # ---------- 5. Is current directory trusted? ----------
  # On first run per project, optionally inherit matching trusted_folders
  # from the user's ~/.copilot/{settings,config}.json into the plugin's
  # private config dir — but only with explicit consent, recorded once in
  # $PLUGIN_COPILOT_HOME/inherit_consent.marker. Without this, switching
  # to --config-dir leaves the plugin with an empty trust list (audit
  # b21 substance gap).
  INHERIT_CONSENT_FILE="$PLUGIN_COPILOT_HOME/inherit_consent.marker"
  INHERIT_USER_TRUST="$(_cfg_layered_get '.check_copilot.inherit_user_trust' 2>/dev/null || true)"
  if command -v jq >/dev/null 2>&1 \
     && [[ "${INHERIT_USER_TRUST,,}" == "true" ]] \
     && [[ ! -f "$INHERIT_CONSENT_FILE" ]] \
     && [[ ! -f "$CONFIG_FILE" ]]; then
    USER_CFG=""
    for cand in "$USER_COPILOT_HOME/settings.json" "$USER_COPILOT_HOME/config.json"; do
      [[ -f "$cand" ]] && { USER_CFG="$cand"; break; }
    done
    if [[ -n "$USER_CFG" ]]; then
      if jq --arg p "$CWD" '
            .trusted_folders = [
              (.trusted_folders // [])[]
              | select(. as $f | $p | startswith($f))
            ]
          ' "$USER_CFG" > "$CONFIG_FILE.tmp" 2>/dev/null; then
        chmod 600 "$CONFIG_FILE.tmp" 2>/dev/null || true
        mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
        date +%s > "$INHERIT_CONSENT_FILE"
        chmod 600 "$INHERIT_CONSENT_FILE" 2>/dev/null || true
        ACTIONS+=("Inherited matching \`trusted_folders\` from \`$USER_CFG\` into plugin-private \`$CONFIG_FILE\` (one-time, consent via check_copilot.inherit_user_trust=true).")
      else
        rm -f "$CONFIG_FILE.tmp"
      fi
    fi
  fi

  # With jq: check whether $CWD (or an ancestor) is in trusted_folders.
  # When auto_trust_folder=true and the entry is missing: add it.
  # Otherwise: emit a warning with the manual-fix instructions.
  if command -v jq >/dev/null 2>&1; then
    TRUSTED_OK=0
    if [[ -f "$CONFIG_FILE" ]]; then
      while IFS= read -r folder; do
        [[ -z "$folder" ]] && continue
        folder="${folder%/}"
        case "$CWD" in
          "$folder"|"$folder"/*) TRUSTED_OK=1; break ;;
        esac
      done < <(jq -r '.trusted_folders[]? // empty' "$CONFIG_FILE" 2>/dev/null || true)
    fi

    if (( TRUSTED_OK == 0 )); then
      if [[ "${AUTO_TRUST,,}" == "true" ]]; then
        if add_to_trusted_folders "$CONFIG_FILE" "$CWD"; then
          ACTIONS+=("Added working directory \`$CWD\` to \`$CONFIG_FILE\` -> \`trusted_folders\` automatically (auto_trust_folder=true).")
        else
          ISSUES+=("Auto-trust for \`$CWD\` failed (write permission on \`$CONFIG_FILE\`?). Manual workaround: \`cd $CWD && copilot\`, confirm trust dialog with \"Yes, and remember this folder\".")
        fi
      else
        ISSUES+=("Working directory \`$CWD\` is not listed in \`$CONFIG_FILE\` under \`trusted_folders\`. Copilot calls from the PostToolUse hooks will fail. Options: (1) run \`cd $CWD && copilot\` once and confirm the trust dialog with \"Yes, and remember this folder\", or (2) set \`check_copilot.auto_trust_folder: true\` in your plugin config so the hook adds the folder automatically.")
      fi
    fi
  fi
fi

# ---------- 6. All clean -> exit silently (or short info note on auto-trust) ----------
if (( ${#ISSUES[@]} == 0 )); then
  if (( ${#ACTIONS[@]} == 0 )); then
    # Truly all clean
    printf '{}\n'
    exit 0
  fi
  # No issues, but we did something automatically (e.g. trust set).
  # User should know without seeing a warning.
  ACTIONS_BLOCK=""
  for a in "${ACTIONS[@]}"; do
    ACTIONS_BLOCK+="- $a"$'\n'
  done

  CTX="copilot-qa-suite - automatic setup actions
==============================================
At session start the following actions ran automatically:

${ACTIONS_BLOCK}
This is informational only, not a warning."

  if command -v jq >/dev/null 2>&1; then
    jq -n \
      --arg ctx "$CTX" \
      --arg msg "ℹ️ copilot-qa-suite: ${#ACTIONS[@]} automatic setup action(s) executed." \
      '{
        hookSpecificOutput: {
          hookEventName: "SessionStart",
          additionalContext: $ctx
        },
        systemMessage: $msg
      }'
  else
    printf '{}\n'
  fi
  exit 0
fi

# ---------- 7. Build warning ----------
WARN_SHORT="⚠️ copilot-qa-suite: ${#ISSUES[@]} setup problem(s) detected. The automatic hooks will not work until this is resolved."

ISSUES_BLOCK=""
for i in "${!ISSUES[@]}"; do
  ISSUES_BLOCK+="$((i+1)). ${ISSUES[$i]}"$'\n\n'
done

CLAUDE_CONTEXT="SETUP WARNING FROM copilot-qa-suite
===================================
At session start the GitHub Copilot CLI was found not to be ready. The
PostToolUse hooks (doc, code review, unittest, proguard) will exit 0
silently while these problems remain - meaning there will be NO
automatic quality checks.

Detected problems:

${ISSUES_BLOCK}
INSTRUCTIONS FOR YOU (Claude)
=============================
Show this warning to the user in your VERY FIRST reply, before working
on anything else. Format it as a concise list with the concrete fix
steps. Then carry on normally. Once per session is enough - do not
repeat in subsequent replies."

if command -v jq >/dev/null 2>&1; then
  jq -n \
    --arg warn "$WARN_SHORT" \
    --arg ctx "$CLAUDE_CONTEXT" \
    '{
      hookSpecificOutput: {
        hookEventName: "SessionStart",
        additionalContext: $ctx
      },
      systemMessage: $warn
    }'
else
  esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g' | awk 'BEGIN{ORS="\\n"}{print}' | sed 's/\\n$//'; }
  printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"},"systemMessage":"%s"}\n' \
    "$(esc "$CLAUDE_CONTEXT")" \
    "$(esc "$WARN_SHORT")"
fi

exit 0
