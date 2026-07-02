#!/bin/bash
# Unit tests for op_has_account() using mock configs. No op CLI or network.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test-lib.sh"

SETUP_SCRIPT="$SCRIPT_DIR/../.devcontainer/setup-1password.sh"
[[ ! -f "$SETUP_SCRIPT" ]] && echo "ERROR: $SETUP_SCRIPT not found" && exit 1

# Extract the function only — sourcing the whole script runs its main section
eval "$(sed -n '/^op_has_account()/,/^}/p' "$SETUP_SCRIPT")"
if ! declare -f op_has_account >/dev/null; then
    echo "ERROR: could not extract op_has_account() from $SETUP_SCRIPT"
    exit 1
fi

TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

# check_config <name> <expected: 0|1> [config-json; omit = missing file]
check_config() {
    local name="$1" expected="$2"
    OP_CONFIG_DIR="$TEST_TMP/$name"
    mkdir -p "$OP_CONFIG_DIR"
    [[ $# -ge 3 ]] && printf '%s' "$3" > "$OP_CONFIG_DIR/config"
    # Normalize: callers only branch on zero vs nonzero
    local actual
    op_has_account && actual=0 || actual=1
    if [[ "$actual" -eq "$expected" ]]; then
        pass "$name"
    else
        fail "$name (expected exit $expected, got $actual)"
    fi
}

section "op_has_account"

check_config "valid account" 0 \
    '{"latest_signin":"my","device":"abc123","accounts":[{"shorthand":"my","url":"https://my.1password.com"}]}'

check_config "stale config with accounts:null" 1 \
    '{"latest_signin":"","device":"abc123","accounts":null}'

check_config "empty accounts array" 1 \
    '{"latest_signin":"","device":"abc123","accounts":[]}'

check_config "malformed JSON" 1 '{not json'

check_config "empty file" 1 ''

check_config "missing config file" 1

results
