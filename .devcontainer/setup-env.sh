#!/bin/bash
# Post-create environment setup. Deploys hooks globally and checks auth.
set -e

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

# Generate MCP config from env vars (only if no .mcp.json exists yet)
MCP_CONFIG="/home/vscode/.claude/.mcp.json"
if [ ! -f "$MCP_CONFIG" ]; then
    MCP_JSON='{"mcpServers":{}}'
    MCP_SERVERS=""

    if [ -n "${ATLASSIAN_USER_EMAIL:-}" ] && [ -n "${ATLASSIAN_API_TOKEN:-}" ] && [ -n "${ATLASSIAN_SITE_NAME:-}" ]; then
        MCP_JSON=$(echo "$MCP_JSON" | jq \
            --arg site "$ATLASSIAN_SITE_NAME" \
            --arg email "$ATLASSIAN_USER_EMAIL" \
            --arg token "$ATLASSIAN_API_TOKEN" \
            '.mcpServers.confluence = {
                "type": "stdio",
                "command": "npx",
                "args": ["-y", "@aashari/mcp-server-atlassian-confluence"],
                "env": {
                    "ATLASSIAN_SITE_NAME": $site,
                    "ATLASSIAN_USER_EMAIL": $email,
                    "ATLASSIAN_API_TOKEN": $token
                }
            }')
        MCP_SERVERS="$MCP_SERVERS confluence"
    fi

    if [ -n "${ATLASSIAN_USER_EMAIL:-}" ] && [ -n "${BITBUCKET_API_TOKEN:-}" ]; then
        MCP_JSON=$(echo "$MCP_JSON" | jq \
            --arg email "$ATLASSIAN_USER_EMAIL" \
            --arg token "$BITBUCKET_API_TOKEN" \
            '.mcpServers.bitbucket = {
                "type": "stdio",
                "command": "npx",
                "args": ["-y", "@aashari/mcp-server-atlassian-bitbucket"],
                "env": {
                    "ATLASSIAN_USER_EMAIL": $email,
                    "ATLASSIAN_API_TOKEN": $token
                }
            }')
        MCP_SERVERS="$MCP_SERVERS bitbucket"
    fi

    if [ -n "${GITHUB_PERSONAL_ACCESS_TOKEN:-}" ]; then
        MCP_JSON=$(echo "$MCP_JSON" | jq \
            --arg token "$GITHUB_PERSONAL_ACCESS_TOKEN" \
            '.mcpServers.github = {
                "type": "stdio",
                "command": "npx",
                "args": ["-y", "@modelcontextprotocol/server-github"],
                "env": {
                    "GITHUB_PERSONAL_ACCESS_TOKEN": $token
                }
            }')
        MCP_SERVERS="$MCP_SERVERS github"
    fi

    if [ -n "$MCP_SERVERS" ]; then
        echo "$MCP_JSON" | jq . > "$MCP_CONFIG"
        echo "MCP servers configured:$MCP_SERVERS"
    else
        echo "MCP servers: none (set env vars on host to enable — see README)"
    fi
else
    echo "MCP config: using existing $MCP_CONFIG"
fi

# Deploy global CLAUDE.md (only if none exists yet)
if [ ! -f /home/vscode/.claude/CLAUDE.md ]; then
    cat > /home/vscode/.claude/CLAUDE.md << 'CLAUDEMD'
# Global Container Instructions

- Markdown/documentation files (*.md) may be created or edited when explicitly requested
CLAUDEMD
fi

# Configure git credential helper for Bitbucket HTTPS push/pull
if [ -n "${ATLASSIAN_USER_EMAIL:-}" ] && [ -n "${BITBUCKET_API_TOKEN:-}" ]; then
    git config --global credential.https://bitbucket.org.helper store
    cat > /home/vscode/.git-credentials << CREDS
https://${ATLASSIAN_USER_EMAIL}:${BITBUCKET_API_TOKEN}@bitbucket.org
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

if [ -n "${SSH_AUTH_SOCK:-}" ]; then
    KEY_COUNT=$(ssh-add -l 2>/dev/null | grep -c "SHA256" || true)
    [[ "$KEY_COUNT" -gt 0 ]] && echo "SSH agent: $KEY_COUNT key(s)" || echo "WARNING: SSH agent socket exists but no keys loaded. Run ssh-add on host."
else
    echo "WARNING: No SSH agent socket. Start OpenSSH Agent on host."
fi

gh auth status >/dev/null 2>&1 && echo "GitHub CLI: authenticated" || echo "GitHub CLI: not authenticated (run gh auth login)"
echo ""
echo "Ready. Run: claude --dangerously-skip-permissions"
