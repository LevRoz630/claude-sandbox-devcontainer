#!/bin/bash
# Credential loader: 1Password → env vars → skip
#
# Two modes determined by --interactive flag (NOT TTY detection, because
# VS Code lifecycle commands run in a PTY that fakes interactivity):
#
#   Non-interactive (default — sourced by setup-env.sh or lifecycle commands):
#     - Uses OP_SERVICE_ACCOUNT_TOKEN if set, or exits gracefully
#   Interactive (user runs `setup-1password` which passes --interactive):
#     - Guided op account add / op signin with prompts
#
# Account config persists in a Docker volume at ~/.config/op.
# Designed to work both sourced (by setup-env.sh) and run standalone.
set -uo pipefail

# Ensure op config dir has correct ownership (Docker volumes may init as root)
# and strict permissions (op CLI requires 700, rejects 777)
OP_CONFIG_DIR="/home/vscode/.config/op"
if [ -d "$OP_CONFIG_DIR" ]; then
    if [ "$(stat -c '%U' "$OP_CONFIG_DIR" 2>/dev/null)" != "vscode" ]; then
        sudo /usr/bin/chown -R vscode:vscode "$OP_CONFIG_DIR" 2>/dev/null || true
    fi
    chmod 700 "$OP_CONFIG_DIR" 2>/dev/null || true
fi

VAULT="${OP_VAULT_NAME:-DevContainer}"
INTERACTIVE=false
for arg in "$@"; do
    [ "$arg" = "--interactive" ] && INTERACTIVE=true
done

# ---------------------------------------------------------------------------
# Helper: check if any op account is configured — FILESYSTEM ONLY.
# Never invoke `op` for this check.  Newer op CLI versions open /dev/tty
# directly and show an interactive wizard when no accounts exist, which
# hangs non-interactive scripts and hijacks our guided flow.
# The op CLI v2 stores account metadata in $OP_CONFIG_DIR/config (JSON).
# ---------------------------------------------------------------------------
op_has_account() {
    [ -s "$OP_CONFIG_DIR/config" ]
}

