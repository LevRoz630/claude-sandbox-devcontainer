#!/bin/bash
# Allowlist-only outbound firewall. Runs as root via postStartCommand.
set -euo pipefail
IFS=$'\n\t'

echo "Configuring firewall..."

# Preserve Docker DNS NAT before flushing
DOCKER_DNS_RULES=$(iptables-save -t nat | grep "127\.0\.0\.11" || true)

iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
ipset destroy allowed-domains 2>/dev/null || true

# Fail-closed: DROP first, then open what's needed
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

# IPv6: DROP everything (prevent firewall bypass via IPv6)
ip6tables -P INPUT DROP 2>/dev/null || true
ip6tables -P FORWARD DROP 2>/dev/null || true
ip6tables -P OUTPUT DROP 2>/dev/null || true
ip6tables -A INPUT -i lo -j ACCEPT 2>/dev/null || true
ip6tables -A OUTPUT -o lo -j ACCEPT 2>/dev/null || true

if [ -n "$DOCKER_DNS_RULES" ]; then
    iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
    iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
    echo "$DOCKER_DNS_RULES" | xargs -L 1 iptables -t nat
fi

iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A INPUT -p udp --sport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 443 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 22 -j ACCEPT
iptables -A INPUT -p tcp --sport 22 -m state --state ESTABLISHED -j ACCEPT
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# DNS threat filtering (auto-detect Quad9)
DNS_PRIMARY="${DNS_FILTER_PRIMARY:-auto}"
if [ "$DNS_PRIMARY" = "auto" ]; then
    if dig +short +timeout=3 github.com @9.9.9.9 >/dev/null 2>&1; then
        DNS_PRIMARY="9.9.9.9"
        echo "DNS filtering: Quad9"
    else
        DNS_PRIMARY=""
        echo "DNS filtering: skipped (Quad9 unreachable)"
    fi
elif [ "$DNS_PRIMARY" = "none" ]; then
    DNS_PRIMARY=""
    echo "DNS filtering: disabled"
else
    if [[ ! "$DNS_PRIMARY" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        echo "ERROR: DNS_FILTER_PRIMARY='$DNS_PRIMARY' is not a valid IPv4 address"
        exit 1
    fi
    echo "DNS filtering: $DNS_PRIMARY"
fi

if [ -n "$DNS_PRIMARY" ]; then
    iptables -t nat -A OUTPUT -p udp --dport 53 ! -d 127.0.0.11 -j DNAT --to-destination "${DNS_PRIMARY}:53"
    iptables -t nat -A OUTPUT -p tcp --dport 53 ! -d 127.0.0.11 -j DNAT --to-destination "${DNS_PRIMARY}:53"

    cp /etc/resolv.conf /etc/resolv.conf.bak
    {
        echo "nameserver $DNS_PRIMARY"
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
        echo "ERROR: Invalid CIDR from GitHub meta: $cidr"
        exit 1
    fi
    ipset add allowed-domains "$cidr"
done < <(echo "$gh_ranges" | jq -r '(.web + .api + .git)[]' | aggregate -q)

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
    "my.1password.com"
    "my.1password.eu"
    "my.1password.ca"
    "cache.agilebits.com"
    "downloads.1password.com"
)

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
            echo "WARNING: Invalid IP for $domain: $ip"
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

iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

# Self-test
if curl --connect-timeout 5 http://example.com >/dev/null 2>&1; then
    echo "ERROR: Firewall FAILED — port 80 should be blocked"
    exit 1
fi
if ! curl --connect-timeout 5 https://api.github.com/zen >/dev/null 2>&1; then
    echo "ERROR: Firewall FAILED — GitHub should be reachable"
    exit 1
fi

echo "Firewall active."
