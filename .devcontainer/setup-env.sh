#!/bin/bash
# Container startup: git config, hooks, credentials, MCP. Runs on every start.
set -euo pipefail

# Writable git config that [include]s the readonly host mount
WRITABLE_GITCONFIG="/home/vscode/.gitconfig-local"
if [ ! -f "$WRITABLE_GITCONFIG" ]; then
    if [ -f /home/vscode/.gitconfig ]; then
        echo -e "[include]\n\tpath = /home/vscode/.gitconfig" > "$WRITABLE_GITCONFIG"
    else
        touch "$WRITABLE_GITCONFIG"
    fi
fi

if ! grep -q "GIT_CONFIG_GLOBAL" /home/vscode/.bashrc 2>/dev/null; then
    echo 'export GIT_CONFIG_GLOBAL="/home/vscode/.gitconfig-local"' >> /home/vscode/.bashrc
fi

# Credentials (1Password or env vars) — tmpfs (RAM-only)
[ -f /run/credentials/op-env ] && source /run/credentials/op-env
[ -f /usr/local/bin/setup-1password.sh ] && source /usr/local/bin/setup-1password.sh || true

# GH_TOKEN for new shells (env var, no file written)
if [ -n "${GITHUB_PERSONAL_ACCESS_TOKEN:-}" ]; then
    if ! grep -q 'GH_TOKEN' /home/vscode/.bashrc 2>/dev/null; then
        echo 'export GH_TOKEN="${GITHUB_PERSONAL_ACCESS_TOKEN:-}"' >> /home/vscode/.bashrc
    fi
fi

# Deploy hooks globally
mkdir -p /home/vscode/.claude/hooks
if [ -d /workspace/.claude/hooks ] && ls /workspace/.claude/hooks/*.sh >/dev/null 2>&1; then
    cp /workspace/.claude/hooks/*.sh /home/vscode/.claude/hooks/
    chmod +x /home/vscode/.claude/hooks/*.sh
fi

if [ ! -f /home/vscode/.claude/settings.json ]; then
    cat > /home/vscode/.claude/settings.json << 'SETTINGS'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [{"type": "command", "command": "bash ~/.claude/hooks/exfil-guard.sh"}]
      },
      {
        "matcher": "",
        "hooks": [{"type": "command", "command": "bash ~/.claude/hooks/dedup-check.sh"}]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "WebFetch",
        "hooks": [{"type": "command", "command": "bash ~/.claude/hooks/injection-scanner.sh"}]
      },
      {
        "matcher": "",
        "hooks": [{"type": "command", "command": "bash ~/.claude/hooks/failure-reset.sh"}]
      }
    ],
    "PostToolUseFailure": [
      {
        "matcher": "",
        "hooks": [{"type": "command", "command": "bash ~/.claude/hooks/failure-counter.sh"}]
      }
    ],
    "Stop": []
  }
}
SETTINGS
fi

# MCP servers, git credentials, gh auth
source /usr/local/bin/setup-credentials.sh
setup_post_credentials

if [ ! -f /home/vscode/.claude/CLAUDE.md ]; then
    cat > /home/vscode/.claude/CLAUDE.md << 'CLAUDEMD'
# Global Container Instructions

- Markdown/documentation files (*.md) may be created or edited when explicitly requested
- Never add Co-Authored-By lines to git commits
CLAUDEMD
fi

git config --global --add safe.directory /workspace

if ! grep -q "HISTFILE=/commandhistory/.bash_history" /home/vscode/.bashrc 2>/dev/null; then
    echo 'export PROMPT_COMMAND="history -a"' >> /home/vscode/.bashrc
    echo 'export HISTFILE=/commandhistory/.bash_history' >> /home/vscode/.bashrc
fi

# Startup summary
CRED_COUNT=0
CRED_TOTAL=0
for var in ANTHROPIC_API_KEY ATLASSIAN_SITE_NAME ATLASSIAN_USER_EMAIL \
           ATLASSIAN_API_TOKEN BITBUCKET_API_TOKEN GITHUB_PERSONAL_ACCESS_TOKEN; do
    CRED_TOTAL=$((CRED_TOTAL + 1))
    [ -n "${!var:-}" ] && CRED_COUNT=$((CRED_COUNT + 1))
done

API_STATUS="set"
[ -z "${ANTHROPIC_API_KEY:-}" ] && API_STATUS="NOT SET"

echo ""
echo "Claude Sandbox ready. Run: cc"
echo "  API key: ${API_STATUS} | Credentials: ${CRED_COUNT}/${CRED_TOTAL} | MCP:${MCP_SERVERS:- none}"
echo "  Run 'sandbox-status' for full details."
