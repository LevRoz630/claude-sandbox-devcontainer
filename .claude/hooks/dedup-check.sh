#!/bin/bash
# =============================================================================
# Layer 1: Command deduplication — PreToolUse hook
#
# Blocks after 3 identical tool+command invocations to prevent loops.
# Reads hook JSON from stdin. Tracks invocations in state files keyed by
# a hash of (tool_name + command).
#
# Exit 0 with no output = allow
# Exit 0 with JSON { "decision": "block", ... } = deny
# =============================================================================

set -uo pipefail

INPUT=$(cat)

SESSION=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('session_id','unknown'))")
TOOL=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tool_name','unknown'))")
COMMAND=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); ti=d.get('tool_input',{}); print(ti.get('command', ti.get('file_path','none')))")

STATE_DIR="${CLAUDE_HOOK_STATE_DIR:-/tmp}/claude-hooks-${SESSION}"
mkdir -p "$STATE_DIR"

# Hash the tool+command pair for the state filename
HASH=$(printf '%s\n%s' "$TOOL" "$COMMAND" | sha256sum | cut -d' ' -f1)
STATE_FILE="${STATE_DIR}/dedup-${HASH}"

# Read current count (default 0)
COUNT=0
if [[ -f "$STATE_FILE" ]]; then
    COUNT=$(cat "$STATE_FILE" 2>/dev/null || echo 0)
    # Guard against corrupt state
    if ! [[ "$COUNT" =~ ^[0-9]+$ ]]; then
        COUNT=0
    fi
fi

COUNT=$((COUNT + 1))
echo "$COUNT" > "$STATE_FILE"

THRESHOLD=3

if [[ "$COUNT" -ge "$THRESHOLD" ]]; then
    python3 -c "
import json, sys
print(json.dumps({
    'decision': 'block',
    'reason': 'Blocked: identical command repeated $COUNT times (threshold: $THRESHOLD)',
    'tool': '''$TOOL''',
    'command': '''$COMMAND'''
}))
"
fi

exit 0
