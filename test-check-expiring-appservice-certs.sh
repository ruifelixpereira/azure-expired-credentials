#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# test-check-expiring-appservice-certs.sh
#
# Unit tests for check-expiring-appservice-certs.sh using a mocked `az`.
# No real Azure subscription needed.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_UNDER_TEST="${SCRIPT_DIR}/check-expiring-appservice-certs.sh"
PASS=0
FAIL=0

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# ── helpers ────────────────────────────────────────────────────────────────

assert_exit_code() {
  local expected="$1" actual="$2" label="$3"
  if [[ "$actual" -eq "$expected" ]]; then
    echo -e "  ${GREEN}PASS${NC}: ${label}"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: ${label} (expected exit ${expected}, got ${actual})"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  if echo "$haystack" | grep -qF -- "$needle"; then
    echo -e "  ${GREEN}PASS${NC}: ${label}"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: ${label} — expected output to contain '${needle}'"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" label="$3"
  if ! echo "$haystack" | grep -qF -- "$needle"; then
    echo -e "  ${GREEN}PASS${NC}: ${label}"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: ${label} — expected output NOT to contain '${needle}'"
    FAIL=$((FAIL + 1))
  fi
}

TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "${TMPDIR_TEST}"' EXIT

# ── mock data generation ──────────────────────────────────────────────────

now_epoch=$(date -u +%s)
in_15_days=$(date -u -d @$((now_epoch + 15 * 86400)) +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || date -u -r $((now_epoch + 15 * 86400)) +%Y-%m-%dT%H:%M:%SZ)
in_45_days=$(date -u -d @$((now_epoch + 45 * 86400)) +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || date -u -r $((now_epoch + 45 * 86400)) +%Y-%m-%dT%H:%M:%SZ)
in_90_days=$(date -u -d @$((now_epoch + 90 * 86400)) +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || date -u -r $((now_epoch + 90 * 86400)) +%Y-%m-%dT%H:%M:%SZ)
in_180_days=$(date -u -d @$((now_epoch + 180 * 86400)) +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || date -u -r $((now_epoch + 180 * 86400)) +%Y-%m-%dT%H:%M:%SZ)
past_30_days=$(date -u -d @$((now_epoch - 30 * 86400)) +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || date -u -r $((now_epoch - 30 * 86400)) +%Y-%m-%dT%H:%M:%SZ)

MOCK_CERTS=$(cat <<ENDJSON
{"value": [
  {
    "name": "cert-expiring-15d",
    "id": "/subscriptions/sub-aaaa-1111/resourceGroups/rg-web-prod/providers/Microsoft.Web/certificates/cert-expiring-15d",
    "properties": {
      "subjectName": "*.myapp.com",
      "thumbprint": "AAAA1111BBBB2222CCCC3333DDDD4444EEEE5555",
      "expirationDate": "${in_15_days}"
    }
  },
  {
    "name": "cert-expiring-45d",
    "id": "/subscriptions/sub-aaaa-1111/resourceGroups/rg-web-staging/providers/Microsoft.Web/certificates/cert-expiring-45d",
    "properties": {
      "subjectName": "staging.myapp.com",
      "thumbprint": "FFFF6666GGGG7777HHHH8888IIII9999JJJJ0000",
      "expirationDate": "${in_45_days}"
    }
  },
  {
    "name": "cert-expiring-90d",
    "id": "/subscriptions/sub-aaaa-1111/resourceGroups/rg-web-dev/providers/Microsoft.Web/certificates/cert-expiring-90d",
    "properties": {
      "subjectName": "dev.myapp.com",
      "thumbprint": "KKKK1111LLLL2222MMMM3333NNNN4444OOOO5555",
      "expirationDate": "${in_90_days}"
    }
  },
  {
    "name": "cert-expiring-180d",
    "id": "/subscriptions/sub-aaaa-1111/resourceGroups/rg-web-test/providers/Microsoft.Web/certificates/cert-expiring-180d",
    "properties": {
      "subjectName": "test.myapp.com",
      "thumbprint": "PPPP6666QQQQ7777RRRR8888SSSS9999TTTT0000",
      "expirationDate": "${in_180_days}"
    }
  },
  {
    "name": "cert-already-expired",
    "id": "/subscriptions/sub-aaaa-1111/resourceGroups/rg-web-old/providers/Microsoft.Web/certificates/cert-already-expired",
    "properties": {
      "subjectName": "old.myapp.com",
      "thumbprint": "UUUU1111VVVV2222WWWW3333XXXX4444YYYY5555",
      "expirationDate": "${past_30_days}"
    }
  }
]}
ENDJSON
)

MOCK_SUBSCRIPTIONS='[{"id":"sub-aaaa-1111","state":"Enabled"},{"id":"sub-bbbb-2222","state":"Enabled"}]'

# ── create mock az ────────────────────────────────────────────────────────

create_mock_az() {
  local cert_data="$1"
  local sub_data="${2:-$MOCK_SUBSCRIPTIONS}"
  cat > "${TMPDIR_TEST}/az" <<EOFMOCK
#!/usr/bin/env bash
# Mock az CLI for App Service cert tests
if [[ "\$1" == "account" && "\$2" == "list" ]]; then
  cat <<'SUBJSON'
${sub_data}
SUBJSON
elif [[ "\$1" == "rest" ]]; then
  cat <<'CERTJSON'
${cert_data}
CERTJSON
else
  echo "mock az: unsupported command: \$*" >&2
  exit 1
fi
EOFMOCK
  chmod +x "${TMPDIR_TEST}/az"
}

