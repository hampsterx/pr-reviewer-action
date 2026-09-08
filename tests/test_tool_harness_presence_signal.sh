#!/usr/bin/env bash
set -euo pipefail

# The Tool Harness Findings section is conditional on the harness producing
# output, and tool-harness.md is the signal for it on both sides: corpus.sh
# gates the corpus header on it, and the publish step gates the deterministic
# stripper on the same file.
#
# The distinction that matters is between "no harness output" (tool_mode=off,
# empty file, no section) and "the harness had something to say": the
# native_loop planning placeholder, the fork skip, and the failure stub all
# carry text and must keep their section. Gating on the file rather than on
# TOOL_MODE is what keeps those three working.

if [ -z "${BASH_VERSINFO:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  echo "SKIP: bash >= 4 required (found ${BASH_VERSION:-unknown})" >&2
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PASS=0; FAIL=0
# shellcheck source=_lib/assert.sh
source "$ROOT_DIR/tests/_lib/assert.sh"

# Lift the default-harness block out of corpus.sh and run it in isolation, the
# same idiom test_standards_presence_signal.sh uses. A refactor that moves the
# block fails this extraction loudly rather than passing vacuously.
BLOCK="$(mktemp)"; trap 'rm -f "$BLOCK"' EXIT
python3 - "$SCRIPT_DIR/sections/corpus.sh" "$BLOCK" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
m = re.search(
    r"^(case \"\$\(printf '%s' \"\$TOOL_MODE\".*?tool-harness\.md.*?^esac)$",
    src, re.S | re.M,
)
if not m:
    sys.exit("could not extract the tool-harness default block from corpus.sh")
open(sys.argv[2], "w").write("default_tool_harness() {\n%s\n}\n" % m.group(1))
PY
# shellcheck source=/dev/null
source "$BLOCK"

WORK="$(mktemp -d)"; trap 'rm -f "$BLOCK"; rm -rf "$WORK"' EXIT

echo "=== tool_mode=off produces no harness output ==="
OUT="$( cd "$WORK"
  rm -f tool-harness.md
  TOOL_MODE="off"
  default_tool_harness
  printf 'size=%s' "$(wc -c < tool-harness.md | tr -d ' ')" )"
check_contains "off leaves the file empty" "$OUT" "size=0"

echo "=== native_loop keeps its planning placeholder (#101/#108) ==="
OUT="$( cd "$WORK"
  rm -f tool-harness.md
  TOOL_MODE="native_loop"
  default_tool_harness
  printf 'body=[%s]' "$(cat tool-harness.md)" )"
check_contains "planning placeholder survives" "$OUT" "body=[Tool harness planning pending.]"

echo "=== an unrecognised mode is treated as off, not as output ==="
# corpus.sh only enables the harness for the literal native_loop, so any other
# value must land on the empty branch rather than inventing a section.
OUT="$( cd "$WORK"
  rm -f tool-harness.md
  TOOL_MODE="plan_execute_once"
  default_tool_harness
  printf 'size=%s' "$(wc -c < tool-harness.md | tr -d ' ')" )"
check_contains "unknown mode leaves the file empty" "$OUT" "size=0"

echo "=== a reused workspace's empty file still gets the planning placeholder ==="
# off-mode now leaves an empty file behind, so a later native_loop run in the
# same workspace would find the file present but empty. Testing -f rather than
# -s here would leave the planner with no section and the verdict turn with
# nothing to substitute into.
OUT="$( cd "$WORK"
  : > tool-harness.md
  TOOL_MODE="native_loop"
  default_tool_harness
  printf 'body=[%s]' "$(cat tool-harness.md)" )"
check_contains "empty file is re-initialised for native_loop" \
  "$OUT" "body=[Tool harness planning pending.]"

echo "=== a stale file from a previous run cannot pose as this review ==="
OUT="$( cd "$WORK"
  printf 'Tool harness results from an earlier run\n' > tool-harness.md
  TOOL_MODE="off"
  default_tool_harness
  printf 'size=%s' "$(wc -c < tool-harness.md | tr -d ' ')" )"
check_contains "off truncates a stale harness file" "$OUT" "size=0"

echo "=== an existing file is never overwritten by the default ==="
# The harness itself writes tool-harness.md; the default only fills a gap.
OUT="$( cd "$WORK"
  printf 'real harness output\n' > tool-harness.md
  TOOL_MODE="native_loop"
  default_tool_harness
  printf 'body=[%s]' "$(cat tool-harness.md)" )"
check_contains "real output is preserved" "$OUT" "body=[real harness output]"

echo "=== the corpus gates the header on the file, not on TOOL_MODE ==="
check_contains "corpus.sh gates the Tool Harness header" \
  "$(<"$SCRIPT_DIR/sections/corpus.sh")" 'if [ -s tool-harness.md ]; then'

echo "=== publish_helpers reads the signal it is given ==="
check_contains "publish gates on the harness file" \
  "$(<"$SCRIPT_DIR/publish_helpers.sh")" "if [ -s tool-harness.md ]"
check_contains "publish exports TOOL_HARNESS_PRESENT to the stripper" \
  "$(<"$SCRIPT_DIR/publish_helpers.sh")" 'TOOL_HARNESS_PRESENT="$tool_harness_present"'
check_contains "the stripper knows the findings heading" \
  "$(<"$SCRIPT_DIR/strip_empty_conditional_sections.py")" '"tool_harness_findings": "tool harness findings"'
check_contains "the stripper knows the results heading" \
  "$(<"$SCRIPT_DIR/strip_empty_conditional_sections.py")" '"tool_harness_results": "tool harness results"'
check_contains "the harness file is symlink-guarded like every other artifact" \
  "$(<"$SCRIPT_DIR/artifact_paths.sh")" "tool-harness.md"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
