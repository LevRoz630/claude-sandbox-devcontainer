#!/bin/bash
# Container validation tests. Run inside the devcontainer.
set -uo pipefail

PASS=0; FAIL=0; SKIP=0
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "  SKIP: $1"; SKIP=$((SKIP + 1)); }
section() { echo ""; echo "=== $1 ==="; }

section "1. Environment Variables"

[[ "${DEVCONTAINER:-}" == "true" ]] && pass "DEVCONTAINER=true" || fail "DEVCONTAINER not set to 'true'"
[[ -n "${RENV_PATHS_CACHE:-}" ]] && pass "RENV_PATHS_CACHE is set ($RENV_PATHS_CACHE)" || fail "RENV_PATHS_CACHE not set"
[[ -n "${NODE_OPTIONS:-}" ]] && pass "NODE_OPTIONS is set ($NODE_OPTIONS)" || fail "NODE_OPTIONS not set"
[[ -n "${HISTFILE:-}" ]] && pass "HISTFILE is set ($HISTFILE)" || fail "HISTFILE not set"

section "2. Tool Availability"

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
command -v poetry >/dev/null 2>&1 && pass "poetry: $(poetry --version 2>/dev/null)" || fail "poetry not found"
command -v iptables >/dev/null 2>&1 && pass "iptables available" || fail "iptables not found"
command -v ipset >/dev/null 2>&1 && pass "ipset available" || fail "ipset not found"
command -v dig >/dev/null 2>&1 && pass "dig available" || fail "dig not found"
command -v aggregate >/dev/null 2>&1 && pass "aggregate available" || fail "aggregate not found"
command -v fzf >/dev/null 2>&1 && pass "fzf available" || fail "fzf not found"
command -v op >/dev/null 2>&1 && pass "op (1Password CLI) available" || fail "op not found"

section "3. R + renv"

R_RENV_CHECK=$(Rscript -e "cat(as.character(packageVersion('renv')))" 2>/dev/null)
[[ -n "$R_RENV_CHECK" ]] && pass "renv package installed (v${R_RENV_CHECK})" || fail "renv package not installed in R"
[[ -d "${RENV_PATHS_CACHE:-/home/vscode/.local/share/renv}" ]] && pass "renv cache directory exists" || fail "renv cache directory missing"

section "4. Filesystem & Permissions"

[[ -d /workspace ]] && pass "/workspace exists" || fail "/workspace missing"
[[ -w /workspace ]] && pass "/workspace is writable" || fail "/workspace not writable"
[[ -d /home/vscode/.claude ]] && pass "/home/vscode/.claude exists" || fail "/home/vscode/.claude missing"
[[ -w /home/vscode/.claude ]] && pass "/home/vscode/.claude is writable" || fail "/home/vscode/.claude not writable"
[[ -d /commandhistory ]] && pass "/commandhistory exists" || fail "/commandhistory missing"
[[ -w /commandhistory/.bash_history ]] && pass "/commandhistory/.bash_history is writable" || fail "bash history not writable"
[[ -d /home/vscode/.config/gh ]] && pass "/home/vscode/.config/gh exists" || fail "gh config dir missing"
[[ -w /home/vscode/.config/gh ]] && pass "/home/vscode/.config/gh is writable" || fail "gh config dir not writable"

CURRENT_USER=$(whoami)
[[ "$CURRENT_USER" == "vscode" ]] && pass "Running as user: vscode" || fail "Running as: $CURRENT_USER (expected vscode)"

if [[ -d "/mnt/c/Users" ]]; then
    fail "Host C: drive is accessible at /mnt/c (container not isolated!)"
else
    pass "Host C: drive not accessible (good isolation)"
fi

section "5. Credential Isolation"

if [[ -f /home/vscode/.ssh/id_rsa ]]; then
    fail "SSH private key found at /home/vscode/.ssh/id_rsa"
elif [[ -f /home/vscode/.ssh/id_ed25519 ]]; then
    fail "SSH private key found at /home/vscode/.ssh/id_ed25519"
