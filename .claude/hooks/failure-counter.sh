#!/bin/bash
# =============================================================================
# Layer 2: Failure counter — PostToolUseFailure hook
#
# Tracks consecutive tool failures. After 5+ consecutive failures, outputs a
# warning via additionalContext to nudge Claude to change approach.
#
# Exit 0 with no output = no action
# Exit 0 with JSON { "additionalContext": ... } = inject warning
# =============================================================================

set -uo pipefail

INPUT=$(cat)

SESSION=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('session_id','unknown'))")

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
    python3 -c "
import json
print(json.dumps({
    'additionalContext': 'WARNING: $COUNT consecutive tool failures. Consider a different approach -- the current strategy is not working.'
}))
"
fi

exit 0
