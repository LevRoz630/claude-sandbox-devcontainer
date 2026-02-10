#!/bin/bash
# =============================================================================
# Container validation test suite
#
# Run inside the container to verify all tools, paths, permissions, and
# environment variables are correctly configured.
#
# Usage: bash /workspace/tests/test-container.sh
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
section "1. Environment Variables"
# ---------------------------------------------------------------------------

[[ "${DEVCONTAINER:-}" == "true" ]] && pass "DEVCONTAINER=true" || fail "DEVCONTAINER not set to 'true'"
[[ -n "${RENV_PATHS_CACHE:-}" ]] && pass "RENV_PATHS_CACHE is set ($RENV_PATHS_CACHE)" || fail "RENV_PATHS_CACHE not set"
[[ -n "${NODE_OPTIONS:-}" ]] && pass "NODE_OPTIONS is set ($NODE_OPTIONS)" || fail "NODE_OPTIONS not set"
[[ -n "${HISTFILE:-}" ]] && pass "HISTFILE is set ($HISTFILE)" || fail "HISTFILE not set"

# ---------------------------------------------------------------------------
section "2. Tool Availability"
# ---------------------------------------------------------------------------

command -v git >/dev/null 2>&1 && pass "git: $(git --version)" || fail "git not found"
command -v gh >/dev/null 2>&1 && pass "gh: $(gh --version | head -1)" || fail "gh not found"
command -v node >/dev/null 2>&1 && pass "node: $(node --version)" || fail "node not found"
command -v npm >/dev/null 2>&1 && pass "npm: $(npm --version)" || fail "npm not found"
command -v python3 >/dev/null 2>&1 && pass "python3: $(python3 --version)" || fail "python3 not found"
command -v R >/dev/null 2>&1 && pass "R: $(R --version 2>/dev/null | head -1)" || fail "R not found"
command -v Rscript >/dev/null 2>&1 && pass "Rscript available on PATH" || fail "Rscript not found"
command -v claude >/dev/null 2>&1 && pass "claude: $(claude --version 2>/dev/null || echo 'installed')" || fail "claude not found"
command -v jq >/dev/null 2>&1 && pass "jq available" || fail "jq not found"
command -v delta >/dev/null 2>&1 && pass "delta (git-delta) available" || fail "delta not found"
command -v poetry >/dev/null 2>&1 && pass "poetry: $(poetry --version 2>/dev/null)" || skip "poetry not on PATH (may need pipx path)"
command -v iptables >/dev/null 2>&1 && pass "iptables available" || fail "iptables not found"
command -v ipset >/dev/null 2>&1 && pass "ipset available" || fail "ipset not found"
command -v dig >/dev/null 2>&1 && pass "dig available" || fail "dig not found"
command -v aggregate >/dev/null 2>&1 && pass "aggregate available" || fail "aggregate not found"
command -v fzf >/dev/null 2>&1 && pass "fzf available" || fail "fzf not found"

# ---------------------------------------------------------------------------
section "3. R + renv"
# ---------------------------------------------------------------------------

R_RENV_CHECK=$(Rscript -e "cat(as.character(packageVersion('renv')))" 2>/dev/null)
if [[ -n "$R_RENV_CHECK" ]]; then
    pass "renv package installed (v${R_RENV_CHECK})"
else
    fail "renv package not installed in R"
fi

if [[ -d "${RENV_PATHS_CACHE:-/home/vscode/.local/share/renv}" ]]; then
    pass "renv cache directory exists"
else
    fail "renv cache directory missing"
fi

# ---------------------------------------------------------------------------
section "4. Filesystem & Permissions"
# ---------------------------------------------------------------------------

[[ -d /workspace ]] && pass "/workspace exists" || fail "/workspace missing"
[[ -w /workspace ]] && pass "/workspace is writable" || fail "/workspace not writable"

[[ -d /home/vscode/.claude ]] && pass "/home/vscode/.claude exists" || fail "/home/vscode/.claude missing"
[[ -w /home/vscode/.claude ]] && pass "/home/vscode/.claude is writable" || fail "/home/vscode/.claude not writable"

