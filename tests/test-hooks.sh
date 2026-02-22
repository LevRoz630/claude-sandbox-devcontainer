#!/bin/bash
# =============================================================================
# Hook unit test suite
#
# Tests all 4 hook scripts (.claude/hooks/) using mock JSON input and temp
# state directories. No Claude session or API key required.
#
# Usage: bash /workspace/tests/test-hooks.sh
# =============================================================================

set -uo pipefail

PASS=0
FAIL=0
SKIP=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "  SKIP: $1"; SKIP=$((SKIP + 1)); }

section() { echo ""; echo "=== $1 ==="; }

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

HOOKS_DIR="${HOME}/.claude/hooks"

TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

export CLAUDE_HOOK_STATE_DIR="$TEST_TMP"

# Verify hook scripts exist
for hook in dedup-check.sh failure-counter.sh failure-reset.sh progress-gate.sh; do
    if [[ ! -x "${HOOKS_DIR}/${hook}" ]]; then
        echo "ERROR: ${HOOKS_DIR}/${hook} not found or not executable"
        exit 1
    fi
done

# Helper: run a hook script with mock JSON input, capture stdout + exit code
run_hook() {
    local script="$1"
    local input="$2"
    echo "$input" | bash "${HOOKS_DIR}/${script}" 2>/dev/null
}

# Helper: build a PreToolUse JSON payload
pretool_json() {
    local session="$1"
    local tool="$2"
    local command="$3"
    python3 -c "
import json
print(json.dumps({'session_id': '$session', 'tool_name': '$tool', 'tool_input': {'command': '$command'}}))
"
}

# Helper: build a minimal session JSON payload
session_json() {
    local session="$1"
    python3 -c "import json; print(json.dumps({'session_id': '$session'}))"
}

# Helper: build a Stop hook JSON payload
stop_json() {
    local session="$1"
    local active="$2"  # "true" or "false" (JSON booleans)
    python3 -c "
import json
active = True if '$active' == 'true' else False
print(json.dumps({'session_id': '$session', 'stop_hook_active': active}))
"
}

# Helper: check if output contains a JSON key with a given value
json_has() {
    local output="$1"
    local key="$2"
    local value="$3"
    python3 -c "
import json, sys
d = json.loads(sys.argv[1])
sys.exit(0 if d.get(sys.argv[2]) == sys.argv[3] else 1)
" "$output" "$key" "$value"
}

# Helper: check if output contains a JSON key (any value)
json_has_key() {
    local output="$1"
    local key="$2"
    python3 -c "
import json, sys
d = json.loads(sys.argv[1])
sys.exit(0 if sys.argv[2] in d else 1)
" "$output" "$key"
}

# ===========================================================================
section "1. dedup-check.sh — Command Deduplication"
# ===========================================================================

# Test 1: First call → allowed (no output)
SID="dedup-test-1"
OUTPUT=$(run_hook dedup-check.sh "$(pretool_json "$SID" Bash "ls -la")")
if [[ -z "$OUTPUT" ]]; then
    pass "1st call: allowed (no output)"
else
    fail "1st call: unexpected output: $OUTPUT"
fi

# Test 2: 2nd identical call → still allowed
OUTPUT=$(run_hook dedup-check.sh "$(pretool_json "$SID" Bash "ls -la")")
if [[ -z "$OUTPUT" ]]; then
    pass "2nd identical call: allowed"
else
    fail "2nd identical call: unexpected output: $OUTPUT"
fi

# Test 3: 3rd identical call → blocked
OUTPUT=$(run_hook dedup-check.sh "$(pretool_json "$SID" Bash "ls -la")")
if json_has "$OUTPUT" "decision" "block"; then
    pass "3rd identical call: blocked with decision=block"
else
    fail "3rd identical call: expected block, got: $OUTPUT"
fi

# Test 4: Different command → allowed (separate tracking)
OUTPUT=$(run_hook dedup-check.sh "$(pretool_json "$SID" Bash "cat foo.txt")")
if [[ -z "$OUTPUT" ]]; then
    pass "Different command: allowed"
