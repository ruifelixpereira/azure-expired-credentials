#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# check-expiring-credentials.sh
#
# Lists Azure AD app registrations whose password or certificate credentials
# expire within a given number of days (default: 60 ≈ 2 months).
#
# Prerequisites:
#   - Azure CLI (az) installed and logged in
#   - jq installed
#   - Sufficient permissions (Directory.Read.All or equivalent)
#
# Usage:
#   ./check-expiring-credentials.sh [--days <N>] [--output <json|table>]
# ---------------------------------------------------------------------------

DAYS=60
OUTPUT_FORMAT="table"

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --days   <N>       Number of days to look ahead (default: 60)
  --output <format>  Output format: json or table (default: table)
  -h, --help         Show this help message
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --days)
      DAYS="$2"
      shift 2
      ;;
    --output)
      OUTPUT_FORMAT="$2"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

# Validate inputs
if ! [[ "$DAYS" =~ ^[0-9]+$ ]]; then
  echo "Error: --days must be a positive integer." >&2
  exit 1
fi

if [[ "$OUTPUT_FORMAT" != "json" && "$OUTPUT_FORMAT" != "table" ]]; then
  echo "Error: --output must be 'json' or 'table'." >&2
  exit 1
fi

# Compute date boundaries (portable across GNU and BSD date)
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
if date -u -d "+${DAYS} days" +%Y-%m-%dT%H:%M:%SZ &>/dev/null; then
  end_date=$(date -u -d "+${DAYS} days" +%Y-%m-%dT%H:%M:%SZ)
else
  # macOS / BSD date
  end_date=$(date -u -v+${DAYS}d +%Y-%m-%dT%H:%M:%SZ)
fi

echo "Checking for credentials expiring between ${now} and ${end_date} (${DAYS} days)..." >&2

# Fetch all app registrations and filter locally with jq
results=$(az ad app list --all -o json 2>/dev/null | jq --arg now "$now" --arg end "$end_date" '
  [.[] |
    {
      appId,
      displayName,
      expiringPasswords: [
        .passwordCredentials[]? |
        select(.endDateTime >= $now and .endDateTime <= $end) |
        {keyId, displayName, endDateTime}
      ],
      expiringCertificates: [
        .keyCredentials[]? |
        select(.endDateTime >= $now and .endDateTime <= $end) |
        {keyId, displayName, endDateTime}
      ]
    } |
    select((.expiringPasswords | length > 0) or (.expiringCertificates | length > 0))
  ]')

count=$(echo "$results" | jq 'length')

if [[ "$count" -eq 0 ]]; then
  echo "No credentials expiring in the next ${DAYS} days." >&2
  exit 0
fi

echo "Found ${count} app(s) with expiring credentials." >&2

if [[ "$OUTPUT_FORMAT" == "json" ]]; then
  echo "$results" | jq .
else
  # Table output
  printf "\n%-40s %-38s %-6s %-40s %s\n" "APP NAME" "APP ID" "TYPE" "KEY ID" "EXPIRES"
  printf "%s\n" "$(printf '=%.0s' {1..160})"

  echo "$results" | jq -r '
    .[] |
    .appId as $appId |
    .displayName as $name |
    (
      (.expiringPasswords[] | [$name, $appId, "Pass", .keyId, .endDateTime])
      ,
      (.expiringCertificates[] | [$name, $appId, "Cert", .keyId, .endDateTime])
    ) | @tsv
  ' | while IFS=$'\t' read -r name appId ctype keyId expires; do
    printf "%-40s %-38s %-6s %-40s %s\n" \
      "${name:0:40}" "$appId" "$ctype" "$keyId" "$expires"
  done
fi
