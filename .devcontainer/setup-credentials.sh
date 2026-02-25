#!/bin/bash
# MCP servers, git credentials, gh auth. Sourced by setup-env.sh and setup-1password.sh.
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
        # Use credential-cache (in-memory daemon) instead of credential-store (plaintext file)
        git config --global credential.https://bitbucket.org.helper cache
        git credential-cache store <<CREDS
protocol=https
host=bitbucket.org
username=x-bitbucket-api-token-auth
password=${BITBUCKET_API_TOKEN}

CREDS
    fi
    # Clean up any legacy plaintext credential file
    rm -f /home/vscode/.git-credentials
}

setup_gh_auth() {
    # Use GH_TOKEN env var instead of gh auth login (avoids writing token to disk)
    if [ -n "${GITHUB_PERSONAL_ACCESS_TOKEN:-}" ]; then
        export GH_TOKEN="$GITHUB_PERSONAL_ACCESS_TOKEN"
    fi
}

setup_post_credentials() {
    setup_mcp_servers
    setup_git_credentials
    setup_gh_auth
}
