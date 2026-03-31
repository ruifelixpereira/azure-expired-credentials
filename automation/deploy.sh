#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# deploy.sh — Deploy the credential-expiry monitoring stack to Azure
#
# Usage:
#   ./deploy.sh --resource-group <RG> --email <addr> [OPTIONS]
# ---------------------------------------------------------------------------

RESOURCE_GROUP=""
LOCATION="eastus"
NAME_PREFIX="credcheck"
DAYS_AHEAD=60
EMAIL=""
EXISTING_WORKSPACE_ID=""
RUNBOOK_SCRIPT_URI=""

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Required:
  --resource-group  <name>   Resource group (created if it doesn't exist)
  --email           <addr>   Alert email address

Optional:
  --location        <region> Azure region (default: eastus)
  --name-prefix     <name>   Resource name prefix (default: credcheck)
  --days-ahead      <N>      Days to look ahead (default: 60)
  --workspace-id    <id>     Existing Log Analytics workspace resource ID
  --runbook-uri     <uri>    URI to the runbook .ps1 file (e.g. GitHub raw URL)
  -h, --help                 Show this help
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --resource-group)  RESOURCE_GROUP="$2"; shift 2 ;;
    --location)        LOCATION="$2"; shift 2 ;;
    --name-prefix)     NAME_PREFIX="$2"; shift 2 ;;
    --days-ahead)      DAYS_AHEAD="$2"; shift 2 ;;
    --email)           EMAIL="$2"; shift 2 ;;
    --workspace-id)    EXISTING_WORKSPACE_ID="$2"; shift 2 ;;
    --runbook-uri)     RUNBOOK_SCRIPT_URI="$2"; shift 2 ;;
    -h|--help)         usage ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$RESOURCE_GROUP" || -z "$EMAIL" ]]; then
  echo "Error: --resource-group and --email are required." >&2
  usage
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Ensuring resource group '${RESOURCE_GROUP}' exists in '${LOCATION}'..."
az group create --name "$RESOURCE_GROUP" --location "$LOCATION" -o none

echo "==> Deploying Bicep template..."
deployment_output=$(az deployment group create \
  --resource-group "$RESOURCE_GROUP" \
  --template-file "${SCRIPT_DIR}/main.bicep" \
  --parameters \
    namePrefix="$NAME_PREFIX" \
    daysAhead="$DAYS_AHEAD" \
    alertEmailAddresses="[\"${EMAIL}\"]" \
    existingWorkspaceId="$EXISTING_WORKSPACE_ID" \
    runbookScriptUri="$RUNBOOK_SCRIPT_URI" \
  -o json)

automation_name=$(echo "$deployment_output" | jq -r '.properties.outputs.automationAccountName.value')
principal_id=$(echo "$deployment_output" | jq -r '.properties.outputs.automationPrincipalId.value')
workspace_customer_id=$(echo "$deployment_output" | jq -r '.properties.outputs.workspaceCustomerId.value')

echo ""
echo "==> Deployment complete!"
echo "    Automation Account:  ${automation_name}"
echo "    Managed Identity:    ${principal_id}"
echo "    Workspace ID:        ${workspace_customer_id}"

# Upload runbook content if no URI was provided
if [[ -z "$RUNBOOK_SCRIPT_URI" ]]; then
  echo ""
  echo "==> Uploading runbook script..."
  az automation runbook replace-content \
    --resource-group "$RESOURCE_GROUP" \
    --automation-account-name "$automation_name" \
    --name "Check-ExpiringCredentials" \
    --content @"${SCRIPT_DIR}/runbook-check-expiring-credentials.ps1" \
    -o none

  echo "==> Publishing runbook..."
  az automation runbook publish \
    --resource-group "$RESOURCE_GROUP" \
    --automation-account-name "$automation_name" \
    --name "Check-ExpiringCredentials" \
    -o none

  echo "==> Linking runbook to schedule..."
  job_schedule_id=$(uuidgen)
  az rest --method PUT \
    --url "/subscriptions/$(az account show --query id -o tsv)/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Automation/automationAccounts/${automation_name}/jobSchedules/${job_schedule_id}?api-version=2023-11-01" \
    --body "{
      \"properties\": {
        \"runbook\": { \"name\": \"Check-ExpiringCredentials\" },
        \"schedule\": { \"name\": \"Weekly-CredentialCheck\" },
        \"parameters\": { \"DaysAhead\": \"${DAYS_AHEAD}\" }
      }
    }" \
    -o none
fi

echo ""
echo "=== Next: run post-deployment setup ==="
echo ""
echo "  ./post-deploy.sh --resource-group ${RESOURCE_GROUP} --name-prefix ${NAME_PREFIX} --subscription-ids <SUB_ID_1,SUB_ID_2>"
echo ""
echo "This will:"
echo "  1. Grant Directory.Read.All to the managed identity"
echo "  2. Grant Reader role on subscriptions you specify"
echo "  3. Set the Log Analytics shared key in the encrypted variable"
echo ""
echo "Done."
