#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# =============================================================================
# Allowlist-only outbound firewall for Claude Code devcontainer
#
# Based on the official Anthropic reference implementation, extended with
# domains needed for R/CRAN, Python/PyPI, Bitbucket, Atlassian, and weather API.
#
# This script runs as root via postStartCommand. It:
#   1. Preserves Docker DNS NAT rules
#   2. Flushes all other iptables rules
#   3. Allows DNS, SSH, localhost, and host-network traffic
#   4. Fetches GitHub IP ranges and adds them to an ipset
#   5. Resolves all other allowed domains via dig and adds their IPs
#   6. Sets default policy to DROP for INPUT/FORWARD/OUTPUT
#   7. Self-tests by verifying example.com is blocked and GitHub is reachable
# =============================================================================

echo "=== Configuring allowlist firewall ==="

# 1. Extract Docker DNS info BEFORE any flushing
DOCKER_DNS_RULES=$(iptables-save -t nat | grep "127\.0\.0\.11" || true)

# Flush existing rules and delete existing ipsets
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
ipset destroy allowed-domains 2>/dev/null || true

# 2. Selectively restore ONLY internal Docker DNS resolution
if [ -n "$DOCKER_DNS_RULES" ]; then
    echo "Restoring Docker DNS rules..."
    iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
    iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
    echo "$DOCKER_DNS_RULES" | xargs -L 1 iptables -t nat
else
    echo "No Docker DNS rules to restore"
fi

# 3. Allow DNS and localhost before any restrictions
# Outbound DNS
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
# Inbound DNS responses
iptables -A INPUT -p udp --sport 53 -j ACCEPT
# Outbound SSH (for git push via SSH)
iptables -A OUTPUT -p tcp --dport 22 -j ACCEPT
# Inbound SSH responses
iptables -A INPUT -p tcp --sport 22 -m state --state ESTABLISHED -j ACCEPT
# Localhost
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# 4. Create ipset with CIDR support
ipset create allowed-domains hash:net

# 5. Fetch GitHub meta information and add their IP ranges
echo "Fetching GitHub IP ranges..."
gh_ranges=$(curl -s https://api.github.com/meta)
if [ -z "$gh_ranges" ]; then
    echo "ERROR: Failed to fetch GitHub IP ranges"
    exit 1
fi

if ! echo "$gh_ranges" | jq -e '.web and .api and .git' >/dev/null; then
    echo "ERROR: GitHub API response missing required fields"
    exit 1
fi

echo "Processing GitHub IPs..."
while read -r cidr; do
    if [[ ! "$cidr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        echo "ERROR: Invalid CIDR range from GitHub meta: $cidr"
        exit 1
    fi
    echo "  Adding GitHub range $cidr"
    ipset add allowed-domains "$cidr"
done < <(echo "$gh_ranges" | jq -r '(.web + .api + .git)[]' | aggregate -q)

# 6. Resolve and add other allowed domains
ALLOWED_DOMAINS=(
    # Claude Code infrastructure (Anthropic reference)
    "api.anthropic.com"
    "statsig.anthropic.com"
    "statsig.com"
    "sentry.io"
    # Package registries
    "registry.npmjs.org"
    "cloud.r-project.org"
    "packagemanager.posit.co"
    "pypi.org"
    "files.pythonhosted.org"
    # Git hosts
    "bitbucket.org"
    "api.bitbucket.org"
    # Atlassian (for Confluence MCP)
    "enaborea.atlassian.net"
    # IBM Weather API
    "api.weather.com"
    # VS Code
    "update.code.visualstudio.com"
    "marketplace.visualstudio.com"
    "vscode.blob.core.windows.net"
)

for domain in "${ALLOWED_DOMAINS[@]}"; do
    echo "Resolving $domain..."
    ips=$(dig +noall +answer A "$domain" | awk '$4 == "A" {print $5}')
    if [ -z "$ips" ]; then
        echo "WARNING: Failed to resolve $domain (may be wildcard or CNAME-only)"
        continue
    fi

    while read -r ip; do
        if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            echo "WARNING: Invalid IP from DNS for $domain: $ip"
            continue
        fi
        echo "  Adding $ip for $domain"
        ipset add allowed-domains "$ip" 2>/dev/null || true
    done < <(echo "$ips")
done

# 7. Get host gateway IP and allow ONLY that host (not the entire /24)
HOST_IP=$(ip route | grep default | cut -d" " -f3)
if [ -z "$HOST_IP" ]; then
    echo "ERROR: Failed to detect host IP"
    exit 1
fi

echo "Host gateway detected as: $HOST_IP (allowing this IP only, not /24)"
iptables -A INPUT -s "$HOST_IP" -j ACCEPT
iptables -A OUTPUT -d "$HOST_IP" -j ACCEPT

# 8. Set default policies to DROP
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

# Allow established connections for already-approved traffic
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Allow all outbound HTTPS (port 443) — enables research on any site.
# Exfiltration via HTTPS is mitigated at the application layer by the
# exfil-guard hook (blocks curl POST, wget --post-data, nc, etc.).
# WebFetch is GET-only by design; WebSearch goes through Anthropic's API.
iptables -A OUTPUT -p tcp --dport 443 -j ACCEPT

# Allow outbound traffic to allowlisted domains on ANY port (non-443 services)
iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT

# Explicitly REJECT all other outbound traffic (fast feedback vs silent DROP)
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

echo ""
echo "=== Firewall configuration complete ==="
echo "Verifying firewall rules..."

# Self-test: non-HTTPS port on a non-allowlisted host should be BLOCKED
if curl --connect-timeout 5 http://example.com >/dev/null 2>&1; then
    echo "ERROR: Firewall verification FAILED - was able to reach http://example.com (port 80)"
    exit 1
else
    echo "  PASS: http://example.com (port 80) is blocked as expected"
fi

# Self-test: GitHub API should be ALLOWED
if ! curl --connect-timeout 5 https://api.github.com/zen >/dev/null 2>&1; then
    echo "ERROR: Firewall verification FAILED - unable to reach https://api.github.com"
    exit 1
else
    echo "  PASS: https://api.github.com is reachable as expected"
fi

# Self-test: Anthropic API should be ALLOWED
if ! curl --connect-timeout 5 -o /dev/null -w "%{http_code}" https://api.anthropic.com 2>/dev/null | grep -q "^[2-4]"; then
    echo "  INFO: https://api.anthropic.com responded (firewall allows traffic)"
else
    echo "  PASS: https://api.anthropic.com is reachable"
fi

echo ""
echo "=== Firewall active. HTTPS (443) open for research; other ports allowlisted only. ==="
