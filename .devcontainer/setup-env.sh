#!/bin/bash
# =============================================================================
# Post-create environment setup for Claude Code devcontainer
#
# Runs once after the container is first created (postCreateCommand).
# Sets up directory structure, checks authentication, and prints status.
# =============================================================================

set -e

echo "=== Setting up container environment ==="

# Deploy security hooks from project repo into user-level Claude config.
# This makes them global inside the container — they apply to ANY repo opened here.
# Source of truth: /workspace/.claude/hooks/
mkdir -p /home/vscode/.claude/hooks
if [ -d /workspace/.claude/hooks ] && ls /workspace/.claude/hooks/*.sh >/dev/null 2>&1; then
    cp /workspace/.claude/hooks/*.sh /home/vscode/.claude/hooks/
    chmod +x /home/vscode/.claude/hooks/*.sh
    echo "Deployed hooks: $(ls /workspace/.claude/hooks/*.sh | xargs -n1 basename | tr '\n' ' ')"
fi

# Register hooks in user-level Claude settings (global for all repos in container).
# Only writes if no settings.json exists yet (preserves manual edits).
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
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.claude/hooks/progress-gate.sh"
          }
        ]
      }
    ]
  }
}
SETTINGS
    echo "Registered hooks in user-level Claude settings"
fi

# Ensure renv cache directory exists
mkdir -p /home/vscode/.local/share/renv

# Configure git to trust the workspace
git config --global --add safe.directory /workspace

# Add bash history snippet to bashrc if not already there
if ! grep -q "HISTFILE=/commandhistory/.bash_history" /home/vscode/.bashrc 2>/dev/null; then
    echo 'export PROMPT_COMMAND="history -a"' >> /home/vscode/.bashrc
    echo 'export HISTFILE=/commandhistory/.bash_history' >> /home/vscode/.bashrc
fi

echo ""
echo "=== Container environment ready ==="
echo ""
echo "Available tools:"
echo "  R:       $(R --version 2>/dev/null | head -1 || echo 'not installed')"
echo "  Node:    $(node --version 2>/dev/null || echo 'not installed')"
echo "  Python:  $(python3 --version 2>/dev/null || echo 'not installed')"
echo "  Claude:  $(claude --version 2>/dev/null || echo 'not installed')"
echo "  Git:     $(git --version 2>/dev/null || echo 'not installed')"
echo "  Poetry:  $(poetry --version 2>/dev/null || echo 'not installed')"
echo ""

# Check SSH agent forwarding
if [ -n "$SSH_AUTH_SOCK" ]; then
    KEY_COUNT=$(ssh-add -l 2>/dev/null | grep -c "SHA256" || true)
    if [ "$KEY_COUNT" -gt 0 ]; then
        echo "SSH agent: $KEY_COUNT key(s) available via forwarding"
    else
        echo "WARNING: SSH agent socket exists but no keys loaded."
        echo "  On host, run: ssh-add"
    fi
else
    echo "WARNING: No SSH agent socket. Git SSH operations will not work."
    echo "  On Windows host, ensure OpenSSH Authentication Agent service is running:"
    echo "    Get-Service ssh-agent | Set-Service -StartupType Automatic -PassThru | Start-Service"
    echo "    ssh-add \$env:USERPROFILE\\.ssh\\id_rsa"
fi

# Check gh authentication
if gh auth status >/dev/null 2>&1; then
    echo "GitHub CLI: authenticated"
else
    echo "WARNING: GitHub CLI not authenticated."
    echo "  Run: gh auth login"
fi

echo ""
echo "To start Claude Code with full permissions (safe inside container):"
echo "  claude --dangerously-skip-permissions"
echo ""
