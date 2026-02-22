#!/bin/bash
# =============================================================================
# Layer 3: Progress gate — Stop hook
#
# Checks whether Claude has made meaningful progress (via git diff) before
# allowing a session to stop. If stop_hook_active is true, tracks a
# continuation counter with a hard cap at 3 to prevent infinite loops.
#
# Exit 0 = allow stop
# Exit 0 with JSON { "decision": "block", ... } = block stop, continue working
# =============================================================================

set -uo pipefail

INPUT=$(cat)

SESSION=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('session_id','unknown'))")
STOP_HOOK_ACTIVE=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(str(d.get('stop_hook_active', False)).lower())")

STATE_DIR="${CLAUDE_HOOK_STATE_DIR:-/tmp}/claude-hooks-${SESSION}"
mkdir -p "$STATE_DIR"

# --- Not a git repo? Allow stop (nothing to measure) ---
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    exit 0
fi

# --- Handle continuation counter when stop_hook_active ---
if [[ "$STOP_HOOK_ACTIVE" == "true" ]]; then
    CONT_FILE="${STATE_DIR}/cont-count"
    CONT_COUNT=0
    if [[ -f "$CONT_FILE" ]]; then
        CONT_COUNT=$(cat "$CONT_FILE" 2>/dev/null || echo 0)
        if ! [[ "$CONT_COUNT" =~ ^[0-9]+$ ]]; then
            CONT_COUNT=0
        fi
    fi

    CONT_COUNT=$((CONT_COUNT + 1))
    echo "$CONT_COUNT" > "$CONT_FILE"

    # Hard cap — prevent infinite continuation loop
    if [[ "$CONT_COUNT" -ge 3 ]]; then
        exit 0
    fi
fi

# --- Check for git changes as evidence of progress ---
if ! git rev-parse HEAD >/dev/null 2>&1; then
    # Empty repo (no commits yet) — use git status
    CHANGES=$(git status --porcelain 2>/dev/null)
else
    CHANGES=$(git diff --stat HEAD 2>/dev/null)
fi

if [[ -n "$CHANGES" ]]; then
    # Progress detected — allow stop
    exit 0
fi

# No progress detected — block stop
python3 -c "
import json
print(json.dumps({
    'decision': 'block',
    'reason': 'No git changes detected. Continue working -- the task may not be complete.'
}))
"

exit 0
