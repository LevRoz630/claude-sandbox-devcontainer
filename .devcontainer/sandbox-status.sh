#!/bin/bash
# Full diagnostics for the Claude Code Sandbox. Run via: sandbox-status
set -uo pipefail

echo "=== Claude Code Sandbox ==="
echo ""

echo "Tools:"
echo "  R        $(R --version 2>/dev/null | head -1 | grep -oP 'version \K[^ ]+' || echo '-')"
echo "  Node     $(node --version 2>/dev/null || echo '-')"
echo "  Python   $(python3 --version 2>/dev/null | grep -oP '\d+\.\S+' || echo '-')"
echo "  Claude   $(claude --version 2>/dev/null || echo '-')"
echo ""

if [ -n "${SSH_AUTH_SOCK:-}" ]; then
    KEY_COUNT=$(ssh-add -l 2>/dev/null | grep -c "SHA256" || true)
    if [ "$KEY_COUNT" -gt 0 ]; then
        echo "SSH agent: $KEY_COUNT key(s)"
        ssh-add -l 2>/dev/null | sed 's/^/  /'
    else
        echo "SSH agent: no keys loaded"
    fi
else
    echo "SSH agent: not available"
fi
echo ""

gh auth status >/dev/null 2>&1 && echo "GitHub CLI: authenticated" || echo "GitHub CLI: not authenticated (run: gh auth login)"

if command -v op &>/dev/null; then
    if op whoami </dev/null >/dev/null 2>&1; then
        echo "1Password: authenticated"
    elif [ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]; then
        echo "1Password: token set, auth failed"
    else
        echo "1Password: not authenticated (run: setup-1password)"
    fi
fi
echo ""

echo "Credentials:"
for var in ANTHROPIC_API_KEY ATLASSIAN_SITE_NAME ATLASSIAN_USER_EMAIL \
           ATLASSIAN_API_TOKEN BITBUCKET_API_TOKEN GITHUB_PERSONAL_ACCESS_TOKEN; do
    [ -n "${!var:-}" ] && echo "  $var: set" || echo "  $var: -"
done
echo ""

echo "MCP servers:"
if command -v claude &>/dev/null; then
    claude mcp list 2>/dev/null | sed 's/^/  /' || echo "  (could not list)"
else
    echo "  (claude not found)"
fi
