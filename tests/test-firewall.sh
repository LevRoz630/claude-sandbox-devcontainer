#!/bin/bash
# Firewall validation tests. Run after init-firewall.sh inside the container.
# Tests use network behavior (curl/dig), not sudo iptables, because sudoers
# only allows init-firewall.sh.
set -uo pipefail

PASS=0; FAIL=0; SKIP=0
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "  SKIP: $1"; SKIP=$((SKIP + 1)); }
section() { echo ""; echo "=== $1 ==="; }

section "1. Firewall Active (behavioral check)"

# If HTTP (port 80) is blocked and HTTPS works, the firewall is running.
# Without the firewall, both would succeed.
if curl --connect-timeout 3 -s "http://example.com" >/dev/null 2>&1; then
    fail "HTTP (port 80) is open — firewall may not be running"
    echo ""
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped (ABORTED)"
    exit 1
else
    pass "HTTP (port 80) is blocked"
fi

if curl --connect-timeout 5 -s "https://api.github.com/zen" >/dev/null 2>&1; then
    pass "HTTPS (port 443) works — firewall is active and allowing HTTPS"
else
    fail "HTTPS is also blocked — firewall may be misconfigured or network is down"
    echo ""
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped (ABORTED)"
    exit 1
fi

section "2. Blocked Traffic (non-HTTPS ports)"

# HTTPS (443) is open to all domains by design, so we test HTTP (port 80)
# which should be blocked for everything.
for domain in example.com evil.com google.com facebook.com aws.amazon.com; do
    if curl --connect-timeout 3 -s "http://$domain" >/dev/null 2>&1; then
        fail "$domain reachable on HTTP (port 80 should be blocked)"
    else
        pass "$domain blocked on HTTP (port 80)"
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

section "4b. DNS Filtering"

# Check if /etc/resolv.conf points to a known filtering DNS (set by init-firewall.sh)
FILTERING_DNS=$(grep -oE '^nameserver (9\.9\.9\.9|1\.1\.1\.2|1\.0\.0\.2)' /etc/resolv.conf 2>/dev/null | head -1 | awk '{print $2}')
if [[ -n "$FILTERING_DNS" ]]; then
    pass "DNS filtering active (resolv.conf → $FILTERING_DNS)"
else
    skip "DNS filtering not active (corporate network or disabled)"
fi

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