else
    pass "No SSH private keys in container"
fi

if [[ -f /home/vscode/.config/gh/hosts.yml ]]; then
    if grep -q "oauth_token" /home/vscode/.config/gh/hosts.yml 2>/dev/null; then
        fail "GitHub OAuth token found in hosts.yml (use GH_TOKEN env var instead)"
    else
        pass "gh hosts.yml exists but no oauth_token"
    fi
else
    pass "No pre-existing gh hosts.yml"
fi

if [[ -f /home/vscode/.op-credentials ]]; then
    fail "Plaintext credentials found at ~/.op-credentials (should use /run/credentials/op-env)"
else
    pass "No legacy ~/.op-credentials file"
fi

if [[ -f /home/vscode/.git-credentials ]]; then
    fail "Plaintext git credentials at ~/.git-credentials (should use credential-cache)"
else
    pass "No plaintext ~/.git-credentials file"
fi

if ls /tmp/.ssh-setup/* 2>/dev/null | head -1 | grep -q .; then
    fail "SSH keys found in /tmp/.ssh-setup"
else
    pass "No SSH key copies in /tmp"
fi

section "6. Sudo Lockdown"

SUDO_LIST=$(sudo -l 2>/dev/null || true)
if echo "$SUDO_LIST" | grep -q "NOPASSWD: ALL"; then
    fail "vscode has NOPASSWD: ALL (sudo not locked down!)"
else
    pass "vscode does NOT have NOPASSWD: ALL"
fi
echo "$SUDO_LIST" | grep -q "init-firewall.sh" && pass "vscode can sudo init-firewall.sh" || skip "Cannot verify firewall sudoers entry"
echo "$SUDO_LIST" | grep -q "chown.*vscode.*\.config/op" && pass "vscode can sudo chown op config dir" || skip "Cannot verify op chown sudoers entry"

if sudo iptables -L >/dev/null 2>&1; then
    fail "vscode can run 'sudo iptables' (firewall bypassable!)"
else
    pass "vscode cannot run 'sudo iptables' (firewall protected)"
fi
if sudo apt-get --version >/dev/null 2>&1; then
    fail "vscode can run 'sudo apt-get' (can install arbitrary tools!)"
else
    pass "vscode cannot run 'sudo apt-get' (system locked)"
fi

section "7. Node.js Version"

NODE_MAJOR=$(node --version 2>/dev/null | cut -d'.' -f1 | tr -d 'v')
[[ "$NODE_MAJOR" -ge 20 ]] && pass "Node.js >= 20 (v${NODE_MAJOR})" || fail "Node.js is v$NODE_MAJOR (expected >= 20)"

section "8. Script Presence"

[[ -f /usr/local/bin/init-firewall.sh ]] && pass "init-firewall.sh exists" || fail "init-firewall.sh missing"
[[ -x /usr/local/bin/init-firewall.sh ]] && pass "init-firewall.sh is executable" || fail "init-firewall.sh not executable"
[[ -f /usr/local/bin/setup-env.sh ]] && pass "setup-env.sh exists" || fail "setup-env.sh missing"
[[ -x /usr/local/bin/setup-env.sh ]] && pass "setup-env.sh is executable" || fail "setup-env.sh not executable"
[[ -f /usr/local/bin/clone-repos.sh ]] && pass "clone-repos.sh exists" || fail "clone-repos.sh missing"
[[ -x /usr/local/bin/clone-repos.sh ]] && pass "clone-repos.sh is executable" || fail "clone-repos.sh not executable"

section "9. DNS Resolution"

dig +short api.anthropic.com 2>/dev/null | head -1 | grep -qE '^[0-9]+\.' && pass "DNS resolves api.anthropic.com" || fail "Cannot resolve api.anthropic.com"
dig +short github.com 2>/dev/null | head -1 | grep -qE '^[0-9]+\.' && pass "DNS resolves github.com" || fail "Cannot resolve github.com"

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[[ $FAIL -gt 0 ]] && exit 1 || exit 0
