#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# test-check-expiring-credentials.sh
#
# Unit tests for check-expiring-credentials.sh using a mocked `az` command.
# No real Azure subscription needed.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_UNDER_TEST="${SCRIPT_DIR}/check-expiring-credentials.sh"
PASS=0
FAIL=0

# Colours for output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Colour

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

# Create a temp directory for the mock az script
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "${TMPDIR_TEST}"' EXIT

# ── mock data generation ──────────────────────────────────────────────────

# Dates relative to now
now_epoch=$(date -u +%s)
in_30_days=$(date -u -d @$((now_epoch + 30 * 86400)) +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || date -u -r $((now_epoch + 30 * 86400)) +%Y-%m-%dT%H:%M:%SZ)
in_90_days=$(date -u -d @$((now_epoch + 90 * 86400)) +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || date -u -r $((now_epoch + 90 * 86400)) +%Y-%m-%dT%H:%M:%SZ)
in_180_days=$(date -u -d @$((now_epoch + 180 * 86400)) +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || date -u -r $((now_epoch + 180 * 86400)) +%Y-%m-%dT%H:%M:%SZ)
past_30_days=$(date -u -d @$((now_epoch - 30 * 86400)) +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || date -u -r $((now_epoch - 30 * 86400)) +%Y-%m-%dT%H:%M:%SZ)

MOCK_DATA=$(cat <<ENDJSON
[
  {
    "appId": "aaaa-1111-bbbb-2222",
    "displayName": "App-Expiring-Soon-Password",
    "passwordCredentials": [
      {
        "keyId": "key-pass-30d",
        "displayName": "secret-30d",
        "endDateTime": "${in_30_days}"
      }
    ],
    "keyCredentials": []
  },
  {
    "appId": "cccc-3333-dddd-4444",
    "displayName": "App-Expiring-Soon-Cert",
    "passwordCredentials": [],
    "keyCredentials": [
      {
        "keyId": "key-cert-30d",
        "displayName": "cert-30d",
        "endDateTime": "${in_30_days}"
      }
    ]
  },
  {
    "appId": "eeee-5555-ffff-6666",
    "displayName": "App-Expiring-Later",
    "passwordCredentials": [
      {
        "keyId": "key-pass-180d",
        "displayName": "secret-180d",
        "endDateTime": "${in_180_days}"
      }
    ],
    "keyCredentials": []
  },
  {
    "appId": "gggg-7777-hhhh-8888",
    "displayName": "App-Already-Expired",
    "passwordCredentials": [
      {
        "keyId": "key-pass-expired",
        "displayName": "secret-expired",
        "endDateTime": "${past_30_days}"
      }
    ],
    "keyCredentials": []
  },
  {
    "appId": "iiii-9999-jjjj-0000",
    "displayName": "App-No-Credentials",
    "passwordCredentials": [],
    "keyCredentials": []
  },
  {
    "appId": "kkkk-1111-llll-2222",
    "displayName": "App-Mixed-Credentials",
    "passwordCredentials": [
      {
        "keyId": "key-pass-90d",
        "displayName": "secret-90d",
        "endDateTime": "${in_90_days}"
      }
    ],
    "keyCredentials": [
      {
        "keyId": "key-cert-30d-mixed",
        "displayName": "cert-30d-mixed",
        "endDateTime": "${in_30_days}"
      }
    ]
  }
]
ENDJSON
)

# ── create mock az ────────────────────────────────────────────────────────

create_mock_az() {
  local mock_data="$1"
  cat > "${TMPDIR_TEST}/az" <<EOFMOCK
#!/usr/bin/env bash
# Mock az CLI — returns canned JSON for "az ad app list"
if [[ "\$1" == "ad" && "\$2" == "app" && "\$3" == "list" ]]; then
  cat <<'JSONEOF'
${mock_data}
JSONEOF
else
  echo "mock az: unsupported command: \$*" >&2
  exit 1
fi
EOFMOCK
  chmod +x "${TMPDIR_TEST}/az"
}

