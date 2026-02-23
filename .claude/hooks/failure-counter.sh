#!/bin/bash
# =============================================================================
# Failure counter — PostToolUseFailure hook
#
# Tracks consecutive tool failures. After 5+ consecutive failures, outputs a
# warning via additionalContext to nudge Claude to change approach.
#
# Exit 0 with no output = no action
# Exit 0 with JSON { "additionalContext": ... } = inject warning
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

# Read current count (default 0)
COUNT=0
if [[ -f "$STATE_FILE" ]]; then
    COUNT=$(cat "$STATE_FILE" 2>/dev/null || echo 0)
    if ! [[ "$COUNT" =~ ^[0-9]+$ ]]; then
        COUNT=0
    fi
fi

COUNT=$((COUNT + 1))
echo "$COUNT" > "$STATE_FILE"

THRESHOLD=5

if [[ "$COUNT" -ge "$THRESHOLD" ]]; then
    jq -n --arg msg "WARNING: $COUNT consecutive tool failures. Consider a different approach -- the current strategy is not working." \
        '{additionalContext: $msg}'
fi

exit 0
