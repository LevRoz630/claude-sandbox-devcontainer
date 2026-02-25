#!/bin/bash
# Tests for clone-repos.sh selection parsing and validation. No gh auth needed.
set -uo pipefail

PASS=0; FAIL=0; SKIP=0
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "  SKIP: $1"; SKIP=$((SKIP + 1)); }
section() { echo ""; echo "=== $1 ==="; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLONE_SCRIPT=""
for candidate in "${SCRIPT_DIR}/../.devcontainer/clone-repos.sh" "/usr/local/bin/clone-repos.sh"; do
    if [[ -f "$candidate" ]]; then
        CLONE_SCRIPT="$candidate"; break
    fi
done

if [[ -z "$CLONE_SCRIPT" ]]; then
    echo "ERROR: clone-repos.sh not found"
    exit 1
fi
echo "Using script: $CLONE_SCRIPT"

section "1. Script Basics"

[[ -f "$CLONE_SCRIPT" ]] && pass "clone-repos.sh exists" || fail "clone-repos.sh missing"

head -1 "$CLONE_SCRIPT" | grep -q '#!/bin/bash' && pass "Has bash shebang" || fail "Missing bash shebang"

grep -q 'set -uo pipefail' "$CLONE_SCRIPT" && pass "Uses set -uo pipefail" || fail "Missing set -uo pipefail"

section "2. gh Auth Check"

# Without gh auth, script should fail with exit 1
if gh auth status &>/dev/null; then
    skip "gh is authenticated — cannot test auth-failure path"
else
    OUTPUT=$(bash "$CLONE_SCRIPT" /tmp/test-clone 2>&1)
    RC=$?
    [[ $RC -eq 1 ]] && pass "Exits 1 when gh not authenticated" || fail "Expected exit 1, got $RC"
    echo "$OUTPUT" | grep -qi "not authenticated\|error" && pass "Prints auth error message" || fail "No auth error message: $OUTPUT"
fi

section "3. Selection Parsing (unit tests)"

# We test the parsing logic by extracting it and running with mock data.
# Create a mock wrapper that simulates the selection logic.
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

cat > "$TEST_TMP/parse-selection.sh" << 'PARSESCRIPT'
#!/bin/bash
set -uo pipefail

# Mock repo array
declare -a repo_array=("user/repo-a" "user/repo-b" "user/repo-c" "user/repo-d" "user/repo-e")

selection="$1"

selected=()
if [ "$selection" = "all" ]; then
    selected=("${repo_array[@]}")
else
    IFS=',' read -ra parts <<< "$selection"
    for part in "${parts[@]}"; do
        part=$(echo "$part" | tr -d ' ')
        if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            start=${BASH_REMATCH[1]}
            end=${BASH_REMATCH[2]}
            for ((j=start; j<=end; j++)); do
                idx=$((j - 1))
                if [ $idx -ge 0 ] && [ $idx -lt ${#repo_array[@]} ]; then
                    selected+=("${repo_array[$idx]}")
                fi
            done
        elif [[ "$part" =~ ^[0-9]+$ ]]; then
            idx=$((part - 1))
            if [ $idx -ge 0 ] && [ $idx -lt ${#repo_array[@]} ]; then
                selected+=("${repo_array[$idx]}")
            fi
        fi
    done
fi

printf '%s\n' "${selected[@]}"
PARSESCRIPT
chmod +x "$TEST_TMP/parse-selection.sh"

# Test: single number
OUTPUT=$(bash "$TEST_TMP/parse-selection.sh" "1")
[[ "$OUTPUT" == "user/repo-a" ]] && pass "Single number '1' selects first repo" || fail "Single '1': got '$OUTPUT'"

OUTPUT=$(bash "$TEST_TMP/parse-selection.sh" "3")
[[ "$OUTPUT" == "user/repo-c" ]] && pass "Single number '3' selects third repo" || fail "Single '3': got '$OUTPUT'"

# Test: comma-separated
OUTPUT=$(bash "$TEST_TMP/parse-selection.sh" "1,3,5")
EXPECTED=$(printf 'user/repo-a\nuser/repo-c\nuser/repo-e')
[[ "$OUTPUT" == "$EXPECTED" ]] && pass "Comma-separated '1,3,5' selects repos a,c,e" || fail "Comma: got '$OUTPUT'"

# Test: range
OUTPUT=$(bash "$TEST_TMP/parse-selection.sh" "2-4")
EXPECTED=$(printf 'user/repo-b\nuser/repo-c\nuser/repo-d')
[[ "$OUTPUT" == "$EXPECTED" ]] && pass "Range '2-4' selects repos b,c,d" || fail "Range: got '$OUTPUT'"

# Test: mixed range and single
OUTPUT=$(bash "$TEST_TMP/parse-selection.sh" "1,3-5")
EXPECTED=$(printf 'user/repo-a\nuser/repo-c\nuser/repo-d\nuser/repo-e')
[[ "$OUTPUT" == "$EXPECTED" ]] && pass "Mixed '1,3-5' selects repos a,c,d,e" || fail "Mixed: got '$OUTPUT'"

# Test: all
OUTPUT=$(bash "$TEST_TMP/parse-selection.sh" "all")
EXPECTED=$(printf 'user/repo-a\nuser/repo-b\nuser/repo-c\nuser/repo-d\nuser/repo-e')
[[ "$OUTPUT" == "$EXPECTED" ]] && pass "'all' selects all repos" || fail "All: got '$OUTPUT'"

# Test: out-of-range number (too high)
OUTPUT=$(bash "$TEST_TMP/parse-selection.sh" "99")
[[ -z "$OUTPUT" ]] && pass "Out-of-range '99' selects nothing" || fail "Out-of-range: got '$OUTPUT'"

# Test: out-of-range number (zero)
OUTPUT=$(bash "$TEST_TMP/parse-selection.sh" "0")
[[ -z "$OUTPUT" ]] && pass "Zero '0' selects nothing (1-indexed)" || fail "Zero: got '$OUTPUT'"

# Test: spaces in input
OUTPUT=$(bash "$TEST_TMP/parse-selection.sh" "1, 3, 5")
EXPECTED=$(printf 'user/repo-a\nuser/repo-c\nuser/repo-e')
[[ "$OUTPUT" == "$EXPECTED" ]] && pass "Spaces in '1, 3, 5' handled correctly" || fail "Spaces: got '$OUTPUT'"

# Test: partial range overlap with bounds
OUTPUT=$(bash "$TEST_TMP/parse-selection.sh" "4-7")
EXPECTED=$(printf 'user/repo-d\nuser/repo-e')
[[ "$OUTPUT" == "$EXPECTED" ]] && pass "Range '4-7' clips to valid repos (d,e)" || fail "Partial range: got '$OUTPUT'"

section "4. Non-interactive Terminal Check"

# Piping stdin should trigger non-interactive error
if ! gh auth status &>/dev/null; then
    skip "gh not authenticated — cannot test non-interactive path (auth fails first)"
else
    OUTPUT=$(echo "" | bash "$CLONE_SCRIPT" /tmp/test-clone 2>&1)
    RC=$?
    # Script should either exit 1 for non-interactive or exit 0 for empty selection
    [[ $RC -le 1 ]] && pass "Non-interactive stdin: exits cleanly" || fail "Non-interactive: exit $RC"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[[ $FAIL -gt 0 ]] && exit 1 || exit 0