run_script() {
  # Put mock az first in PATH
  PATH="${TMPDIR_TEST}:${PATH}" bash "${SCRIPT_UNDER_TEST}" "$@" 2>/dev/null
}

run_script_stderr() {
  PATH="${TMPDIR_TEST}:${PATH}" bash "${SCRIPT_UNDER_TEST}" "$@" 2>&1 1>/dev/null
}

run_script_all() {
  PATH="${TMPDIR_TEST}:${PATH}" bash "${SCRIPT_UNDER_TEST}" "$@" 2>&1
}

# ── tests ─────────────────────────────────────────────────────────────────

echo "=== Test Suite: check-expiring-credentials.sh ==="
echo ""

# ------------------------------------------------------------------
echo "Test 1: Default (60 days) — finds apps expiring within 60 days"
create_mock_az "$MOCK_DATA"
output=$(run_script --output json)
rc=$?
assert_exit_code 0 $rc "exits successfully"
assert_contains "$output" "App-Expiring-Soon-Password" "includes password app expiring in 30d"
assert_contains "$output" "App-Expiring-Soon-Cert" "includes cert app expiring in 30d"
assert_contains "$output" "key-cert-30d-mixed" "includes mixed app cert expiring in 30d"
assert_not_contains "$output" "App-Expiring-Later" "excludes app expiring in 180d"
assert_not_contains "$output" "App-Already-Expired" "excludes already-expired app"
assert_not_contains "$output" "App-No-Credentials" "excludes app with no credentials"
echo ""

# ------------------------------------------------------------------
echo "Test 2: --days 120 — also finds apps expiring in 90 days"
output=$(run_script --days 120 --output json)
rc=$?
assert_exit_code 0 $rc "exits successfully"
assert_contains "$output" "App-Expiring-Soon-Password" "still includes 30d app"
assert_contains "$output" "key-pass-90d" "includes password cred expiring in 90d"
assert_not_contains "$output" "App-Expiring-Later" "still excludes 180d app"
echo ""

# ------------------------------------------------------------------
echo "Test 3: --days 365 — finds everything not already expired"
output=$(run_script --days 365 --output json)
rc=$?
assert_exit_code 0 $rc "exits successfully"
assert_contains "$output" "App-Expiring-Soon-Password" "includes 30d app"
assert_contains "$output" "App-Expiring-Later" "includes 180d app"
assert_not_contains "$output" "App-Already-Expired" "still excludes already-expired"
echo ""

# ------------------------------------------------------------------
echo "Test 4: No expiring credentials — clean exit"
no_expire_data='[{"appId":"x","displayName":"Safe","passwordCredentials":[{"keyId":"k","displayName":"d","endDateTime":"'${in_180_days}'"}],"keyCredentials":[]}]'
create_mock_az "$no_expire_data"
output_stderr=$(run_script_stderr --days 7)
rc=$?
assert_exit_code 0 $rc "exits successfully"
assert_contains "$output_stderr" "No credentials expiring" "prints no-expiring message"
echo ""

# ------------------------------------------------------------------
echo "Test 5: Table output format runs without error"
create_mock_az "$MOCK_DATA"
output=$(run_script_all --output table)
rc=$?
assert_exit_code 0 $rc "exits successfully"
assert_contains "$output" "APP NAME" "table header present"
assert_contains "$output" "App-Expiring-Soon-Password" "table shows expiring app"
echo ""

# ------------------------------------------------------------------
echo "Test 6: Invalid --days value"
output=$(run_script_all --days abc 2>&1 || true)
assert_contains "$output" "must be a positive integer" "rejects non-numeric days"
echo ""

# ------------------------------------------------------------------
echo "Test 7: Invalid --output value"
output=$(run_script_all --output xml 2>&1 || true)
assert_contains "$output" "must be 'json' or 'table'" "rejects invalid output format"
echo ""

# ------------------------------------------------------------------
echo "Test 8: --help flag"
output=$(run_script_all --help 2>&1 || true)
assert_contains "$output" "Usage:" "shows usage info"
echo ""

# ── summary ───────────────────────────────────────────────────────────────

echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