else
    fail "Different command: unexpected output: $OUTPUT"
fi

# Test 5: Different tool, same command → allowed (separate tracking)
OUTPUT=$(run_hook dedup-check.sh "$(pretool_json "$SID" Write "ls -la")")
if [[ -z "$OUTPUT" ]]; then
    pass "Different tool, same command: allowed"
else
    fail "Different tool, same command: unexpected output: $OUTPUT"
fi

# Test 6: Corrupt state file → handled gracefully
SID="dedup-test-corrupt"
# Run once to create state dir, then corrupt the file
run_hook dedup-check.sh "$(pretool_json "$SID" Bash "echo hi")" >/dev/null
# Find and corrupt the state file
CORRUPT_FILE=$(find "$TEST_TMP/claude-hooks-${SID}" -name 'dedup-*' 2>/dev/null | head -1)
if [[ -n "$CORRUPT_FILE" ]]; then
    echo "not-a-number" > "$CORRUPT_FILE"
    OUTPUT=$(run_hook dedup-check.sh "$(pretool_json "$SID" Bash "echo hi")")
    if [[ $? -eq 0 ]]; then
        pass "Corrupt state file: handled gracefully"
    else
        fail "Corrupt state file: script crashed"
    fi
else
    skip "Corrupt state file: could not find state file to corrupt"
fi

# ===========================================================================
section "2. failure-counter.sh — Consecutive Failure Tracking"
# ===========================================================================

# Test 7: 4 failures → no warning
SID="fail-test-1"
for i in 1 2 3 4; do
    OUTPUT=$(run_hook failure-counter.sh "$(session_json "$SID")")
done
if [[ -z "$OUTPUT" ]]; then
    pass "4 failures: no warning output"
else
    fail "4 failures: unexpected output: $OUTPUT"
fi

# Test 8: 5th failure → warning with additionalContext
OUTPUT=$(run_hook failure-counter.sh "$(session_json "$SID")")
if json_has_key "$OUTPUT" "additionalContext"; then
    pass "5th failure: warning with additionalContext"
else
    fail "5th failure: expected additionalContext, got: $OUTPUT"
fi

# Test 9: Missing state file → starts from 0
SID="fail-test-fresh"
OUTPUT=$(run_hook failure-counter.sh "$(session_json "$SID")")
if [[ -z "$OUTPUT" ]]; then
    pass "Fresh session: starts from 0, no warning"
else
    fail "Fresh session: unexpected output: $OUTPUT"
fi

# ===========================================================================
section "3. failure-reset.sh — Counter Reset on Success"
# ===========================================================================

# Test 10: After 4 failures, success resets counter
SID="reset-test-1"
for i in 1 2 3 4; do
    run_hook failure-counter.sh "$(session_json "$SID")" >/dev/null
done
# Now reset
run_hook failure-reset.sh "$(session_json "$SID")" >/dev/null
# Next failure should be count=1, no warning
OUTPUT=$(run_hook failure-counter.sh "$(session_json "$SID")")
if [[ -z "$OUTPUT" ]]; then
    pass "Reset after 4 failures: next failure has no warning"
else
    fail "Reset after 4 failures: unexpected output: $OUTPUT"
fi

# Test 11: Reset on missing state file → no crash
SID="reset-test-fresh"
OUTPUT=$(run_hook failure-reset.sh "$(session_json "$SID")")
EXIT_CODE=$?
if [[ $EXIT_CODE -eq 0 ]]; then
    pass "Reset on missing state file: no crash (exit 0)"
else
    fail "Reset on missing state file: exit code $EXIT_CODE"
fi

# ===========================================================================
section "4. progress-gate.sh — Stop Hook with Progress Check"
# ===========================================================================

# Create a temp git repo for git-based tests
TEST_REPO=$(mktemp -d)
git -C "$TEST_REPO" init >/dev/null 2>&1
git -C "$TEST_REPO" config user.email "test@test.com"
git -C "$TEST_REPO" config user.name "Test"
GIT_COMMITTER_DATE="2025-01-01T00:00:00" GIT_AUTHOR_DATE="2025-01-01T00:00:00" \
    git -C "$TEST_REPO" commit --allow-empty -m "init" >/dev/null 2>&1

