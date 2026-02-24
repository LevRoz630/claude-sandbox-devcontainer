#!/bin/bash
# Credential loader: 1Password → env vars → skip
# Sources credentials from 1Password vault if available, otherwise falls back
# to existing environment variables (set via containerEnv or .env file).
# Designed to be sourced by setup-env.sh, not run standalone.
set -uo pipefail

VAULT="${OP_VAULT_NAME:-DevContainer}"

# ---------------------------------------------------------------------------
# Helper: read a 1Password field, but only if the target env var is unset
# Usage: op_fill VAR_NAME "op://Vault/Item/field"
# ---------------------------------------------------------------------------
op_fill() {
    local var_name="$1"
    local op_ref="$2"
    # Skip if already set from env / .env
    if [ -n "${!var_name:-}" ]; then
        return 0
    fi
    local val
    val=$(op read "$op_ref" 2>/dev/null) || return 1
    if [ -n "$val" ]; then
        export "$var_name=$val"
    fi
}

# ---------------------------------------------------------------------------
# Decide whether to use 1Password
# ---------------------------------------------------------------------------
use_op=false

if ! command -v op &>/dev/null; then
    echo "1Password CLI: not installed — using env vars only"
elif [ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]; then
    # Service account mode — automatic, no interaction needed
    if op vault list --format=json >/dev/null 2>&1; then
        use_op=true
        echo "1Password: authenticated (service account)"
    else
        echo "WARNING: OP_SERVICE_ACCOUNT_TOKEN set but authentication failed — falling back to env vars"
    fi
else
    # Interactive mode — check if user has a session or account configured
    if op vault list --format=json >/dev/null 2>&1; then
        # Already signed in (cached session)
        use_op=true
        echo "1Password: authenticated (cached session)"
    elif op account list --format=json 2>/dev/null | jq -e 'length > 0' >/dev/null 2>&1; then
        # Account configured but session expired — need sign-in
        echo "1Password: account configured, session expired."
        echo "Run 'eval \$(op signin)' in terminal to authenticate, then re-run setup."
        echo "Falling back to env vars for now."
    else
        echo "1Password CLI: no account configured — using env vars only"
        echo "  To set up: op account add --address <your>.1password.com --email <you@example.com>"
    fi
fi

# ---------------------------------------------------------------------------
# Load credentials from 1Password (only fills vars not already set)
# ---------------------------------------------------------------------------
if [ "$use_op" = true ]; then
    echo "1Password: loading credentials from vault '${VAULT}'..."
    loaded=0
    failed=0

    for pair in \
        "ANTHROPIC_API_KEY:op://${VAULT}/Anthropic API Key/credential" \
        "ATLASSIAN_SITE_NAME:op://${VAULT}/Atlassian/site name" \
        "ATLASSIAN_USER_EMAIL:op://${VAULT}/Atlassian/email" \
        "ATLASSIAN_API_TOKEN:op://${VAULT}/Atlassian/api token" \
        "BITBUCKET_API_TOKEN:op://${VAULT}/Bitbucket Token/credential" \
        "GITHUB_PERSONAL_ACCESS_TOKEN:op://${VAULT}/GitHub Token/token" \
    ; do
        var="${pair%%:*}"
        ref="${pair#*:}"
        if [ -n "${!var:-}" ]; then
            echo "  $var: already set (env)"
        elif op_fill "$var" "$ref"; then
            echo "  $var: loaded from 1Password"
            ((loaded++))
        else
            echo "  $var: not found in vault"
            ((failed++))
        fi
    done

    # SSH key — load into agent (never touches disk)
    if [ -n "${SSH_AUTH_SOCK:-}" ]; then
        if op read "op://${VAULT}/SSH Key/private_key?ssh-format=openssh" 2>/dev/null | ssh-add - 2>/dev/null; then
            echo "  SSH key: loaded into agent from 1Password"
        else
            echo "  SSH key: not found in vault (using host agent forwarding)"
        fi
    fi

    # GitHub CLI auth
    if [ -n "${GITHUB_PERSONAL_ACCESS_TOKEN:-}" ] && ! gh auth status >/dev/null 2>&1; then
        echo "$GITHUB_PERSONAL_ACCESS_TOKEN" | gh auth login --with-token 2>/dev/null \
            && echo "  GitHub CLI: authenticated via 1Password token" \
            || echo "  GitHub CLI: auth failed"
    fi

    echo "1Password: ${loaded} loaded, ${failed} missing"
fi

# ---------------------------------------------------------------------------
# Summary of credential sources
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Persist exports in bashrc so new terminal sessions inherit them
# ---------------------------------------------------------------------------
for var in ANTHROPIC_API_KEY ATLASSIAN_SITE_NAME ATLASSIAN_USER_EMAIL \
           ATLASSIAN_API_TOKEN BITBUCKET_API_TOKEN GITHUB_PERSONAL_ACCESS_TOKEN; do
    if [ -n "${!var:-}" ]; then
        # Remove any old export for this var, then append the new one
        sed -i "/^export ${var}=/d" /home/vscode/.bashrc 2>/dev/null || true
        echo "export ${var}='${!var}'" >> /home/vscode/.bashrc
    fi
done
