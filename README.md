# Expired Credentials Checker

Scripts to find Azure credentials that are about to expire — covering both **Azure AD app registrations** (service principal secrets & certificates) and **App Service SSL/TLS certificates**.

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
| `check-expiring-credentials.sh` | Lists AD app registrations with expiring password/cert credentials |
| `test-check-expiring-credentials.sh` | Tests for the above (mocked `az`, no Azure needed) |
| `check-expiring-appservice-certs.sh` | Lists App Service SSL/TLS certificates expiring soon |
| `test-check-expiring-appservice-certs.sh` | Tests for the above (mocked `az`, no Azure needed) |

## Usage

```bash
# Make all scripts executable
chmod +x check-expiring-credentials.sh check-expiring-appservice-certs.sh \
         test-check-expiring-credentials.sh test-check-expiring-appservice-certs.sh
```

### 1. AD App Registration Credentials

```bash
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