# Test 12: stop_hook_active=false + git changes → allow stop
SID="progress-test-1"
echo "change" > "$TEST_REPO/file.txt"
git -C "$TEST_REPO" add file.txt
OUTPUT=$(cd "$TEST_REPO" && run_hook progress-gate.sh "$(stop_json "$SID" false)")
if [[ -z "$OUTPUT" ]]; then
    pass "stop_hook_active=false + changes: allow stop"
else
    fail "stop_hook_active=false + changes: unexpected output: $OUTPUT"
fi
# Clean up the change
git -C "$TEST_REPO" reset HEAD -- file.txt >/dev/null 2>&1
rm -f "$TEST_REPO/file.txt"

# Test 13: stop_hook_active=false + no git changes → block stop
SID="progress-test-2"
OUTPUT=$(cd "$TEST_REPO" && run_hook progress-gate.sh "$(stop_json "$SID" false)")
if json_has "$OUTPUT" "decision" "block"; then
    pass "stop_hook_active=false + no changes: block stop"
else
    fail "stop_hook_active=false + no changes: expected block, got: $OUTPUT"
fi

# Test 14: stop_hook_active=true + cont_count < 3 → block
SID="progress-test-3"
OUTPUT=$(cd "$TEST_REPO" && run_hook progress-gate.sh "$(stop_json "$SID" true)")
if json_has "$OUTPUT" "decision" "block"; then
    pass "stop_hook_active=true, cont_count=1: block"
else
    fail "stop_hook_active=true, cont_count=1: expected block, got: $OUTPUT"
fi

# Test 15: stop_hook_active=true + cont_count >= 3 → allow (hard cap)
SID="progress-test-4"
# Run 3 times to hit the hard cap
cd "$TEST_REPO"
run_hook progress-gate.sh "$(stop_json "$SID" true)" >/dev/null
run_hook progress-gate.sh "$(stop_json "$SID" true)" >/dev/null
OUTPUT=$(run_hook progress-gate.sh "$(stop_json "$SID" true)")
cd - >/dev/null
if [[ -z "$OUTPUT" ]]; then
    pass "stop_hook_active=true, cont_count=3: allow stop (hard cap)"
else
    fail "stop_hook_active=true, cont_count=3: expected allow, got: $OUTPUT"
fi

# Test 16: Not a git repo → allow stop
SID="progress-test-nogit"
NON_GIT_DIR=$(mktemp -d)
OUTPUT=$(cd "$NON_GIT_DIR" && run_hook progress-gate.sh "$(stop_json "$SID" false)")
if [[ -z "$OUTPUT" ]]; then
    pass "Not a git repo: allow stop"
else
    fail "Not a git repo: unexpected output: $OUTPUT"
fi
rm -rf "$NON_GIT_DIR"

# Test 17: Empty git repo (no commits) → use git status fallback
SID="progress-test-empty"
EMPTY_REPO=$(mktemp -d)
git -C "$EMPTY_REPO" init >/dev/null 2>&1
# Add a file so git status --porcelain shows something
echo "new" > "$EMPTY_REPO/readme.txt"
git -C "$EMPTY_REPO" add readme.txt
OUTPUT=$(cd "$EMPTY_REPO" && run_hook progress-gate.sh "$(stop_json "$SID" false)")
if [[ -z "$OUTPUT" ]]; then
    pass "Empty repo with staged file: allow stop (status fallback)"
else
    fail "Empty repo with staged file: unexpected output: $OUTPUT"
fi
rm -rf "$EMPTY_REPO"

# Cleanup test repo
rm -rf "$TEST_REPO"

# ---------------------------------------------------------------------------
echo ""
echo "==========================================="
echo "  Results: $PASS passed, $FAIL failed, $SKIP skipped"
echo "==========================================="

if [[ $FAIL -gt 0 ]]; then
    exit 1
else
    exit 0
fi
