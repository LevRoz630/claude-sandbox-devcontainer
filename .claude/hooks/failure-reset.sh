#!/bin/bash
# =============================================================================
# Layer 2: Failure reset — PostToolUse hook
#
# Resets the consecutive failure counter on any successful tool use.
# =============================================================================

set -uo pipefail

INPUT=$(cat)

SESSION=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('session_id','unknown'))")

STATE_DIR="${CLAUDE_HOOK_STATE_DIR:-/tmp}/claude-hooks-${SESSION}"
mkdir -p "$STATE_DIR"

STATE_FILE="${STATE_DIR}/failure-count"

# Reset counter to 0
echo "0" > "$STATE_FILE"

exit 0
