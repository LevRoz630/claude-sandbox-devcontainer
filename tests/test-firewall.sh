#!/bin/bash
# Firewall validation tests. Run after init-firewall.sh inside the container.
set -uo pipefail

PASS=0; FAIL=0; SKIP=0
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "  SKIP: $1"; SKIP=$((SKIP + 1)); }
section() { echo ""; echo "=== $1 ==="; }

section "1. Firewall Rules Active"

RULE_COUNT=$(sudo iptables -L OUTPUT -n 2>/dev/null | wc -l)
if [[ "$RULE_COUNT" -gt 3 ]]; then
    pass "iptables OUTPUT chain has rules ($RULE_COUNT lines)"
else
    fail "iptables OUTPUT chain appears empty (run init-firewall.sh first)"
    echo ""
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped (ABORTED)"
    exit 1
fi

INPUT_POLICY=$(sudo iptables -L INPUT 2>/dev/null | head -1 | grep -o 'policy [A-Z]*' | awk '{print $2}')
OUTPUT_POLICY=$(sudo iptables -L OUTPUT 2>/dev/null | head -1 | grep -o 'policy [A-Z]*' | awk '{print $2}')
FORWARD_POLICY=$(sudo iptables -L FORWARD 2>/dev/null | head -1 | grep -o 'policy [A-Z]*' | awk '{print $2}')

[[ "$INPUT_POLICY" == "DROP" ]] && pass "INPUT policy is DROP" || fail "INPUT policy is $INPUT_POLICY (expected DROP)"
[[ "$OUTPUT_POLICY" == "DROP" ]] && pass "OUTPUT policy is DROP" || fail "OUTPUT policy is $OUTPUT_POLICY (expected DROP)"
[[ "$FORWARD_POLICY" == "DROP" ]] && pass "FORWARD policy is DROP" || fail "FORWARD policy is $FORWARD_POLICY (expected DROP)"

if sudo ipset list allowed-domains >/dev/null 2>&1; then
    IPSET_SIZE=$(sudo ipset list allowed-domains 2>/dev/null | grep "Number of entries" | awk '{print $NF}')
    pass "ipset 'allowed-domains' exists with $IPSET_SIZE entries"
else
    fail "ipset 'allowed-domains' not found"
fi

section "2. Blocked Destinations"

for domain in example.com evil.com google.com facebook.com aws.amazon.com; do
    if curl --connect-timeout 3 -s "https://$domain" >/dev/null 2>&1; then
        fail "$domain is reachable (should be blocked)"
    else
        pass "$domain is blocked"
    fi
done

section "3. Allowed Destinations"

curl --connect-timeout 5 -s "https://api.github.com/zen" >/dev/null 2>&1 && pass "api.github.com is reachable" || fail "api.github.com is blocked"

for domain in api.anthropic.com registry.npmjs.org cloud.r-project.org pypi.org bitbucket.org; do
    HTTP_CODE=$(curl --connect-timeout 5 -s -o /dev/null -w "%{http_code}" "https://$domain" 2>/dev/null || echo "000")
    [[ "$HTTP_CODE" != "000" ]] && pass "$domain is reachable (HTTP $HTTP_CODE)" || fail "$domain connection failed"
done

section "4. DNS"

dig +short github.com 2>/dev/null | head -1 | grep -qE '^[0-9]+\.' && pass "DNS resolution works" || fail "DNS resolution broken"

section "5. Localhost"

python3 -m http.server 18923 --bind 127.0.0.1 &>/dev/null &
PY_PID=$!
sleep 1
curl --connect-timeout 2 -s "http://127.0.0.1:18923" >/dev/null 2>&1 && pass "Localhost connectivity works" || fail "Localhost connectivity broken"
kill $PY_PID 2>/dev/null || true
wait $PY_PID 2>/dev/null || true

section "6. SSH Outbound (port 22)"

if timeout 3 bash -c "echo >/dev/tcp/github.com/22" 2>/dev/null; then
    pass "SSH to github.com:22 is allowed"
else
    skip "SSH to github.com:22 timed out (may be network issue)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[[ $FAIL -gt 0 ]] && exit 1 || exit 0