# ---------------------------------------------------------------------------
# Helper: non-interactive auth check.
# When OP_SERVICE_ACCOUNT_TOKEN is set, op never prompts (service-account
# mode is always non-interactive).  Otherwise we only invoke `op whoami`
# if op_has_account confirms an account exists on disk — preventing the
# interactive wizard from firing.
# ---------------------------------------------------------------------------
op_authed() {
    if [ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]; then
        op whoami >/dev/null 2>&1
        return $?
    fi
    op_has_account && op whoami </dev/null >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Helper: read a 1Password field, but only if the target env var is unset
# Usage: op_fill VAR_NAME "op://Vault/Item/field"
# ---------------------------------------------------------------------------
op_fill() {
    local var_name="$1"
    local op_ref="$2"
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
# Load credentials from 1Password (only fills vars not already set)
# ---------------------------------------------------------------------------
load_credentials() {
    echo "1Password: loading credentials from vault '${VAULT}'..."
    local loaded=0
    local failed=0

    for pair in \
        "ANTHROPIC_API_KEY:op://${VAULT}/Anthropic API Key/credential" \
        "ATLASSIAN_SITE_NAME:op://${VAULT}/Atlassian/site name" \
        "ATLASSIAN_USER_EMAIL:op://${VAULT}/Atlassian/email" \
        "ATLASSIAN_API_TOKEN:op://${VAULT}/Atlassian/api token" \
        "BITBUCKET_API_TOKEN:op://${VAULT}/Bitbucket Token/credential" \
        "GITHUB_PERSONAL_ACCESS_TOKEN:op://${VAULT}/GitHub Token/token" \
    ; do
        local var="${pair%%:*}"
        local ref="${pair#*:}"
        if [ -n "${!var:-}" ]; then
            echo "  $var: already set (env)"
        elif op_fill "$var" "$ref"; then
            echo "  $var: loaded from 1Password"
            loaded=$((loaded + 1))
        else
            echo "  $var: not found in vault"
            failed=$((failed + 1))
        fi
    done

    # SSH keys — load into agent (never touches disk)
    # If no forwarded agent exists, start one inside the container
    if [ -z "${SSH_AUTH_SOCK:-}" ]; then
        eval "$(ssh-agent -s)" >/dev/null 2>&1
        # Persist for new terminals
        local _ssh_env="/home/vscode/.ssh-agent-env"
        echo "export SSH_AUTH_SOCK=$SSH_AUTH_SOCK" > "$_ssh_env"
        echo "export SSH_AGENT_PID=$SSH_AGENT_PID" >> "$_ssh_env"
        if ! grep -q '\.ssh-agent-env' /home/vscode/.bashrc 2>/dev/null; then
            echo '[ -f ~/.ssh-agent-env ] && source ~/.ssh-agent-env' >> /home/vscode/.bashrc
        fi
    fi
    if [ -n "${SSH_AUTH_SOCK:-}" ]; then
        for key_item in "SSH Key GitHub" "SSH Key Bitbucket"; do
            if op read "op://${VAULT}/${key_item}/private_key" 2>/dev/null | ssh-add - 2>/dev/null; then
                echo "  ${key_item}: loaded into agent"
            fi
        done
    fi

    echo "1Password: ${loaded} loaded, ${failed} missing"

    # If nothing was found, show what items actually exist in the vault
    if [ "$loaded" -eq 0 ] && [ "$failed" -gt 0 ]; then
        echo ""
        echo "  Hint: expected items in vault '${VAULT}':"
        echo "    - 'Anthropic API Key' (field: credential)"
        echo "    - 'Atlassian' (fields: site name, email, api token)"
        echo "    - 'Bitbucket Token' (field: credential)"
        echo "    - 'GitHub Token' (field: token)"
        echo ""
        echo "  Items actually in vault:"
        op item list --vault "$VAULT" --format=json 2>/dev/null \
            | jq -r '.[].title // empty' 2>/dev/null \
            | while read -r title; do echo "    - '$title'"; done \
            || echo "    (could not list items)"
    fi

    # Persist exports to a dedicated credentials file (sourced by setup-env.sh and .bashrc)
    local _OP_CREDS="/home/vscode/.op-credentials"
    local _OP_VARS=(ANTHROPIC_API_KEY ATLASSIAN_SITE_NAME ATLASSIAN_USER_EMAIL
                    ATLASSIAN_API_TOKEN BITBUCKET_API_TOKEN GITHUB_PERSONAL_ACCESS_TOKEN)
    : > "$_OP_CREDS"
    for var in "${_OP_VARS[@]}"; do
        if [ -n "${!var:-}" ]; then
            printf 'export %s=%q\n' "$var" "${!var}" >> "$_OP_CREDS"
        fi
    done
    chmod 600 "$_OP_CREDS"
    # Ensure .bashrc sources the credentials file for new terminals
    if ! grep -q '\.op-credentials' /home/vscode/.bashrc 2>/dev/null; then
        echo '[ -f ~/.op-credentials ] && source ~/.op-credentials' >> /home/vscode/.bashrc
    fi
}

# ---------------------------------------------------------------------------
# Interactive signin: prompt user for account details or master password
# ---------------------------------------------------------------------------
interactive_signin() {
    # Check if an account is already configured (filesystem check, no op invocation)
    if op_has_account; then
        echo "1Password account found. Signing in..."
        echo "(Enter your master password when prompted)"
        echo ""
        if op signin; then
            echo ""
            echo "Signed in to 1Password!"
            return 0
        else
            echo "ERROR: signin failed." >&2
            return 1
        fi
    fi

    # No account configured — ask auth method
    echo "No 1Password account configured."
    echo ""
    echo "How do you sign in to 1Password?"
    echo "  1) Master password + secret key"
    echo "  2) SSO (Microsoft, Google, Okta, etc.)"
    echo ""
    read -rp "Choice [1/2]: " auth_choice

    case "$auth_choice" in
        2)
            echo ""
            echo "SSO accounts cannot sign in via the CLI without the 1Password desktop app,"
            echo "which isn't available inside the container."
            echo ""
            echo "Instead, create a service account token:"
            echo "  1. Go to your 1Password admin console → Integrations → Service Accounts"
            echo "  2. Create a token with access to your '${VAULT}' vault"
            echo "  3. Set it on your host:  setx OP_SERVICE_ACCOUNT_TOKEN \"<token>\""
            echo "  4. Rebuild the container"
            echo ""
            echo "See: https://developer.1password.com/docs/service-accounts/get-started/"
            return 1
            ;;
        1|"")
            # Master password flow — guided setup
            echo ""
            echo "You'll need:"
            echo "  - Sign-in address (e.g., my.1password.com or my.1password.eu)"
            echo "  - Email address"
            echo "  - Secret key (starts with A3-)"
            echo "  - Master password"
            echo ""

            read -rp "Sign-in address: " op_address
            if [ -z "$op_address" ]; then
                echo "ERROR: address is required." >&2
                return 1
            fi

            read -rp "Email: " op_email
            if [ -z "$op_email" ]; then
                echo "ERROR: email is required." >&2
                return 1
            fi

            read -rp "Secret key: " op_secret_key
            if [ -z "$op_secret_key" ]; then
                echo "ERROR: secret key is required." >&2
                return 1
            fi

            echo ""
            echo "Adding account and signing in..."
            echo "(Enter your master password when prompted)"
            echo ""
            if op account add --address "$op_address" --email "$op_email" --secret-key "$op_secret_key" --signin; then
                echo ""
                echo "Signed in to 1Password!"
                return 0
            else
                echo "ERROR: account add/signin failed." >&2
                return 1
            fi
            ;;
        *)
            echo "Invalid choice." >&2
            return 1
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Main logic: --interactive flag determines mode (not TTY detection)
# ---------------------------------------------------------------------------
if ! command -v op &>/dev/null; then
    echo "1Password CLI: not installed — using env vars only"
    return 0 2>/dev/null || exit 0
fi

use_op=false

if [ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]; then
    # Service account token works in any context (interactive or not)
    if op_authed; then
        use_op=true
        echo "1Password: authenticated (service account)"
    else
        echo "WARNING: OP_SERVICE_ACCOUNT_TOKEN set but authentication failed — falling back to env vars"
    fi
elif [ "$INTERACTIVE" = true ]; then
    # User explicitly ran `setup-1password` in a terminal
    if op_authed; then
        use_op=true
        echo "1Password: authenticated (cached session)"
    else
        if interactive_signin; then
            use_op=true
        else
            echo "Continuing without 1Password."
        fi
    fi
else
    # Non-interactive (postCreateCommand / postStartCommand)
    if op_authed; then
        use_op=true
        echo "1Password: authenticated (cached session)"
    else
        echo "No OP_SERVICE_ACCOUNT_TOKEN set."
        echo "Run 'setup-1password' in a terminal to set up credentials."
    fi
fi

# ---------------------------------------------------------------------------
# Load credentials if authenticated
# ---------------------------------------------------------------------------
if [ "$use_op" = true ]; then
    load_credentials
fi
