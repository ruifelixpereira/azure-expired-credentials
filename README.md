# Expired Credentials Checker

Scripts to find Azure credentials that are about to expire — covering both **Azure AD app registrations** (service principal secrets & certificates) and **App Service SSL/TLS certificates**.

Includes an **Azure Automation + Azure Monitor** stack for scheduled checks with email alerts.

## Prerequisites

| Tool | Minimum version | Install |
|------|----------------|---------|
| Azure CLI (`az`) | 2.50+ | [Install](https://learn.microsoft.com/cli/azure/install-azure-cli) |
| `jq` | 1.6+ | `sudo apt install jq` / `brew install jq` |

You must be logged in (`az login`) with appropriate permissions:
- **AD app credentials:** Directory.Read.All or equivalent
- **App Service certs:** Reader role on the target subscription(s)

## Files

| File | Description |
|------|-------------|
| `quick-checks/check-expiring-credentials.sh` | Lists AD app registrations with expiring password/cert credentials |
| `quick-checks/test-check-expiring-credentials.sh` | Tests for the above (mocked `az`, no Azure needed) |
| `quick-checks/check-expiring-appservice-certs.sh` | Lists App Service SSL/TLS certificates expiring soon |
| `quick-checks/test-check-expiring-appservice-certs.sh` | Tests for the above (mocked `az`, no Azure needed) |
| `automation/main.bicep` | Bicep template — Automation Account, Runbook, Schedule, Log Analytics, Alert Rule |
| `automation/main.bicepparam` | Bicep parameters file |
| `automation/runbook-check-expiring-credentials.ps1` | PowerShell runbook (both checks combined) |
| `automation/deploy.sh` | One-command deployment script |

## Usage

```bash
# Make all scripts executable
chmod +x quick-checks/*.sh
```

### 1. AD App Registration Credentials

```bash
cd quick-checks

# Default: credentials expiring in the next 60 days, table output
./check-expiring-credentials.sh

# Custom window (e.g. 90 days) with JSON output
./check-expiring-credentials.sh --days 90 --output json

# Show help
./check-expiring-credentials.sh --help
```

#### Options

| Flag | Default | Description |
|------|---------|-------------|
| `--days <N>` | `60` | Number of days to look ahead |
| `--output <format>` | `table` | Output format: `json` or `table` |
| `-h`, `--help` | — | Show usage information |

#### Example table output

```
APP NAME                                 APP ID                                 TYPE   KEY ID                                   EXPIRES
================================================================================================
My-Service-Principal                     aaaa-1111-bbbb-2222                    Pass   key-pass-30d                             2026-04-30T12:00:00Z
My-Cert-App                              cccc-3333-dddd-4444                    Cert   key-cert-30d                             2026-04-28T08:30:00Z
```

### 2. App Service SSL/TLS Certificates

```bash
cd quick-checks

# Default: certs expiring in the next 60 days across all subscriptions
./check-expiring-appservice-certs.sh

# Scope to a single subscription
./check-expiring-appservice-certs.sh --subscription "My-Sub-Name-Or-Id"

# Custom window with JSON output
./check-expiring-appservice-certs.sh --days 90 --output json

# Show help
./check-expiring-appservice-certs.sh --help
```

#### Options

| Flag | Default | Description |
|------|---------|-------------|
| `--days <N>` | `60` | Number of days to look ahead |
| `--output <format>` | `table` | Output format: `json` or `table` |
| `--subscription <id>` | *(all)* | Limit to a single subscription (name or ID) |
| `-h`, `--help` | — | Show usage information |

#### Example table output

```
CERT NAME                           RESOURCE GROUP       SUBJECT                                  THUMBPRINT                                   EXPIRES
===============================================================================================================
cert-prod-wildcard                  rg-web-prod          *.myapp.com                              AAAA1111BBBB2222CCCC3333DDDD4444EEEE5555     2026-04-30T12:00:00Z
cert-staging                        rg-web-staging       staging.myapp.com                        FFFF6666GGGG7777HHHH8888IIII9999JJJJ0000     2026-05-15T08:30:00Z
```

## Running Tests

Both test scripts mock the `az` CLI — no Azure subscription is required:

```bash
cd quick-checks
./test-check-expiring-credentials.sh
./test-check-expiring-appservice-certs.sh
```

### AD app credential tests cover:
- Default 60-day window correctly filters expiring credentials
- Custom `--days` values (120, 365) widen the window
- Already-expired credentials are excluded
- Apps with no credentials are excluded
- Both table and JSON output formats
- Input validation for `--days` and `--output`
- `--help` flag

### App Service certificate tests cover:
- Default 60-day window correctly filters expiring certificates
- Custom `--days` values (120, 365) widen the window
- Already-expired certificates are excluded
- Both table and JSON output formats
- JSON output contains expected fields (thumbprint, resourceGroup, etc.)
- Multi-subscription scanning
- Single-subscription `--subscription` flag
- Input validation for `--days` and `--output`
- `--help` flag

## Automated Monitoring (Azure Automation + Azure Monitor)

The `automation/` folder contains everything needed to run the checks on a weekly schedule and get email alerts when credentials are about to expire.

### Architecture

```
Azure Automation Account (Managed Identity)
  └─ PowerShell Runbook (weekly schedule)
       ├─ Scans AD app registrations (secrets + certs)
       └─ Scans App Service SSL certificates
            │
            ▼
      Log Analytics Workspace
        (custom table: ExpiringCredentials_CL)
            │
            ▼
      Azure Monitor Scheduled Query Rule
        → fires when DaysRemaining >= 0
            │
            ▼
      Action Group → Email notification
```

### Deploy

```bash
cd automation
chmod +x deploy.sh

# Minimal — creates all resources in a new resource group
./deploy.sh --resource-group rg-credential-monitor --email team@example.com

# With options
./deploy.sh \
  --resource-group rg-credential-monitor \
  --location swedencentral \
  --name-prefix credmon \
  --days-ahead 90 \
  --email security@example.com
```

#### Deploy options

| Flag | Default | Description |
|------|---------|-------------|
| `--resource-group` | *(required)* | Resource group name (created if missing) |
| `--email` | *(required)* | Alert email recipient |
| `--location` | `eastus` | Azure region |
| `--name-prefix` | `credcheck` | Resource name prefix |
| `--days-ahead` | `60` | Days to look ahead |
| `--workspace-id` | *(new)* | Existing Log Analytics workspace resource ID |
| `--runbook-uri` | — | URI to hosted .ps1 (skips upload step) |

### Post-deployment steps

After `deploy.sh` completes, it prints commands to finish setup:

1. **Grant the Managed Identity `Directory.Read.All`** (for AD app checks)
2. **Grant Reader on target subscriptions** (for App Service cert checks)
3. **Set the Log Analytics shared key** in the encrypted Automation variable

### What gets deployed

| Resource | Purpose |
|----------|---------|
| Log Analytics Workspace | Stores `ExpiringCredentials_CL` custom log |
| Automation Account | Runs the PowerShell runbook on a schedule |
| PowerShell 7.2 Runbook | Combines AD app + App Service cert checks |
| Weekly Schedule | Monday 08:00 UTC |
| Action Group | Email notifications |
| Scheduled Query Alert Rule | Fires daily when expiring credentials are found in logs |