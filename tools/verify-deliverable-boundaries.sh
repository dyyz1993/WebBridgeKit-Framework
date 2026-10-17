#!/bin/bash
# Verify that the WebBridgeKit SDK and AppTemplate starter stay clean and decoupled from product apps.

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

PASS=0
FAIL=0

pass() {
    echo "  PASS  $1"
    PASS=$((PASS + 1))
}

fail() {
    echo "  FAIL  $1"
    if [ -n "${2:-}" ]; then
        echo "$2" | sed 's/^/         /'
    fi
    FAIL=$((FAIL + 1))
}

echo ""
echo "=== Framework Deliverable Boundary Verification ==="
echo ""

CREDENTIAL_MATCHES=$(rg -n -i \
    --glob '*.swift' \
    --glob '*.plist' \
    --glob '*.json' \
    'test_key|-----BEGIN ([A-Z ]+ )?PRIVATE KEY-----|BarkChannel\([^)]*key:[[:space:]]*"[^"]+"|barkDeviceKey:[[:space:]]*"[^"]+"|((api|webhook)[_-]?(key|secret)|apns[_-]?(token|key)|device[_-]?token|private[_-]?key)[[:space:]]*[:=][[:space:]]*"[^"[:space:]][^"]*"' \
    AppTemplate/Sources 2>/dev/null || true)
if [ -z "$CREDENTIAL_MATCHES" ]; then
    pass "AppTemplate contains no literal credentials or private keys"
else
    fail "AppTemplate contains no literal credentials or private keys" "$CREDENTIAL_MATCHES"
fi

if awk '
    /^schemes:/ { in_schemes = 1; next }
    in_schemes && /^[^[:space:]]/ { in_schemes = 0 }
    in_schemes && /^  AppTemplate:$/ { found = 1 }
    END { exit(found ? 0 : 1) }
' project.yml; then
    pass "AppTemplate scheme is declared in project.yml"
else
    fail "AppTemplate scheme is declared in project.yml" "Missing schemes.AppTemplate"
fi

if ! grep -q "DREL_CONTAINER_ONLY" project.yml; then
    pass "Framework project.yml is decoupled from DREL_CONTAINER_ONLY product flag"
else
    fail "Framework project.yml is decoupled from DREL_CONTAINER_ONLY product flag"
fi

SDK_PRODUCT_REFS=$(rg -n \
    'import[[:space:]]+SuperApp|SuperApp/Sources|import[[:space:]]+Kingfisher' \
    Sources --glob '*.swift' 2>/dev/null || true)
if [ -z "$SDK_PRODUCT_REFS" ]; then
    pass "SDK sources do not import SuperApp product code or product-only pods"
else
    fail "SDK sources do not import SuperApp product code or product-only pods" "$SDK_PRODUCT_REFS"
fi

if [ ! -d "SuperApp" ] && [ ! -d "NotificationServiceExtension" ] && [ ! -d "Server" ]; then
    pass "Product application targets and server are cleanly separated from framework repo"
else
    fail "Product application targets and server are cleanly separated from framework repo"
fi

if rg -q -F 'WebBridgeKit.shared.initialize()' README.md AppTemplate/Sources; then
    fail "Starter uses the current SDK bootstrap API" \
        "Replace stale WebBridgeKit.shared.initialize() with WebBridgeKitManager.shared.initialize()"
else
    pass "Starter uses the current SDK bootstrap API"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
