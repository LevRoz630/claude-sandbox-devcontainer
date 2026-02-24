#!/bin/bash
# Post-create environment setup. Deploys hooks globally and checks auth.
set -e

# Set up writable git config that includes the read-only mounted .gitconfig
# The host .gitconfig is mounted read-only at ~/.gitconfig; we point git to a
# writable file that [include]s it so `git config --global` works.
WRITABLE_GITCONFIG="/home/vscode/.gitconfig-local"
if [ ! -f "$WRITABLE_GITCONFIG" ]; then
    if [ -f /home/vscode/.gitconfig ]; then
        echo -e "[include]\n\tpath = /home/vscode/.gitconfig" > "$WRITABLE_GITCONFIG"
    else
        touch "$WRITABLE_GITCONFIG"
    fi
fi
export GIT_CONFIG_GLOBAL="$WRITABLE_GITCONFIG"

# Load credentials: first check for previously saved 1Password credentials,
# then try live 1Password auth (service account or cached session)
if [ -f /home/vscode/.op-credentials ]; then
    source /home/vscode/.op-credentials
fi
if [ -f /usr/local/bin/setup-1password.sh ]; then
    source /usr/local/bin/setup-1password.sh
fi

# Make it persistent across shells
if ! grep -q "GIT_CONFIG_GLOBAL" /home/vscode/.bashrc 2>/dev/null; then
    echo 'export GIT_CONFIG_GLOBAL="/home/vscode/.gitconfig-local"' >> /home/vscode/.bashrc
fi

# Deploy hooks from the repo into user-level Claude config (global for all repos in container)
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

# Register MCP servers via claude CLI (handles config location/format automatically)
# Uses ${VAR} references (expanded by Claude Code at runtime) so no plaintext secrets on disk.
# Servers are removed then re-added on every run so stale entries are cleaned up.
MCP_MANAGED="confluence jira bitbucket github"
MCP_SERVERS=""

# Remove managed servers (clean slate — prevents stale entries when credentials are removed)
for server in $MCP_MANAGED; do
    claude mcp remove "$server" 2>/dev/null || true
done

rm -f /home/vscode/.claude/.mcp.json

if [ -n "${ATLASSIAN_USER_EMAIL:-}" ] && [ -n "${ATLASSIAN_API_TOKEN:-}" ] && [ -n "${ATLASSIAN_SITE_NAME:-}" ]; then
    claude mcp add-json confluence '{"type":"stdio","command":"npx","args":["-y","@aashari/mcp-server-atlassian-confluence"],"env":{"ATLASSIAN_SITE_NAME":"${ATLASSIAN_SITE_NAME}","ATLASSIAN_USER_EMAIL":"${ATLASSIAN_USER_EMAIL}","ATLASSIAN_API_TOKEN":"${ATLASSIAN_API_TOKEN}"}}' --scope user
    MCP_SERVERS="$MCP_SERVERS confluence"
fi

if [ -n "${ATLASSIAN_USER_EMAIL:-}" ] && [ -n "${ATLASSIAN_API_TOKEN:-}" ] && [ -n "${ATLASSIAN_SITE_NAME:-}" ]; then
    claude mcp add-json jira '{"type":"stdio","command":"npx","args":["-y","@aashari/mcp-server-atlassian-jira"],"env":{"ATLASSIAN_SITE_NAME":"${ATLASSIAN_SITE_NAME}","ATLASSIAN_USER_EMAIL":"${ATLASSIAN_USER_EMAIL}","ATLASSIAN_API_TOKEN":"${ATLASSIAN_API_TOKEN}"}}' --scope user
    MCP_SERVERS="$MCP_SERVERS jira"
fi

if [ -n "${ATLASSIAN_USER_EMAIL:-}" ] && [ -n "${BITBUCKET_API_TOKEN:-}" ]; then
    claude mcp add-json bitbucket '{"type":"stdio","command":"npx","args":["-y","@aashari/mcp-server-atlassian-bitbucket"],"env":{"ATLASSIAN_USER_EMAIL":"${ATLASSIAN_USER_EMAIL}","ATLASSIAN_API_TOKEN":"${BITBUCKET_API_TOKEN}"}}' --scope user
    MCP_SERVERS="$MCP_SERVERS bitbucket"
