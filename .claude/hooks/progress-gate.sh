#!/bin/bash
# Stop hook: blocks stop if no git progress detected. Hard cap at 3 continuations.

set -uo pipefail

INPUT=$(cat)
if ! echo "$INPUT" | jq -e . >/dev/null 2>&1; then exit 0; fi

SESSION=$(echo "$INPUT" | jq -r '.session_id // "unknown"')
STOP_HOOK_ACTIVE=$(echo "$INPUT" | jq -r 'if .stop_hook_active then "true" else "false" end')

STATE_DIR="${CLAUDE_HOOK_STATE_DIR:-/tmp}/claude-hooks-${SESSION}"
mkdir -p "$STATE_DIR"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    exit 0
fi

if [[ "$STOP_HOOK_ACTIVE" == "true" ]]; then
    CONT_FILE="${STATE_DIR}/cont-count"
    CONT_COUNT=0
    if [[ -f "$CONT_FILE" ]]; then
        CONT_COUNT=$(cat "$CONT_FILE" 2>/dev/null || echo 0)
        if ! [[ "$CONT_COUNT" =~ ^[0-9]+$ ]]; then CONT_COUNT=0; fi
    fi

    CONT_COUNT=$((CONT_COUNT + 1))
    echo "$CONT_COUNT" > "$CONT_FILE"

    if [[ "$CONT_COUNT" -ge 3 ]]; then
        exit 0
    fi
fi

# Check for uncommitted changes or recent commits as evidence of progress
if ! git rev-parse HEAD >/dev/null 2>&1; then
    CHANGES=$(git status --porcelain 2>/dev/null)
else
    CHANGES=$(git diff --stat HEAD 2>/dev/null)
    if [[ -z "$CHANGES" ]]; then
        RECENT_COMMITS=$(git log --since="10 minutes ago" --oneline 2>/dev/null)
        if [[ -n "$RECENT_COMMITS" ]]; then
            CHANGES="$RECENT_COMMITS"
        fi
    fi
fi

if [[ -n "$CHANGES" ]]; then
    exit 0
fi

jq -n '{decision: "block", reason: "No git changes detected. Continue working -- the task may not be complete."}'
exit 0
