#!/bin/bash
# =============================================================================
# Failure reset — PostToolUse hook
#
# Resets the consecutive failure counter on any successful tool use.
# =============================================================================

set -uo pipefail

INPUT=$(cat)

# Validate JSON input — fail open on malformed data
if ! echo "$INPUT" | jq -e . >/dev/null 2>&1; then
    exit 0
fi

SESSION=$(echo "$INPUT" | jq -r '.session_id // "unknown"')

STATE_DIR="${CLAUDE_HOOK_STATE_DIR:-/tmp}/claude-hooks-${SESSION}"
mkdir -p "$STATE_DIR"

STATE_FILE="${STATE_DIR}/failure-count"

# Reset counter to 0
echo "0" > "$STATE_FILE"

exit 0
