#!/bin/bash
# PreToolUse hook: blocks after repeated identical tool+command invocations.
# Read-only tools (Read, Glob, Grep) are excluded — re-reading files is normal.
# A different tool call resets all dedup counters (prevents getting stuck).

set -uo pipefail

INPUT=$(cat)
if ! echo "$INPUT" | jq -e . >/dev/null 2>&1; then exit 0; fi

SESSION=$(echo "$INPUT" | jq -r '.session_id // "unknown"')
TOOL=$(echo "$INPUT" | jq -r '.tool_name // "unknown"')
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // .tool_input.file_path // "none"')

# Skip read-only tools — re-reading files after edits is normal workflow
case "$TOOL" in
    Read|Glob|Grep|WebFetch|WebSearch) exit 0 ;;
esac

STATE_DIR="${CLAUDE_HOOK_STATE_DIR:-/tmp}/claude-hooks-${SESSION}"
mkdir -p -m 700 "$STATE_DIR"

HASH=$(printf '%s\n%s' "$TOOL" "$COMMAND" | sha256sum | cut -d' ' -f1)
STATE_FILE="${STATE_DIR}/dedup-${HASH}"
LAST_HASH_FILE="${STATE_DIR}/dedup-last-hash"

# Reset all dedup counters when a different tool+command is used
LAST_HASH=""
if [[ -f "$LAST_HASH_FILE" ]]; then
    LAST_HASH=$(cat "$LAST_HASH_FILE" 2>/dev/null || echo "")
fi
if [[ "$HASH" != "$LAST_HASH" ]]; then
    rm -f "${STATE_DIR}"/dedup-[0-9a-f]* 2>/dev/null
fi
echo "$HASH" > "$LAST_HASH_FILE"

COUNT=0
if [[ -f "$STATE_FILE" ]]; then
    COUNT=$(cat "$STATE_FILE" 2>/dev/null || echo 0)
    if ! [[ "$COUNT" =~ ^[0-9]+$ ]]; then COUNT=0; fi
fi

COUNT=$((COUNT + 1))
echo "$COUNT" > "$STATE_FILE"

THRESHOLD=5
if [[ "$COUNT" -ge "$THRESHOLD" ]]; then
    jq -n \
        --arg reason "Blocked: identical command repeated $COUNT times (threshold: $THRESHOLD). Try a different approach." \
        --arg tool "$TOOL" \
        --arg command "$COMMAND" \
        '{decision: "block", reason: $reason, tool: $tool, command: $command}'
fi

exit 0