run_script() {
  PATH="${TMPDIR_TEST}:${PATH}" bash "${SCRIPT_UNDER_TEST}" "$@" 2>/dev/null
}

run_script_stderr() {
  PATH="${TMPDIR_TEST}:${PATH}" bash "${SCRIPT_UNDER_TEST}" "$@" 2>&1 1>/dev/null
}

run_script_all() {
  PATH="${TMPDIR_TEST}:${PATH}" bash "${SCRIPT_UNDER_TEST}" "$@" 2>&1
}

# ── tests ─────────────────────────────────────────────────────────────────

echo "=== Test Suite: check-expiring-appservice-certs.sh ==="
echo ""

# ------------------------------------------------------------------
echo "Test 1: Default (60 days) — finds certs expiring within 60 days"
create_mock_az "$MOCK_CERTS"
output=$(run_script --output json --subscription sub-aaaa-1111)
rc=$?
assert_exit_code 0 $rc "exits successfully"
assert_contains "$output" "cert-expiring-15d" "includes cert expiring in 15d"
assert_contains "$output" "cert-expiring-45d" "includes cert expiring in 45d"
assert_not_contains "$output" "cert-expiring-90d" "excludes cert expiring in 90d"
assert_not_contains "$output" "cert-expiring-180d" "excludes cert expiring in 180d"
assert_not_contains "$output" "cert-already-expired" "excludes already-expired cert"
echo ""

# ------------------------------------------------------------------
echo "Test 2: --days 120 — also includes 90-day cert"
output=$(run_script --days 120 --output json --subscription sub-aaaa-1111)
rc=$?
assert_exit_code 0 $rc "exits successfully"
assert_contains "$output" "cert-expiring-15d" "includes 15d cert"
assert_contains "$output" "cert-expiring-45d" "includes 45d cert"
assert_contains "$output" "cert-expiring-90d" "includes 90d cert"
assert_not_contains "$output" "cert-expiring-180d" "excludes 180d cert"
assert_not_contains "$output" "cert-already-expired" "excludes already-expired"
echo ""

# ------------------------------------------------------------------
echo "Test 3: --days 365 — finds everything not already expired"
output=$(run_script --days 365 --output json --subscription sub-aaaa-1111)
rc=$?
assert_exit_code 0 $rc "exits successfully"
assert_contains "$output" "cert-expiring-15d" "includes 15d cert"
assert_contains "$output" "cert-expiring-180d" "includes 180d cert"
assert_not_contains "$output" "cert-already-expired" "still excludes expired"
echo ""

# ------------------------------------------------------------------
echo "Test 4: No expiring certs — clean exit"
no_expire='{"value":[{"name":"safe-cert","id":"/subscriptions/sub-aaaa-1111/resourceGroups/rg/providers/Microsoft.Web/certificates/safe-cert","properties":{"subjectName":"safe.com","thumbprint":"ABCD","expirationDate":"'${in_180_days}'"}}]}'
create_mock_az "$no_expire"
output_stderr=$(run_script_stderr --days 7 --subscription sub-aaaa-1111)
rc=$?
assert_exit_code 0 $rc "exits successfully"
assert_contains "$output_stderr" "No App Service certificates expiring" "prints no-expiring message"
echo ""

# ------------------------------------------------------------------
echo "Test 5: Table output format"
create_mock_az "$MOCK_CERTS"
output=$(run_script_all --output table --subscription sub-aaaa-1111)
rc=$?
assert_exit_code 0 $rc "exits successfully"
assert_contains "$output" "CERT NAME" "table header present"
assert_contains "$output" "cert-expiring-15d" "table shows expiring cert"
assert_contains "$output" "*.myapp.com" "table shows subject name"
echo ""

# ------------------------------------------------------------------
echo "Test 6: JSON output contains expected fields"
create_mock_az "$MOCK_CERTS"
output=$(run_script --output json --subscription sub-aaaa-1111)
assert_contains "$output" "thumbprint" "JSON has thumbprint field"
assert_contains "$output" "resourceGroup" "JSON has resourceGroup field"
assert_contains "$output" "subjectName" "JSON has subjectName field"
assert_contains "$output" "expirationDate" "JSON has expirationDate field"
echo ""

# ------------------------------------------------------------------
echo "Test 7: Multi-subscription scan"
create_mock_az "$MOCK_CERTS"
output=$(run_script --output json)
rc=$?
assert_exit_code 0 $rc "exits successfully"
# Each subscription returns the same mock data, so we get duplicates — that's fine for the test
assert_contains "$output" "cert-expiring-15d" "finds certs across subscriptions"
echo ""

# ------------------------------------------------------------------
echo "Test 8: Invalid --days value"
output=$(run_script_all --days abc 2>&1 || true)
assert_contains "$output" "must be a positive integer" "rejects non-numeric days"
echo ""

# ------------------------------------------------------------------
echo "Test 9: Invalid --output value"
output=$(run_script_all --output xml 2>&1 || true)
assert_contains "$output" "must be 'json' or 'table'" "rejects invalid output format"
echo ""

# ------------------------------------------------------------------
echo "Test 10: --help flag"
output=$(run_script_all --help 2>&1 || true)
assert_contains "$output" "Usage:" "shows usage info"
assert_contains "$output" "--subscription" "help mentions subscription flag"
echo ""

# ── summary ───────────────────────────────────────────────────────────────

echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
