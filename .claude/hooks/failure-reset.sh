#!/bin/bash
# PostToolUse hook: resets the failure counter on success.

set -uo pipefail

INPUT=$(cat)
if ! echo "$INPUT" | jq -e . >/dev/null 2>&1; then exit 0; fi

SESSION=$(echo "$INPUT" | jq -r '.session_id // "unknown"')

STATE_DIR="${CLAUDE_HOOK_STATE_DIR:-/tmp}/claude-hooks-${SESSION}"
mkdir -p "$STATE_DIR"

echo "0" > "${STATE_DIR}/failure-count"
exit 0
