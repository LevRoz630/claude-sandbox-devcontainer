#!/bin/bash
# PostToolUseFailure hook: warns after 5+ consecutive failures.

set -uo pipefail

INPUT=$(cat)
if ! echo "$INPUT" | jq -e . >/dev/null 2>&1; then exit 0; fi

SESSION=$(echo "$INPUT" | jq -r '.session_id // "unknown"')

STATE_DIR="${CLAUDE_HOOK_STATE_DIR:-/tmp}/claude-hooks-${SESSION}"
mkdir -p -m 700 "$STATE_DIR"
STATE_FILE="${STATE_DIR}/failure-count"

COUNT=0
if [[ -f "$STATE_FILE" ]]; then
    COUNT=$(cat "$STATE_FILE" 2>/dev/null || echo 0)
    if ! [[ "$COUNT" =~ ^[0-9]+$ ]]; then COUNT=0; fi
fi

COUNT=$((COUNT + 1))
echo "$COUNT" > "$STATE_FILE"

THRESHOLD=5
if [[ "$COUNT" -ge "$THRESHOLD" ]]; then
    jq -n --arg msg "WARNING: $COUNT consecutive tool failures. Consider a different approach -- the current strategy is not working." \
        '{additionalContext: $msg}'
fi

exit 0
