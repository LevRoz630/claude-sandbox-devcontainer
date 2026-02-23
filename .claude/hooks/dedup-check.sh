#!/bin/bash
# PreToolUse hook: blocks after 3 identical tool+command invocations.

set -uo pipefail

INPUT=$(cat)
if ! echo "$INPUT" | jq -e . >/dev/null 2>&1; then exit 0; fi

SESSION=$(echo "$INPUT" | jq -r '.session_id // "unknown"')
TOOL=$(echo "$INPUT" | jq -r '.tool_name // "unknown"')
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // .tool_input.file_path // "none"')

STATE_DIR="${CLAUDE_HOOK_STATE_DIR:-/tmp}/claude-hooks-${SESSION}"
mkdir -p "$STATE_DIR"

HASH=$(printf '%s\n%s' "$TOOL" "$COMMAND" | sha256sum | cut -d' ' -f1)
STATE_FILE="${STATE_DIR}/dedup-${HASH}"

COUNT=0
if [[ -f "$STATE_FILE" ]]; then
    COUNT=$(cat "$STATE_FILE" 2>/dev/null || echo 0)
    if ! [[ "$COUNT" =~ ^[0-9]+$ ]]; then COUNT=0; fi
fi

COUNT=$((COUNT + 1))
echo "$COUNT" > "$STATE_FILE"

THRESHOLD=3
if [[ "$COUNT" -ge "$THRESHOLD" ]]; then
    jq -n \
        --arg reason "Blocked: identical command repeated $COUNT times (threshold: $THRESHOLD)" \
        --arg tool "$TOOL" \
        --arg command "$COMMAND" \
        '{decision: "block", reason: $reason, tool: $tool, command: $command}'
fi

exit 0
