#!/bin/bash
# =============================================================================
# Firewall validation test suite
#
# Must be run AFTER init-firewall.sh has been executed (requires root for setup).
# Run inside the container with NET_ADMIN + NET_RAW capabilities.
#
# Usage:
#   sudo /usr/local/bin/init-firewall.sh   # First, set up firewall
#   bash /workspace/tests/test-firewall.sh  # Then, run tests
# =============================================================================

set -uo pipefail

PASS=0
FAIL=0
SKIP=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "  SKIP: $1"; SKIP=$((SKIP + 1)); }

section() { echo ""; echo "=== $1 ==="; }

# ---------------------------------------------------------------------------
section "1. Firewall Rules Active"
# ---------------------------------------------------------------------------

# Check that iptables has rules loaded
RULE_COUNT=$(sudo iptables -L OUTPUT -n 2>/dev/null | wc -l)
if [[ "$RULE_COUNT" -gt 3 ]]; then
    pass "iptables OUTPUT chain has rules ($RULE_COUNT lines)"
else
    fail "iptables OUTPUT chain appears empty (firewall not active?)"
    echo "  Hint: Run 'sudo /usr/local/bin/init-firewall.sh' first"
    echo ""
    echo "==========================================="
    echo "  Results: $PASS passed, $FAIL failed, $SKIP skipped"
    echo "  ABORTING: Firewall not active"
    echo "==========================================="
    exit 1
fi

# Check default policies
INPUT_POLICY=$(sudo iptables -L INPUT 2>/dev/null | head -1 | grep -o 'policy [A-Z]*' | awk '{print $2}')
OUTPUT_POLICY=$(sudo iptables -L OUTPUT 2>/dev/null | head -1 | grep -o 'policy [A-Z]*' | awk '{print $2}')
FORWARD_POLICY=$(sudo iptables -L FORWARD 2>/dev/null | head -1 | grep -o 'policy [A-Z]*' | awk '{print $2}')

[[ "$INPUT_POLICY" == "DROP" ]] && pass "INPUT policy is DROP" || fail "INPUT policy is $INPUT_POLICY (expected DROP)"
[[ "$OUTPUT_POLICY" == "DROP" ]] && pass "OUTPUT policy is DROP" || fail "OUTPUT policy is $OUTPUT_POLICY (expected DROP)"
[[ "$FORWARD_POLICY" == "DROP" ]] && pass "FORWARD policy is DROP" || fail "FORWARD policy is $FORWARD_POLICY (expected DROP)"

# Check ipset exists
if sudo ipset list allowed-domains >/dev/null 2>&1; then
    IPSET_SIZE=$(sudo ipset list allowed-domains 2>/dev/null | grep "Number of entries" | awk '{print $NF}')
    pass "ipset 'allowed-domains' exists with $IPSET_SIZE entries"
else
    fail "ipset 'allowed-domains' not found"
fi

# ---------------------------------------------------------------------------
section "2. Blocked Destinations (should fail)"
# ---------------------------------------------------------------------------

BLOCKED_DOMAINS=(
    "example.com"
    "evil.com"
    "google.com"
    "facebook.com"
    "aws.amazon.com"
)

for domain in "${BLOCKED_DOMAINS[@]}"; do
    if curl --connect-timeout 3 -s "https://$domain" >/dev/null 2>&1; then
        fail "$domain is REACHABLE (should be blocked)"
    else
        pass "$domain is blocked"
    fi
done

# ---------------------------------------------------------------------------
section "3. Allowed Destinations (should succeed)"
# ---------------------------------------------------------------------------

# GitHub API (IPs fetched from /meta)
if curl --connect-timeout 5 -s "https://api.github.com/zen" >/dev/null 2>&1; then
    pass "api.github.com is reachable"
else
    fail "api.github.com is blocked (should be allowed)"
fi

# Anthropic API (may return 401 without auth, but connection should work)
HTTP_CODE=$(curl --connect-timeout 5 -s -o /dev/null -w "%{http_code}" "https://api.anthropic.com" 2>/dev/null || echo "000")
if [[ "$HTTP_CODE" != "000" ]]; then
    pass "api.anthropic.com is reachable (HTTP $HTTP_CODE)"
else
    fail "api.anthropic.com connection failed (blocked by firewall?)"
fi

# npm registry
HTTP_CODE=$(curl --connect-timeout 5 -s -o /dev/null -w "%{http_code}" "https://registry.npmjs.org" 2>/dev/null || echo "000")
if [[ "$HTTP_CODE" != "000" ]]; then
    pass "registry.npmjs.org is reachable (HTTP $HTTP_CODE)"
else
    fail "registry.npmjs.org connection failed"
fi

# CRAN
HTTP_CODE=$(curl --connect-timeout 5 -s -o /dev/null -w "%{http_code}" "https://cloud.r-project.org" 2>/dev/null || echo "000")
if [[ "$HTTP_CODE" != "000" ]]; then
    pass "cloud.r-project.org is reachable (HTTP $HTTP_CODE)"
else
    fail "cloud.r-project.org connection failed"
fi

# PyPI
HTTP_CODE=$(curl --connect-timeout 5 -s -o /dev/null -w "%{http_code}" "https://pypi.org" 2>/dev/null || echo "000")
if [[ "$HTTP_CODE" != "000" ]]; then
    pass "pypi.org is reachable (HTTP $HTTP_CODE)"
else
    fail "pypi.org connection failed"
fi

# Bitbucket
HTTP_CODE=$(curl --connect-timeout 5 -s -o /dev/null -w "%{http_code}" "https://bitbucket.org" 2>/dev/null || echo "000")
if [[ "$HTTP_CODE" != "000" ]]; then
    pass "bitbucket.org is reachable (HTTP $HTTP_CODE)"
else
    fail "bitbucket.org connection failed"
fi

# ---------------------------------------------------------------------------
section "4. DNS Still Works"
# ---------------------------------------------------------------------------

if dig +short github.com 2>/dev/null | head -1 | grep -qE '^[0-9]+\.'; then
    pass "DNS resolution works (github.com)"
else
    fail "DNS resolution broken"
fi

# ---------------------------------------------------------------------------
section "5. Localhost Still Works"
# ---------------------------------------------------------------------------

# Start a quick HTTP server and test connectivity
python3 -m http.server 18923 --bind 127.0.0.1 &>/dev/null &
PY_PID=$!
sleep 1

if curl --connect-timeout 2 -s "http://127.0.0.1:18923" >/dev/null 2>&1; then
    pass "Localhost connectivity works"
else
    fail "Localhost connectivity broken"
fi

kill $PY_PID 2>/dev/null || true
wait $PY_PID 2>/dev/null || true

# ---------------------------------------------------------------------------
section "6. SSH Outbound (port 22)"
# ---------------------------------------------------------------------------

# Test that port 22 is allowed (for git SSH operations)
# We just check that the connection isn't immediately rejected by iptables
if timeout 3 bash -c "echo >/dev/tcp/github.com/22" 2>/dev/null; then
    pass "SSH to github.com:22 is allowed"
else
    skip "SSH to github.com:22 timed out (may be network, not firewall)"
fi

# ---------------------------------------------------------------------------
echo ""
echo "==========================================="
echo "  Results: $PASS passed, $FAIL failed, $SKIP skipped"
echo "==========================================="

if [[ $FAIL -gt 0 ]]; then
    exit 1
else
    exit 0
fi
