#!/usr/bin/env bash
set -euo pipefail

# Bash >= 4 required: empty-array expansion under `set -u` and other 4.x
# behaviors break on macOS stock bash 3.2. Skip (not fail) so local runs
# explain themselves; CI runs bash 5.
if [ -z "${BASH_VERSINFO:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  echo "SKIP: bash >= 4 required (found ${BASH_VERSION:-unknown}); on macOS run with PATH=\"/opt/homebrew/bin:\$PATH\"" >&2
  exit 0
fi

# Fallback-tier configuration validation.
#
# The fallback endpoint/format/key inherit from the primary when blank (action.yml),
# so AI_FALLBACK_BASE_URL is non-empty for every caller of the composite action,
# including one that configures no fallback at all. The validation must therefore key
# on AI_FALLBACK_MODEL, not on the base URL alone, or it rejects every single-provider
# configuration before any model call.
#
# The four cases below only mean something together: relaxing the check far enough to
# admit an inherited URL must not also admit an endpoint that was configured deliberately
# and whose model was forgotten.
#
# Each case asserts the exit status AND which check produced it. Status alone is not
# enough: config.sh has earlier guards (missing REPO/PR_NUMBER/AI_BASE_URL/AI_MODEL,
# missing GH_TOKEN) that also exit 1, so a fixture that failed to set one of those
# would let the negative cases pass without ever reaching the check under test.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0
# shellcheck source=_lib/assert.sh
source "$SCRIPT_DIR/_lib/assert.sh"

PRIMARY_URL="https://primary.example.com/v1"
OTHER_URL="https://fallback.example.com/v1"

# Run config.sh in a subshell under a complete minimal environment, with the fallback
# values action.yml's review-step env block would produce. Echoes "<status>|<tag>",
# where the tag names the validation that spoke, so a case cannot pass because some
# other guard fired first.
config_result() {
  local fallback_base_url="$1" fallback_model="$2"
  local status errfile stderr tag

  errfile="$(mktemp)"

  # `env -i` plus an explicit allowlist, so no ambient configuration reaches config.sh --
  # it reads a wide surface (SYSTEM_PROMPT_FILE, STANDARDS_FILE, every AI_*, the token), and
  # a value inherited from a developer's environment can change the result of a case for a
  # reason unrelated to the check under test. PATH and HOME are forwarded deliberately, so
  # the sourced scripts can find the commands they call.
  if env -i \
      PATH="$PATH" \
      HOME="${HOME:-/tmp}" \
      REPO="owner/repo" \
      PR_NUMBER="1" \
      GH_TOKEN="dummy-token" \
      AI_BASE_URL="$PRIMARY_URL" \
      AI_API_FORMAT="openai" \
      AI_MODEL="primary-model" \
      AI_API_KEY="sk-primary" \
      AI_FALLBACK_BASE_URL="$fallback_base_url" \
      AI_FALLBACK_MODEL="$fallback_model" \
      ROOT_DIR="$ROOT_DIR" \
      bash -c '
        set -euo pipefail
        # config.sh resolves the bundled system prompt relative to SCRIPT_DIR.
        export SCRIPT_DIR="$ROOT_DIR/scripts"
        source "$ROOT_DIR/scripts/sections/common.sh"
        source "$ROOT_DIR/scripts/sections/config.sh"
      ' >/dev/null 2>"$errfile"; then
    status=0
  else
    status=$?
  fi

  stderr="$(cat "$errfile")"
  rm -f "$errfile"

  # Name which validation spoke, so a case cannot pass because an earlier guard fired.
  case "$stderr" in
    *"AI_FALLBACK_MODEL is required"*)    tag="needs-model" ;;
    *"AI_FALLBACK_BASE_URL is required"*) tag="needs-url" ;;
    *ERROR*)                              tag="other-guard" ;;
    *)                                    tag="accepted" ;;
  esac
  printf '%s|%s\n' "$status" "$tag"
}

echo "=== Test: no fallback configured, base URL inherited from primary ==="
# What every single-provider caller gets: action.yml fills the fallback base URL from
# ai_base_url, and there is no way to blank it (GitHub expressions treat "" as falsy).
check "inherited base URL with no fallback model is accepted" \
  "$(config_result "$PRIMARY_URL" "")" "0|accepted"

echo ""
echo "=== Test: fallback fully configured ==="
check "explicit fallback endpoint and model is accepted" \
  "$(config_result "$OTHER_URL" "fallback-model")" "0|accepted"

echo ""
echo "=== Test: explicit fallback endpoint with no model is still rejected ==="
# The case the check exists for, and the one a blanket relaxation would lose: a
# distinct endpoint was configured deliberately, so the missing model is a mistake.
check "explicit distinct fallback endpoint without a model is rejected" \
  "$(config_result "$OTHER_URL" "")" "1|needs-model"

echo ""
echo "=== Test: fallback model with no endpoint is still rejected ==="
# The mirror-image check. Unreachable through action.yml (the URL always inherits),
# live for anything driving scripts/run_review.sh directly.
check "fallback model without an endpoint is rejected" \
  "$(config_result "" "fallback-model")" "1|needs-url"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
