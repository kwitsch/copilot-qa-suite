#!/usr/bin/env bash
# Microbench: load_config slow path vs fast path.
#
# Runs N iterations of load_config in a fresh subshell each time (so the
# fast path actually re-sources its env-file rather than reusing in-process
# state). Reports total + median per iteration in milliseconds.
#
# Usage:  ./tools/bench-load-config.sh [iterations]   (default 50)

set -euo pipefail

ITER="${1:-50}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DATA="$(mktemp -d)"
trap 'rm -rf "$TMP_DATA"' EXIT

export CLAUDE_PLUGIN_ROOT="$ROOT"
export CLAUDE_PROJECT_DIR="$ROOT"
export CLAUDE_PLUGIN_DATA="$TMP_DATA"

bench_one() {
  local label="$1" prep="$2" pre_compile="$3"
  if [[ "$pre_compile" == "yes" ]]; then
    "$ROOT/hooks/compile-config/compile.sh" >/dev/null
  else
    rm -rf "$TMP_DATA/session"
  fi

  local start end
  start="$(date +%s%N)"
  for ((i=0; i<ITER; i++)); do
    bash -c "$prep"
  done
  end="$(date +%s%N)"

  local total_ms=$(( (end - start) / 1000000 ))
  local per_ms_x100=$(( (end - start) / 10000 / ITER ))
  printf '%-35s  total=%dms  per_iter=%d.%02dms\n' \
    "$label" "$total_ms" "$((per_ms_x100/100))" "$((per_ms_x100%100))"
}

PREP_DOC='source "$CLAUDE_PLUGIN_ROOT/hooks/lib/config.sh"; load_config doc'
PREP_REVIEW='source "$CLAUDE_PLUGIN_ROOT/hooks/lib/config.sh"; load_config code_review'
PREP_ALL='source "$CLAUDE_PLUGIN_ROOT/hooks/lib/config.sh"; load_config doc; load_config code_review; load_config unittest'

echo "Bench: $ITER iterations per scenario"
echo "Plugin data: $TMP_DATA"
echo

bench_one "slow path: load_config doc"           "$PREP_DOC"    "no"
bench_one "fast path: load_config doc"           "$PREP_DOC"    "yes"
echo
bench_one "slow path: load_config code_review"   "$PREP_REVIEW" "no"
bench_one "fast path: load_config code_review"   "$PREP_REVIEW" "yes"
echo
bench_one "slow path: 3 hooks (typical Edit)"    "$PREP_ALL"    "no"
bench_one "fast path: 3 hooks (typical Edit)"    "$PREP_ALL"    "yes"
