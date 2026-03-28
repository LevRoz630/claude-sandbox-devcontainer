#!/bin/bash
# Shared test framework. Source at the top of each test script.
set -uo pipefail

PASS=0; FAIL=0; SKIP=0
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "  SKIP: $1"; SKIP=$((SKIP + 1)); }
section() { echo ""; echo "=== $1 ==="; }

results() {
    echo ""
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    [[ $FAIL -gt 0 ]] && exit 1 || exit 0
}
