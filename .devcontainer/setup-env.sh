#!/bin/bash
# =============================================================================
# Post-create environment setup for Claude Code devcontainer
#
# Runs once after the container is first created (postCreateCommand).
# Sets up directory structure, configures SSH permissions, and prints status.
# =============================================================================

set -e

echo "=== Setting up container environment ==="

# Fix SSH key permissions (bind mount from Windows may have wrong perms)
if [ -d /home/vscode/.ssh ]; then
    # Copy to a writable location since the mount is readonly
    cp -r /home/vscode/.ssh /tmp/.ssh-setup
    chmod 700 /tmp/.ssh-setup
    chmod 600 /tmp/.ssh-setup/* 2>/dev/null || true
    chmod 644 /tmp/.ssh-setup/*.pub 2>/dev/null || true
    chmod 644 /tmp/.ssh-setup/known_hosts 2>/dev/null || true
    chmod 644 /tmp/.ssh-setup/config 2>/dev/null || true
    echo "  SSH keys found and permissions configured"
fi

# Ensure hooks directory exists
mkdir -p /home/vscode/.claude/hooks

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
echo "To start Claude Code with full permissions (safe inside container):"
echo "  claude --dangerously-skip-permissions"
echo ""
