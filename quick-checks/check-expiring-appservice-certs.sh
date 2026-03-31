#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# check-expiring-appservice-certs.sh
#
# Lists App Service SSL/TLS certificates that expire within a given number
# of days (default: 60 ≈ 2 months). Scans all subscriptions the caller has
# access to, or a single subscription if --subscription is provided.
#
# Prerequisites:
#   - Azure CLI (az) installed and logged in
#   - jq installed
#   - Reader role (or equivalent) on the target subscription(s)
#
# Usage:
#   ./check-expiring-appservice-certs.sh [--days <N>] [--output <json|table>]
#                                        [--subscription <name-or-id>]
# ---------------------------------------------------------------------------

DAYS=60
OUTPUT_FORMAT="table"
SUBSCRIPTION=""

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --days         <N>       Number of days to look ahead (default: 60)
  --output       <format>  Output format: json or table (default: table)
  --subscription <id>      Limit to a single subscription (name or ID)
  -h, --help               Show this help message
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
    --subscription)
      SUBSCRIPTION="$2"
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
  end_date=$(date -u -v+${DAYS}d +%Y-%m-%dT%H:%M:%SZ)
fi

echo "Checking for App Service certificates expiring between ${now} and ${end_date} (${DAYS} days)..." >&2

# Build the list of subscriptions to scan
if [[ -n "$SUBSCRIPTION" ]]; then
  sub_ids=("$SUBSCRIPTION")
else
  mapfile -t sub_ids < <(az account list --query "[?state=='Enabled'].id" -o tsv 2>/dev/null)
fi

if [[ ${#sub_ids[@]} -eq 0 ]]; then
  echo "Error: no accessible subscriptions found." >&2
  exit 1
fi

echo "Scanning ${#sub_ids[@]} subscription(s)..." >&2

all_results="[]"

for sub in "${sub_ids[@]}"; do
  # Use the ARM REST API to list all certificates in the subscription
  # (az webapp config ssl list requires --resource-group, so we use az rest instead)
  certs=$(az rest --method GET \
    --url "/subscriptions/${sub}/providers/Microsoft.Web/certificates?api-version=2023-12-01" \
    -o json 2>/dev/null || echo '{"value":[]}')

  filtered=$(echo "$certs" | jq --arg now "$now" --arg end "$end_date" --arg sub "$sub" '
    [.value[]? |
      select(.properties.expirationDate >= $now and .properties.expirationDate <= $end) |
      {
        subscription: $sub,
        name: .name,
        resourceGroup: (.id | split("/") | .[4]),
        subjectName: .properties.subjectName,
        thumbprint: .properties.thumbprint,
        expirationDate: .properties.expirationDate
      }
    ]')

  all_results=$(echo "$all_results" "$filtered" | jq -s 'add')
done

count=$(echo "$all_results" | jq 'length')

if [[ "$count" -eq 0 ]]; then
  echo "No App Service certificates expiring in the next ${DAYS} days." >&2
  exit 0
fi

echo "Found ${count} certificate(s) expiring soon." >&2

if [[ "$OUTPUT_FORMAT" == "json" ]]; then
  echo "$all_results" | jq .
else
  printf "\n%-35s %-20s %-40s %-44s %s\n" "CERT NAME" "RESOURCE GROUP" "SUBJECT" "THUMBPRINT" "EXPIRES"
  printf "%s\n" "$(printf '=%.0s' {1..175})"

  echo "$all_results" | jq -r '
    .[] | [.name, .resourceGroup, .subjectName, .thumbprint, .expirationDate] | @tsv
  ' | while IFS=$'\t' read -r name rg subject thumb expires; do
    printf "%-35s %-20s %-40s %-44s %s\n" \
      "${name:0:35}" "${rg:0:20}" "${subject:0:40}" "$thumb" "$expires"
  done
fi
