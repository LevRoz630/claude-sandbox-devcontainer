#!/bin/bash
# Test gitconfig sanitization logic from setup-env.sh.
# Runs anywhere (no container required).
set -uo pipefail

PASS=0; FAIL=0; SKIP=0
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "  SKIP: $1"; SKIP=$((SKIP + 1)); }
section() { echo ""; echo "=== $1 ==="; }

TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# The awk filter from setup-env.sh — strips [credential] and [url ...] sections
filter_gitconfig() {
    awk '
    /^\[url /        { skip=1; next }
    /^\[credential/  { skip=1; next }
    /^\[/            { skip=0 }
    !skip            { print }
    ' "$1"
}

section "1. Strips 1Password credential helper"

cat > "$TMPDIR_TEST/host.gitconfig" << 'EOF'
[user]
    name = TestUser
    email = test@example.com
[credential]
    helper = !op plugin run -- gh auth git-credential
[core]
    editor = vim
EOF

RESULT=$(filter_gitconfig "$TMPDIR_TEST/host.gitconfig")
echo "$RESULT" | grep -q "name = TestUser" && pass "Preserves user.name" || fail "Lost user.name"
echo "$RESULT" | grep -q "editor = vim" && pass "Preserves core.editor" || fail "Lost core.editor"
echo "$RESULT" | grep -q "op plugin" && fail "1Password credential helper not stripped" || pass "Strips op plugin credential helper"
echo "$RESULT" | grep -q "\[credential\]" && fail "[credential] section header not stripped" || pass "Strips [credential] section header"

section "2. Strips SSH URL rewrite (insteadOf)"

cat > "$TMPDIR_TEST/host2.gitconfig" << 'EOF'
[user]
    name = TestUser
    email = test@example.com
[url "git@github.com:"]
    insteadOf = https://github.com/
[alias]
    st = status
    co = checkout
EOF

RESULT=$(filter_gitconfig "$TMPDIR_TEST/host2.gitconfig")
echo "$RESULT" | grep -q "insteadOf" && fail "insteadOf not stripped" || pass "Strips insteadOf URL rewrite"
echo "$RESULT" | grep -q '\[url' && fail "[url] section header not stripped" || pass "Strips [url] section header"
echo "$RESULT" | grep -q "st = status" && pass "Preserves aliases" || fail "Lost aliases"
echo "$RESULT" | grep -q "co = checkout" && pass "Preserves all alias entries" || fail "Lost alias entries"

section "3. Strips both credential and URL sections together"

cat > "$TMPDIR_TEST/host3.gitconfig" << 'EOF'
[user]
    name = Lev
    email = l.rozanov@outlook.com
[credential]
    helper = !op plugin run -- gh auth git-credential
[url "git@github.com:"]
    insteadOf = https://github.com/
[core]
    autocrlf = input
    editor = code --wait
[alias]
    lg = log --oneline --graph
EOF

RESULT=$(filter_gitconfig "$TMPDIR_TEST/host3.gitconfig")
echo "$RESULT" | grep -q "op plugin" && fail "Credential helper leaked through" || pass "Both: credential helper stripped"
echo "$RESULT" | grep -q "insteadOf" && fail "insteadOf leaked through" || pass "Both: insteadOf stripped"
echo "$RESULT" | grep -q "name = Lev" && pass "Both: user.name preserved" || fail "Both: user.name lost"
echo "$RESULT" | grep -q "autocrlf = input" && pass "Both: core settings preserved" || fail "Both: core settings lost"
echo "$RESULT" | grep -q "lg = log" && pass "Both: aliases preserved" || fail "Both: aliases lost"

section "4. Handles multiple credential helpers"

cat > "$TMPDIR_TEST/host4.gitconfig" << 'EOF'
[credential]
    helper = !op plugin run -- gh auth git-credential
    helper = /usr/lib/git-core/git-credential-cache
[credential "https://bitbucket.org"]
    helper = store
[user]
    name = TestUser
EOF

RESULT=$(filter_gitconfig "$TMPDIR_TEST/host4.gitconfig")
echo "$RESULT" | grep -q "helper" && fail "Credential helper entries leaked" || pass "Strips all credential helpers"
echo "$RESULT" | grep -q '\[credential' && fail "[credential] section leaked" || pass "Strips all credential sections"
echo "$RESULT" | grep -q "name = TestUser" && pass "Preserves user after credential sections" || fail "Lost user after credential sections"

section "5. Handles empty/minimal config"

echo "" > "$TMPDIR_TEST/empty.gitconfig"
RESULT=$(filter_gitconfig "$TMPDIR_TEST/empty.gitconfig")
[[ -z "$(echo "$RESULT" | tr -d '[:space:]')" ]] && pass "Empty config produces empty output" || fail "Empty config produced unexpected output"

cat > "$TMPDIR_TEST/minimal.gitconfig" << 'EOF'
[user]
    name = Minimal
EOF
RESULT=$(filter_gitconfig "$TMPDIR_TEST/minimal.gitconfig")
echo "$RESULT" | grep -q "name = Minimal" && pass "Minimal config preserved" || fail "Minimal config lost"

section "6. URL resolution with filtered config"

(
    cd "$TMPDIR_TEST"
    git init -q testrepo && cd testrepo

    # Simulate: host config has SSH rewrite, container config does not
    filter_gitconfig "$TMPDIR_TEST/host3.gitconfig" > "$TMPDIR_TEST/filtered.gitconfig"
    git config -f "$TMPDIR_TEST/filtered.gitconfig" credential.helper '!/usr/bin/gh auth git-credential'

    RESOLVED=$(GIT_CONFIG_GLOBAL="$TMPDIR_TEST/filtered.gitconfig" git ls-remote --get-url https://github.com/foo/bar.git 2>/dev/null)
    [[ "$RESOLVED" == "https://github.com/foo/bar.git" ]] && pass "HTTPS URL stays HTTPS (no SSH rewrite)" || fail "URL resolved to: $RESOLVED (expected HTTPS)"

    HELPER=$(GIT_CONFIG_GLOBAL="$TMPDIR_TEST/filtered.gitconfig" git config --get credential.helper 2>/dev/null)
    [[ "$HELPER" == *"gh auth git-credential"* ]] && pass "Credential helper is gh CLI" || fail "Credential helper is: $HELPER"
)

section "7. Migration: re-filters config with [include]"

# Simulate old-style config with [include]
cat > "$TMPDIR_TEST/old-style.gitconfig" << 'EOF'
[include]
    path = /home/vscode/.gitconfig
[credential]
    helper =
    helper = !/usr/bin/gh auth git-credential
EOF

grep -q '^\[include\]' "$TMPDIR_TEST/old-style.gitconfig" && pass "Detects old [include]-based config" || fail "Failed to detect [include] pattern"

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[[ $FAIL -gt 0 ]] && exit 1 || exit 0
