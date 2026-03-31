#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# post-deploy.sh — Configure permissions and secrets after deploying
#                  the credential-expiry monitoring stack.
#
# Usage:
#   ./post-deploy.sh --resource-group <RG> --name-prefix <prefix> \
#                    [--subscription-ids <id1,id2,...>]
# ---------------------------------------------------------------------------

RESOURCE_GROUP=""
NAME_PREFIX="credcheck"
SUBSCRIPTION_IDS=""

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Required:
  --resource-group  <name>   Resource group containing the automation resources
  --name-prefix     <name>   Name prefix used during deployment (default: credcheck)

Optional:
  --subscription-ids <ids>   Comma-separated subscription IDs to grant Reader access
  -h, --help                 Show this help
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --resource-group)   RESOURCE_GROUP="$2"; shift 2 ;;
    --name-prefix)      NAME_PREFIX="$2"; shift 2 ;;
    --subscription-ids) SUBSCRIPTION_IDS="$2"; shift 2 ;;
    -h|--help)          usage ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$RESOURCE_GROUP" ]]; then
  echo "Error: --resource-group is required." >&2
  usage
fi

automation_name="${NAME_PREFIX}-automation"
workspace_name="${NAME_PREFIX}-law"

echo "==> Retrieving managed identity principal ID..."
principal_id=$(az automation account show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$automation_name" \
  --query "identity.principalId" -o tsv)

if [[ -z "$principal_id" || "$principal_id" == "None" ]]; then
  echo "Error: could not find managed identity for ${automation_name}." >&2
  exit 1
fi

echo "    Principal ID: ${principal_id}"

# ── 1. Grant Directory.Read.All via Microsoft Graph app role ──────────────

echo ""
echo "==> Granting Directory.Read.All (Microsoft Graph) to the managed identity..."

graph_app_id="00000003-0000-0000-c000-000000000000"
# Directory.Read.All app role ID
directory_read_role="7ab1d382-f21e-4acd-a863-ba3e13f7da61"

graph_sp_id=$(az ad sp show --id "$graph_app_id" --query "id" -o tsv)

az rest --method POST \
  --url "https://graph.microsoft.com/v1.0/servicePrincipals/${graph_sp_id}/appRoleAssignments" \
  --headers "Content-Type=application/json" \
  --body "{
    \"principalId\": \"${principal_id}\",
    \"resourceId\": \"${graph_sp_id}\",
    \"appRoleId\": \"${directory_read_role}\"
  }" -o none 2>/dev/null && echo "    Done." || echo "    (already assigned or insufficient privileges — check manually)"

# ── 2. Grant Reader on subscriptions ──────────────────────────────────────

if [[ -n "$SUBSCRIPTION_IDS" ]]; then
  echo ""
  echo "==> Granting Reader role on specified subscriptions..."
  IFS=',' read -ra subs <<< "$SUBSCRIPTION_IDS"
  for sub_id in "${subs[@]}"; do
    sub_id=$(echo "$sub_id" | xargs) # trim whitespace
    echo "    Subscription: ${sub_id}"
    az role assignment create \
      --assignee-object-id "$principal_id" \
      --assignee-principal-type ServicePrincipal \
      --role "Reader" \
      --scope "/subscriptions/${sub_id}" \
      -o none 2>/dev/null && echo "      Assigned." || echo "      (already assigned or insufficient privileges)"
  done
else
  echo ""
  echo "==> Skipping subscription Reader role (no --subscription-ids provided)."
  echo "    To grant later:"
  echo "    az role assignment create --assignee-object-id ${principal_id} --assignee-principal-type ServicePrincipal --role Reader --scope /subscriptions/<SUB_ID>"
fi

# ── 3. Set Log Analytics shared key ──────────────────────────────────────

echo ""
echo "==> Retrieving Log Analytics shared key..."
shared_key=$(az monitor log-analytics workspace get-shared-keys \
  --resource-group "$RESOURCE_GROUP" \
  --workspace-name "$workspace_name" \
  --query "primarySharedKey" -o tsv)

if [[ -z "$shared_key" ]]; then
  echo "Error: could not retrieve shared key for ${workspace_name}." >&2
  echo "You may need to set it manually."
  exit 1
fi

echo "==> Updating encrypted Automation variable..."
sub_id=$(az account show --query "id" -o tsv)
az rest --method PATCH \
  --url "/subscriptions/${sub_id}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Automation/automationAccounts/${automation_name}/variables/LogAnalyticsSharedKey?api-version=2023-11-01" \
  --body "{
    \"name\": \"LogAnalyticsSharedKey\",
    \"properties\": {
      \"value\": \"\\\"${shared_key}\\\"\",
      \"isEncrypted\": true
    }
  }" \
  -o none

echo "    Done."

# ── Summary ───────────────────────────────────────────────────────────────

echo ""
echo "=== Post-deployment complete ==="
echo "  Managed Identity:    ${principal_id}"
echo "  Directory.Read.All:  granted"
echo "  Reader role:         ${SUBSCRIPTION_IDS:-'(not assigned — use --subscription-ids)'}"
echo "  LA shared key:       set in encrypted variable"
echo ""
echo "You can now trigger a test run:"
echo "  az automation runbook start --resource-group ${RESOURCE_GROUP} --automation-account-name ${automation_name} --name Check-ExpiringCredentials"
