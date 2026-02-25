#!/bin/bash
# Credential loader: 1Password → env vars → skip
#
# Modes (--interactive flag, NOT TTY detection — VS Code PTY fakes interactivity):
#   Non-interactive (default): uses OP_SERVICE_ACCOUNT_TOKEN or exits gracefully
#   Interactive (`setup-1password`): guided op account add / op signin
#
# Account config persists in Docker volume at ~/.config/op.
set -uo pipefail

# Fix op config dir ownership/perms (Docker volumes may init as root; op requires 700)
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

# Filesystem-only check — never invoke `op` here (newer CLIs open /dev/tty and hang)
op_has_account() {
    [ -s "$OP_CONFIG_DIR/config" ]
}

op_authed() {
    if [ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]; then
        op whoami >/dev/null 2>&1
        return $?
    fi
    op_has_account && op whoami </dev/null >/dev/null 2>&1
}

# Read a 1Password field into env var (skips if already set)
op_fill() {
    local var_name="$1" op_ref="$2"
    [ -n "${!var_name:-}" ] && return 0
    local val
    val=$(op read "$op_ref" 2>/dev/null) || return 1
    [ -n "$val" ] && export "$var_name=$val"
}

load_credentials() {
    echo "Loading credentials from vault '${VAULT}'..."
    local loaded=0 failed=0

    for pair in \
        "ANTHROPIC_API_KEY:op://${VAULT}/Anthropic API Key/credential" \
        "ATLASSIAN_SITE_NAME:op://${VAULT}/Atlassian/site name" \
        "ATLASSIAN_USER_EMAIL:op://${VAULT}/Atlassian/email" \
        "ATLASSIAN_API_TOKEN:op://${VAULT}/Atlassian/api token" \
        "BITBUCKET_API_TOKEN:op://${VAULT}/Bitbucket Token/credential" \
        "GITHUB_PERSONAL_ACCESS_TOKEN:op://${VAULT}/GitHub Token/token" \
    ; do
        local var="${pair%%:*}" ref="${pair#*:}"
        if [ -n "${!var:-}" ]; then
            echo "  $var: already set (env)"
        elif op_fill "$var" "$ref"; then
            echo "  $var: loaded"
            loaded=$((loaded + 1))
        else
            echo "  $var: not found in vault"
            failed=$((failed + 1))
        fi
    done

    # SSH keys — load into agent (never touches disk)
    if [ -z "${SSH_AUTH_SOCK:-}" ]; then
        eval "$(ssh-agent -s)" >/dev/null 2>&1
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

    echo "${loaded} loaded, ${failed} missing"

    # Hint when nothing was found
    if [ "$loaded" -eq 0 ] && [ "$failed" -gt 0 ]; then
        echo ""
        echo "  Expected items in vault '${VAULT}':"
        echo "    'Anthropic API Key' (credential), 'Atlassian' (site name, email, api token)"
        echo "    'Bitbucket Token' (credential), 'GitHub Token' (token)"
        echo ""
        echo "  Actual items:"
        op item list --vault "$VAULT" --format=json 2>/dev/null \
            | jq -r '.[].title // empty' 2>/dev/null \
            | while read -r title; do echo "    - $title"; done \
            || echo "    (could not list)"
    fi

    # Persist for new shells
    local _creds="/home/vscode/.op-credentials"
    local _vars=(ANTHROPIC_API_KEY ATLASSIAN_SITE_NAME ATLASSIAN_USER_EMAIL
                 ATLASSIAN_API_TOKEN BITBUCKET_API_TOKEN GITHUB_PERSONAL_ACCESS_TOKEN)
    : > "$_creds"
    for var in "${_vars[@]}"; do
        [ -n "${!var:-}" ] && printf 'export %s=%q\n' "$var" "${!var}" >> "$_creds"
    done
    chmod 600 "$_creds"
    if ! grep -q '\.op-credentials' /home/vscode/.bashrc 2>/dev/null; then
        echo '[ -f ~/.op-credentials ] && source ~/.op-credentials' >> /home/vscode/.bashrc
    fi
}

interactive_signin() {
    if op_has_account; then
        echo "1Password account found. Enter your master password:"
        echo ""
        if eval "$(op signin)"; then
            echo ""
            echo "Signed in."
            return 0
        else
            echo "ERROR: signin failed." >&2
            return 1
        fi
    fi

    echo "No 1Password account configured."
    echo ""
    echo "How do you sign in?"
    echo "  1) Master password + secret key"
    echo "  2) SSO (Microsoft, Google, Okta, etc.)"
    echo ""
    read -rp "Choice [1/2]: " auth_choice

    case "$auth_choice" in
        2)
            echo ""
            echo "SSO requires the 1Password desktop app (not available in container)."
            echo "Use a service account token instead:"
            echo "  1. Admin console → Integrations → Service Accounts"
            echo "  2. Create token with access to '${VAULT}' vault"
            echo "  3. Set on host: export OP_SERVICE_ACCOUNT_TOKEN=\"<token>\""
            echo "  4. Rebuild container"
            return 1
            ;;
        1|"")
            echo ""
            echo "You'll need: sign-in address, email, secret key (A3-...), master password"
            echo ""
            read -rp "Sign-in address: " op_address
            [ -z "$op_address" ] && { echo "ERROR: required." >&2; return 1; }
            read -rp "Email: " op_email
            [ -z "$op_email" ] && { echo "ERROR: required." >&2; return 1; }
            read -rp "Secret key: " op_secret_key
            [ -z "$op_secret_key" ] && { echo "ERROR: required." >&2; return 1; }
            echo ""
            if eval "$(op account add --address "$op_address" --email "$op_email" --secret-key "$op_secret_key" --signin)"; then
                echo ""
                echo "Signed in."
                return 0
            else
                echo "ERROR: signin failed." >&2
                return 1
            fi
            ;;
        *)
            echo "Invalid choice." >&2
            return 1
            ;;
    esac
}

# Main
if ! command -v op &>/dev/null; then
    [ "$INTERACTIVE" = true ] && echo "1Password CLI not installed."
    return 0 2>/dev/null || exit 0
fi

use_op=false

if [ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]; then
    if op_authed; then
        use_op=true
        [ "$INTERACTIVE" = true ] && echo "1Password: authenticated (service account)"
    else
        [ "$INTERACTIVE" = true ] && echo "WARNING: OP_SERVICE_ACCOUNT_TOKEN set but auth failed"
    fi
elif [ "$INTERACTIVE" = true ]; then
    if op_authed; then
        use_op=true
        echo "1Password: authenticated (cached session)"
    else
        interactive_signin && use_op=true || echo "Continuing without 1Password."
    fi
else
    op_authed && use_op=true
fi

if [ "$use_op" = true ]; then
    load_credentials

    if [ "$INTERACTIVE" = true ]; then
        source /usr/local/bin/setup-credentials.sh
        setup_post_credentials
        echo ""
        echo "Done. MCP servers and git credentials updated."
        echo "Run 'sandbox-status' for details, or 'cc' to start."
    fi
fi
