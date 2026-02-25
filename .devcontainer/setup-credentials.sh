#!/bin/bash
# Shared credential-dependent setup: MCP servers, git credentials, gh auth.
# Sourced by setup-env.sh (on startup) and setup-1password.sh (after interactive login).
# Expects credential env vars to already be exported.
set -uo pipefail

setup_mcp_servers() {
    local MCP_MANAGED="confluence jira bitbucket github"
    MCP_SERVERS=""

    for server in $MCP_MANAGED; do
        claude mcp remove "$server" 2>/dev/null || true
    done
    rm -f /home/vscode/.claude/.mcp.json

    if [ -n "${ATLASSIAN_USER_EMAIL:-}" ] && [ -n "${ATLASSIAN_API_TOKEN:-}" ] && [ -n "${ATLASSIAN_SITE_NAME:-}" ]; then
        local ATLASSIAN_ENV='{"ATLASSIAN_SITE_NAME":"${ATLASSIAN_SITE_NAME}","ATLASSIAN_USER_EMAIL":"${ATLASSIAN_USER_EMAIL}","ATLASSIAN_API_TOKEN":"${ATLASSIAN_API_TOKEN}"}'
        claude mcp add-json confluence "{\"type\":\"stdio\",\"command\":\"npx\",\"args\":[\"-y\",\"@aashari/mcp-server-atlassian-confluence\"],\"env\":${ATLASSIAN_ENV}}" --scope user
        claude mcp add-json jira "{\"type\":\"stdio\",\"command\":\"npx\",\"args\":[\"-y\",\"@aashari/mcp-server-atlassian-jira\"],\"env\":${ATLASSIAN_ENV}}" --scope user
        MCP_SERVERS="$MCP_SERVERS confluence jira"
    fi

    if [ -n "${ATLASSIAN_USER_EMAIL:-}" ] && [ -n "${BITBUCKET_API_TOKEN:-}" ]; then
        claude mcp add-json bitbucket '{"type":"stdio","command":"npx","args":["-y","@aashari/mcp-server-atlassian-bitbucket"],"env":{"ATLASSIAN_USER_EMAIL":"${ATLASSIAN_USER_EMAIL}","ATLASSIAN_API_TOKEN":"${BITBUCKET_API_TOKEN}"}}' --scope user
        MCP_SERVERS="$MCP_SERVERS bitbucket"
    fi

    if [ -n "${GITHUB_PERSONAL_ACCESS_TOKEN:-}" ]; then
        claude mcp add-json github '{"type":"stdio","command":"npx","args":["-y","@modelcontextprotocol/server-github"],"env":{"GITHUB_PERSONAL_ACCESS_TOKEN":"${GITHUB_PERSONAL_ACCESS_TOKEN}"}}' --scope user
        MCP_SERVERS="$MCP_SERVERS github"
    fi
}

setup_git_credentials() {
    if [ -n "${ATLASSIAN_USER_EMAIL:-}" ] && [ -n "${BITBUCKET_API_TOKEN:-}" ]; then
        git config --global credential.https://bitbucket.org.helper store
        cat > /home/vscode/.git-credentials << CREDS
https://x-bitbucket-api-token-auth:${BITBUCKET_API_TOKEN}@bitbucket.org
CREDS
        chmod 600 /home/vscode/.git-credentials
    fi
}

setup_gh_auth() {
    if [ -n "${GITHUB_PERSONAL_ACCESS_TOKEN:-}" ] && ! gh auth status >/dev/null 2>&1; then
        echo "$GITHUB_PERSONAL_ACCESS_TOKEN" | gh auth login --with-token 2>/dev/null
    fi
}

# Run all credential-dependent setup
setup_post_credentials() {
    setup_mcp_servers
    setup_git_credentials
    setup_gh_auth
}