[[ -d /commandhistory ]] && pass "/commandhistory exists" || fail "/commandhistory missing"
[[ -w /commandhistory/.bash_history ]] && pass "/commandhistory/.bash_history is writable" || fail "bash history not writable"

CURRENT_USER=$(whoami)
[[ "$CURRENT_USER" == "vscode" ]] && pass "Running as user: vscode" || fail "Running as: $CURRENT_USER (expected vscode)"

# Check that we can't see host filesystem outside /workspace
if [[ -d "/mnt/c/Users" ]]; then
    fail "Host C: drive is accessible at /mnt/c (container not isolated!)"
else
    pass "Host C: drive not accessible (good isolation)"
fi

# ---------------------------------------------------------------------------
section "5. Host Bind Mounts (readonly)"
# ---------------------------------------------------------------------------

if [[ -d /home/vscode/.ssh ]]; then
    pass ".ssh directory is mounted"
    if touch /home/vscode/.ssh/__test_write 2>/dev/null; then
        rm -f /home/vscode/.ssh/__test_write
        fail ".ssh is WRITABLE (should be readonly)"
    else
        pass ".ssh is readonly as expected"
    fi
else
    skip ".ssh not mounted (host may not have .ssh dir)"
fi

if [[ -f /home/vscode/.gitconfig ]]; then
    pass ".gitconfig is mounted"
    if echo "# test" >> /home/vscode/.gitconfig 2>/dev/null; then
        fail ".gitconfig is WRITABLE (should be readonly)"
    else
        pass ".gitconfig is readonly as expected"
    fi
else
    skip ".gitconfig not mounted"
fi

if [[ -d /home/vscode/.config/gh ]]; then
    pass "gh config is mounted"
else
    skip "gh config not mounted (host may not have .config/gh)"
fi

# ---------------------------------------------------------------------------
section "6. Node.js Version Check"
# ---------------------------------------------------------------------------

NODE_MAJOR=$(node --version 2>/dev/null | cut -d'.' -f1 | tr -d 'v')
if [[ "$NODE_MAJOR" -ge 20 ]]; then
    pass "Node.js major version >= 20 (v${NODE_MAJOR})"
else
    fail "Node.js major version is $NODE_MAJOR (expected >= 20)"
fi

# ---------------------------------------------------------------------------
section "7. Firewall Script Presence"
# ---------------------------------------------------------------------------

[[ -f /usr/local/bin/init-firewall.sh ]] && pass "init-firewall.sh exists" || fail "init-firewall.sh missing"
[[ -x /usr/local/bin/init-firewall.sh ]] && pass "init-firewall.sh is executable" || fail "init-firewall.sh not executable"
[[ -f /usr/local/bin/setup-env.sh ]] && pass "setup-env.sh exists" || fail "setup-env.sh missing"
[[ -x /usr/local/bin/setup-env.sh ]] && pass "setup-env.sh is executable" || fail "setup-env.sh not executable"

# Check sudoers entry for firewall
if sudo -n /usr/local/bin/init-firewall.sh --help 2>/dev/null || sudo -l 2>/dev/null | grep -q init-firewall; then
    pass "sudoers entry allows passwordless firewall execution"
else
    skip "Cannot verify sudoers entry (may need root)"
fi

# ---------------------------------------------------------------------------
section "8. DNS Resolution (pre-firewall)"
# ---------------------------------------------------------------------------

if dig +short api.anthropic.com 2>/dev/null | head -1 | grep -qE '^[0-9]+\.'; then
    pass "DNS resolves api.anthropic.com"
else
    fail "Cannot resolve api.anthropic.com"
fi

if dig +short github.com 2>/dev/null | head -1 | grep -qE '^[0-9]+\.'; then
    pass "DNS resolves github.com"
else
    fail "Cannot resolve github.com"
fi

# ---------------------------------------------------------------------------
section "9. Git Configuration"
# ---------------------------------------------------------------------------

SAFE_DIR=$(git config --global --get-all safe.directory 2>/dev/null || true)
if echo "$SAFE_DIR" | grep -q "/workspace"; then
    pass "git safe.directory includes /workspace"
else
    skip "git safe.directory not yet configured (setup-env.sh not run)"
fi

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
