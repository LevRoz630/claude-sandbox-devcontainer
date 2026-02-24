#!/bin/bash
# Allowlist-only outbound firewall. Runs as root via postStartCommand.
# Based on the Anthropic reference, extended for R/CRAN, Python/PyPI, etc.
set -euo pipefail
IFS=$'\n\t'

echo "Configuring firewall..."

# Save Docker DNS NAT rules before flushing
DOCKER_DNS_RULES=$(iptables-save -t nat | grep "127\.0\.0\.11" || true)

iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
ipset destroy allowed-domains 2>/dev/null || true

# Fail-closed: set DROP policies immediately so any mid-script failure
# leaves the container locked down rather than wide open
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

# Restore Docker DNS
if [ -n "$DOCKER_DNS_RULES" ]; then
    iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
    iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
    echo "$DOCKER_DNS_RULES" | xargs -L 1 iptables -t nat
fi

# Allow traffic needed during setup (DNS resolution, GitHub API fetch, etc.)
# These rules stay in the final config — later rules append after them.
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A INPUT -p udp --sport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 443 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 22 -j ACCEPT
iptables -A INPUT -p tcp --sport 22 -m state --state ESTABLISHED -j ACCEPT
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# DNS-based threat filtering (auto-detect)
DNS_PRIMARY="${DNS_FILTER_PRIMARY:-auto}"
if [ "$DNS_PRIMARY" = "auto" ]; then
    if dig +short +timeout=3 github.com @9.9.9.9 >/dev/null 2>&1; then
        DNS_PRIMARY="9.9.9.9"
        echo "DNS filtering: enabled (Quad9 reachable)"
    else
        DNS_PRIMARY=""
        echo "DNS filtering: skipped (Quad9 unreachable — corporate network?)"
    fi
elif [ "$DNS_PRIMARY" = "none" ]; then
    DNS_PRIMARY=""
    echo "DNS filtering: disabled (DNS_FILTER_PRIMARY=none)"
else
    if [[ ! "$DNS_PRIMARY" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        echo "ERROR: DNS_FILTER_PRIMARY='$DNS_PRIMARY' is not a valid IPv4 address"
        exit 1
    fi
    echo "DNS filtering: using $DNS_PRIMARY"
fi

if [ -n "$DNS_PRIMARY" ]; then
    # DNAT catches explicit queries to external DNS servers (e.g. dig @8.8.8.8)
    iptables -t nat -A OUTPUT -p udp --dport 53 ! -d 127.0.0.11 -j DNAT --to-destination "${DNS_PRIMARY}:53"
    iptables -t nat -A OUTPUT -p tcp --dport 53 ! -d 127.0.0.11 -j DNAT --to-destination "${DNS_PRIMARY}:53"

    # Point the system resolver at the filtering DNS so standard resolution
    # (curl, wget, apt, etc. → /etc/resolv.conf → 127.0.0.11 → upstream)
    # also goes through the filtering provider
    cp /etc/resolv.conf /etc/resolv.conf.bak
    {
        echo "# DNS filtering active — managed by init-firewall.sh"
        echo "nameserver $DNS_PRIMARY"
        # Keep Docker DNS as fallback for container-internal names
        echo "nameserver 127.0.0.11"
    } > /etc/resolv.conf
fi

ipset create allowed-domains hash:net

# GitHub IP ranges
gh_ranges=$(curl -s https://api.github.com/meta)
if [ -z "$gh_ranges" ]; then
    echo "ERROR: Failed to fetch GitHub IP ranges"
    exit 1
fi
if ! echo "$gh_ranges" | jq -e '.web and .api and .git' >/dev/null; then
    echo "ERROR: GitHub API response missing required fields"
    exit 1
fi

while read -r cidr; do
    if [[ ! "$cidr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        echo "ERROR: Invalid CIDR range from GitHub meta: $cidr"
        exit 1
    fi
    ipset add allowed-domains "$cidr"
done < <(echo "$gh_ranges" | jq -r '(.web + .api + .git)[]' | aggregate -q)

# Resolve and add other allowed domains
ALLOWED_DOMAINS=(
    "api.anthropic.com"
    "statsig.anthropic.com"
    "sentry.io"
    "registry.npmjs.org"
    "cloud.r-project.org"
    "packagemanager.posit.co"
    "pypi.org"
    "files.pythonhosted.org"
    "bitbucket.org"
    "api.bitbucket.org"
    "update.code.visualstudio.com"
    "marketplace.visualstudio.com"
    "vscode.blob.core.windows.net"
    # 1Password CLI
    "my.1password.com"
    "my.1password.eu"
    "my.1password.ca"
    "cache.agilebits.com"
    "downloads.1password.com"
)

# User-defined extra domains (space-separated env var)
if [ -n "${FIREWALL_EXTRA_DOMAINS:-}" ]; then
    for domain in $FIREWALL_EXTRA_DOMAINS; do
        ALLOWED_DOMAINS+=("$domain")
    done
fi

for domain in "${ALLOWED_DOMAINS[@]}"; do
    ips=$(dig +noall +answer A "$domain" | awk '$4 == "A" {print $5}')
    if [ -z "$ips" ]; then
        echo "WARNING: Failed to resolve $domain"
        continue
    fi
    while read -r ip; do
        if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            echo "WARNING: Invalid IP from DNS for $domain: $ip"
            continue
        fi
        ipset add allowed-domains "$ip" 2>/dev/null || true
    done < <(echo "$ips")
done

# Host gateway
HOST_IP=$(ip route | grep default | cut -d" " -f3)
if [ -z "$HOST_IP" ]; then
    echo "ERROR: Failed to detect host IP"
    exit 1
fi
iptables -A INPUT -s "$HOST_IP" -j ACCEPT
iptables -A OUTPUT -d "$HOST_IP" -j ACCEPT

# Final rules: allowlisted IPs + reject everything else (DROP policies set above)
iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

# Self-test
if curl --connect-timeout 5 http://example.com >/dev/null 2>&1; then
    echo "ERROR: Firewall verification FAILED — http://example.com (port 80) should be blocked"
    exit 1
fi
if ! curl --connect-timeout 5 https://api.github.com/zen >/dev/null 2>&1; then
    echo "ERROR: Firewall verification FAILED — https://api.github.com should be reachable"
    exit 1
fi

echo "Firewall active. HTTPS (443) open; other ports allowlisted only."
