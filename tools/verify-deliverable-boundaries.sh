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

CREDENTIAL_MATCHES=$(git ls-files -z | python3 -c '
import collections
import math
import os
import re
import sys

private_key_pattern = re.compile(r"-----BEGIN[[:space:]]+([A-Z ]+ )?PRIVATE KEY[[:space:]]*-----", re.IGNORECASE)
prefix_parts = (
    ("gh", "p_"),
    ("gh", "o_"),
    ("s", "k-"),
    ("AK", "IA"),
    ("xox", "b-"),
    ("xox", "a-"),
    ("xox", "p-"),
    ("xox", "r-"),
    ("xox", "s-"),
)
token_prefixes = tuple(left + right for left, right in prefix_parts)
credential_pattern = re.compile(
    r"(?<![A-Za-z0-9_-])(?:"
    + "|".join(re.escape(prefix) for prefix in token_prefixes)
    + r")",
    re.IGNORECASE,
)
long_token_pattern = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]{39,}")

def entropy(value):
    if not value:
        return 0.0
    counts = collections.Counter(value)
    return sum((count / len(value)) * math.log2(len(value) / count) for count in counts.values())

for filename in sys.stdin.buffer.read().split(b"\0"):
    if not filename:
        continue
    path = os.fsdecode(filename)
    try:
        data = open(path, "rb").read()
    except OSError:
        continue
    text = data.decode("utf-8", errors="ignore")
    for match in credential_pattern.finditer(text):
        line = text.count("\n", 0, match.start()) + 1
        print(f"{path}:{line}: credential pattern")

    if b"\0" in data:
        continue
    for match in long_token_pattern.finditer(text):
        candidate = match.group(0)
        if entropy(candidate) >= 4.8 and "abcdefghijklmnopqrstuvwxyz" not in candidate:
            line = text.count("\n", 0, match.start()) + 1
            print(f"{path}:{line}: high-entropy token")
' 2>/dev/null || true)
if [ -z "$CREDENTIAL_MATCHES" ]; then
    pass "Repository contains no literal credentials, private keys, or high-entropy tokens"
else
    fail "Repository contains no literal credentials, private keys, or high-entropy tokens" "$CREDENTIAL_MATCHES"
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