fi

if [ -n "${GITHUB_PERSONAL_ACCESS_TOKEN:-}" ]; then
    claude mcp add-json github '{"type":"stdio","command":"npx","args":["-y","@modelcontextprotocol/server-github"],"env":{"GITHUB_PERSONAL_ACCESS_TOKEN":"${GITHUB_PERSONAL_ACCESS_TOKEN}"}}' --scope user
    MCP_SERVERS="$MCP_SERVERS github"
fi

if [ -n "$MCP_SERVERS" ]; then
    echo "MCP servers registered:$MCP_SERVERS"
    echo "  Verify: claude mcp list"
else
    echo "MCP servers: none (set env vars on host to enable — see README)"
fi

# Deploy global CLAUDE.md (only if none exists yet)
if [ ! -f /home/vscode/.claude/CLAUDE.md ]; then
    cat > /home/vscode/.claude/CLAUDE.md << 'CLAUDEMD'
# Global Container Instructions

- Markdown/documentation files (*.md) may be created or edited when explicitly requested
- Never add Co-Authored-By lines to git commits
CLAUDEMD
fi

# Configure git credential helper for Bitbucket HTTPS push/pull
if [ -n "${ATLASSIAN_USER_EMAIL:-}" ] && [ -n "${BITBUCKET_API_TOKEN:-}" ]; then
    git config --global credential.https://bitbucket.org.helper store
    # Bitbucket scoped API tokens require x-bitbucket-api-token-auth as the username
    cat > /home/vscode/.git-credentials << CREDS
https://x-bitbucket-api-token-auth:${BITBUCKET_API_TOKEN}@bitbucket.org
CREDS
    chmod 600 /home/vscode/.git-credentials
    echo "Bitbucket git HTTPS: configured"
fi

mkdir -p /home/vscode/.local/share/renv
git config --global --add safe.directory /workspace

if ! grep -q "HISTFILE=/commandhistory/.bash_history" /home/vscode/.bashrc 2>/dev/null; then
    echo 'export PROMPT_COMMAND="history -a"' >> /home/vscode/.bashrc
    echo 'export HISTFILE=/commandhistory/.bash_history' >> /home/vscode/.bashrc
fi

echo ""
echo "Tools: R $(R --version 2>/dev/null | head -1 | grep -oP 'version \K[^ ]+' || echo '?'), Node $(node --version 2>/dev/null || echo '?'), Python $(python3 --version 2>/dev/null | grep -oP '\d+\.\S+' || echo '?'), Claude $(claude --version 2>/dev/null || echo '?')"

# Auth status (covers env vars, 1Password, and manual login)
if [ -n "${SSH_AUTH_SOCK:-}" ]; then
    KEY_COUNT=$(ssh-add -l 2>/dev/null | grep -c "SHA256" || true)
    [[ "$KEY_COUNT" -gt 0 ]] && echo "SSH agent: $KEY_COUNT key(s)" || echo "SSH agent: socket exists but no keys loaded"
else
    echo "SSH agent: not available (run setup-1password to load keys from 1Password, or use HTTPS)"
fi

if [ -n "${GITHUB_PERSONAL_ACCESS_TOKEN:-}" ] && ! gh auth status >/dev/null 2>&1; then
    echo "$GITHUB_PERSONAL_ACCESS_TOKEN" | gh auth login --with-token 2>/dev/null
fi
gh auth status >/dev/null 2>&1 && echo "GitHub CLI: authenticated" || echo "GitHub CLI: not authenticated (run gh auth login)"

echo ""
echo "Credential status:"
for var in ANTHROPIC_API_KEY ATLASSIAN_SITE_NAME ATLASSIAN_USER_EMAIL \
           ATLASSIAN_API_TOKEN BITBUCKET_API_TOKEN GITHUB_PERSONAL_ACCESS_TOKEN; do
    if [ -n "${!var:-}" ]; then
        echo "  $var: set"
    else
        echo "  $var: NOT SET"
    fi
done

echo ""
echo "Aliases: cc = claude --dangerously-skip-permissions"
echo "Ready. Run: cc"
