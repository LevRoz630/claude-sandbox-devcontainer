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
