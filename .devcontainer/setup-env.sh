#!/bin/bash
# Container startup: git config, hooks, credentials, MCP. Runs on every start.
set -euo pipefail

# Writable git config derived from readonly host mount.
# We copy (not [include]) the host config, stripping [credential] and [url] sections
# that break in-container auth (e.g. 1Password op-plugin hangs, SSH insteadOf rewrites
# bypass HTTPS credential flow). User identity, core, alias, etc. are preserved.
WRITABLE_GITCONFIG="/home/vscode/.gitconfig-local"
if [ ! -f "$WRITABLE_GITCONFIG" ] || grep -q '^\[include\]' "$WRITABLE_GITCONFIG" 2>/dev/null; then
    # (Re)generate: first run or migrating from old [include]-based config
    if [ -f /home/vscode/.gitconfig ]; then
        awk '
        /^\[url /        { skip=1; next }
        /^\[credential/  { skip=1; next }
        /^\[/            { skip=0 }
        !skip            { print }
        ' /home/vscode/.gitconfig > "$WRITABLE_GITCONFIG"
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
    "SessionStart": [
      {
        "hooks": [{"type": "command", "command": "bash ~/.claude/hooks/learning-mode.sh"}]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [{"type": "command", "command": "bash ~/.claude/hooks/exfil-guard.sh"}]
      },
      {
        "matcher": "Edit|Write",
        "hooks": [{"type": "command", "command": "bash ~/.claude/hooks/plan-gate.sh"}]
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

# Fix auto-updates: Dockerfile installs via npm, not native installer
CLAUDE_JSON="/home/vscode/.claude/.claude.json"
if [ -f "$CLAUDE_JSON" ]; then
    python3 -c "
import json, sys
with open('$CLAUDE_JSON') as f: d = json.load(f)
changed = False
if d.get('installMethod') != 'npm':
    d['installMethod'] = 'npm'; changed = True
if d.get('autoUpdates') != True:
    d['autoUpdates'] = True; changed = True
if changed:
    with open('$CLAUDE_JSON', 'w') as f: json.dump(d, f, indent=2)
    print('Claude auto-update config patched')
"
fi

# MCP servers, git credentials, gh auth
source /usr/local/bin/setup-credentials.sh
setup_post_credentials

if [ ! -f /home/vscode/.claude/CLAUDE.md ]; then
    cat > /home/vscode/.claude/CLAUDE.md << 'CLAUDEMD'
# Global Container Instructions

- Markdown/documentation files (*.md) may be created or edited when explicitly requested
- Never add Co-Authored-By lines to git commits

## Interaction Style — Pedagogical Mode

- NEVER write code before a plan exists. Every task starts with questions and discussion.
- Ask ONE question at a time. Do not bundle multiple questions in one message.
- When multiple approaches exist, present options with trade-offs — do not choose for me.
- Default to Plan Mode thinking: explore, discuss, propose, then implement.
- For non-trivial logic (algorithms, business rules, error handling, data modeling),
  explain trade-offs and insert TODO(human) for me to write.
- After writing code, provide a brief Insight explaining WHY you made the choices you did.
- If I ask "why", point me to relevant files/docs rather than explaining directly.
- Never implement more than one plan step without checking in.
- Keep responses concise — no walls of text. If it takes more than a short paragraph, break it into a conversation.
CLAUDEMD
fi

git config --global --add safe.directory /workspace

# Container credential helper: gh CLI (host's op-plugin/VS Code helpers were stripped
# during gitconfig copy above; this ensures gh is always set even after rebuilds)
git config --global credential.helper '!/usr/bin/gh auth git-credential'

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
