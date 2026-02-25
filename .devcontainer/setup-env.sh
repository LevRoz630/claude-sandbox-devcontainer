#!/bin/bash
# Post-create environment setup. Deploys hooks globally, loads credentials, registers MCP.
# Output is compact — run `sandbox-status` for full diagnostics.
set -e

# Set up writable git config that includes the read-only mounted .gitconfig
WRITABLE_GITCONFIG="/home/vscode/.gitconfig-local"
if [ ! -f "$WRITABLE_GITCONFIG" ]; then
    if [ -f /home/vscode/.gitconfig ]; then
        echo -e "[include]\n\tpath = /home/vscode/.gitconfig" > "$WRITABLE_GITCONFIG"
    else
        touch "$WRITABLE_GITCONFIG"
    fi
fi
export GIT_CONFIG_GLOBAL="$WRITABLE_GITCONFIG"

if ! grep -q "GIT_CONFIG_GLOBAL" /home/vscode/.bashrc 2>/dev/null; then
    echo 'export GIT_CONFIG_GLOBAL="/home/vscode/.gitconfig-local"' >> /home/vscode/.bashrc
fi

# Load credentials: saved 1Password exports, then live 1Password auth
if [ -f /home/vscode/.op-credentials ]; then
    source /home/vscode/.op-credentials
fi
if [ -f /usr/local/bin/setup-1password.sh ]; then
    source /usr/local/bin/setup-1password.sh
fi

# Deploy hooks from the repo into user-level Claude config
mkdir -p /home/vscode/.claude/hooks
if [ -d /workspace/.claude/hooks ] && ls /workspace/.claude/hooks/*.sh >/dev/null 2>&1; then
    cp /workspace/.claude/hooks/*.sh /home/vscode/.claude/hooks/
    chmod +x /home/vscode/.claude/hooks/*.sh
fi

# Register hooks (only if no settings.json exists yet)
if [ ! -f /home/vscode/.claude/settings.json ]; then
    cat > /home/vscode/.claude/settings.json << 'SETTINGS'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.claude/hooks/exfil-guard.sh"
          }
        ]
      },
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.claude/hooks/dedup-check.sh"
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "WebFetch",
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.claude/hooks/injection-scanner.sh"
          }
        ]
      },
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.claude/hooks/failure-reset.sh"
          }
        ]
      }
    ],
    "PostToolUseFailure": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.claude/hooks/failure-counter.sh"
          }
        ]
      }
    ],
    "Stop": []
  }
}
SETTINGS
fi

# Credential-dependent setup (MCP servers, git credentials, gh auth)
source /usr/local/bin/setup-credentials.sh
setup_post_credentials

# Deploy global CLAUDE.md (only if none exists yet)
if [ ! -f /home/vscode/.claude/CLAUDE.md ]; then
    cat > /home/vscode/.claude/CLAUDE.md << 'CLAUDEMD'
# Global Container Instructions

- Markdown/documentation files (*.md) may be created or edited when explicitly requested
- Never add Co-Authored-By lines to git commits
CLAUDEMD
fi

mkdir -p /home/vscode/.local/share/renv
git config --global --add safe.directory /workspace

if ! grep -q "HISTFILE=/commandhistory/.bash_history" /home/vscode/.bashrc 2>/dev/null; then
    echo 'export PROMPT_COMMAND="history -a"' >> /home/vscode/.bashrc
    echo 'export HISTFILE=/commandhistory/.bash_history' >> /home/vscode/.bashrc
fi

# Compact startup summary
CRED_COUNT=0
CRED_TOTAL=0
for var in ANTHROPIC_API_KEY ATLASSIAN_SITE_NAME ATLASSIAN_USER_EMAIL \
           ATLASSIAN_API_TOKEN BITBUCKET_API_TOKEN GITHUB_PERSONAL_ACCESS_TOKEN; do
    CRED_TOTAL=$((CRED_TOTAL + 1))
    [ -n "${!var:-}" ] && CRED_COUNT=$((CRED_COUNT + 1))
done

MCP_SUMMARY="${MCP_SERVERS:- none}"

API_STATUS="set"
[ -z "${ANTHROPIC_API_KEY:-}" ] && API_STATUS="NOT SET"

echo ""
echo "Claude Sandbox ready. Run: cc"
echo "  API key: ${API_STATUS} | Credentials: ${CRED_COUNT}/${CRED_TOTAL} | MCP:${MCP_SUMMARY}"
echo "  Run 'sandbox-status' for full details."
