<#
.SYNOPSIS
    Azure Automation Runbook — checks for expiring AD app credentials and
    App Service SSL certificates, then pushes results to a Log Analytics
    workspace as custom log data so Azure Monitor alert rules can fire.

.DESCRIPTION
    Runs on a schedule inside an Azure Automation Account using a System-Assigned
    Managed Identity. Requires:
      - Directory.Read.All  (for AD app credential checks)
      - Reader on target subscriptions (for App Service cert checks)
      - Log Analytics Contributor on the workspace (to ingest custom logs)

.PARAMETER DaysAhead
    Number of days to look ahead for expiring credentials (default: 60).

.PARAMETER WorkspaceId
    Log Analytics Workspace ID. If omitted, reads from the Automation variable 'LogAnalyticsWorkspaceId'.

.PARAMETER WorkspaceSharedKey
    Log Analytics Workspace shared key. If omitted, reads from the encrypted
    Automation variable 'LogAnalyticsSharedKey'.
#>

param(
    [int]$DaysAhead = 60,

    [string]$WorkspaceId = "",

    [string]$WorkspaceSharedKey = ""
)

$ErrorActionPreference = "Stop"

# ── authenticate with managed identity ────────────────────────────────────

Write-Output "Connecting with system-assigned managed identity..."
Connect-AzAccount -Identity | Out-Null

# ── resolve workspace credentials from Automation variables if needed ─────

if ([string]::IsNullOrWhiteSpace($WorkspaceId)) {
    Write-Output "WorkspaceId not passed as parameter, reading from Automation variable..."
    $WorkspaceId = Get-AutomationVariable -Name 'LogAnalyticsWorkspaceId'
}

if ([string]::IsNullOrWhiteSpace($WorkspaceSharedKey)) {
    Write-Output "WorkspaceSharedKey not passed as parameter, reading from Automation variable..."
    $WorkspaceSharedKey = Get-AutomationVariable -Name 'LogAnalyticsSharedKey'
}

if ([string]::IsNullOrWhiteSpace($WorkspaceId) -or [string]::IsNullOrWhiteSpace($WorkspaceSharedKey)) {
    throw "WorkspaceId and WorkspaceSharedKey must be provided as parameters or set as Automation variables."
}

$now       = (Get-Date).ToUniversalTime()
$endWindow = $now.AddDays($DaysAhead)

Write-Output "Checking for credentials expiring between $($now.ToString('o')) and $($endWindow.ToString('o')) ($DaysAhead days)..."

$allFindings = @()

# ── 1. AD app registration credentials ───────────────────────────────────
# Get-AzADApplication does not populate PasswordCredential/KeyCredential,
# so we call the Microsoft Graph API directly via Invoke-AzRestMethod.

Write-Output "Scanning AD app registrations via Graph API..."

try {
    $graphUrl = 'https://graph.microsoft.com/v1.0/applications?$select=appId,displayName,passwordCredentials,keyCredentials&$top=999'
    $apps = @()

    while ($graphUrl) {
        $response = Invoke-AzRestMethod -Uri $graphUrl -Method GET
        if ($response.StatusCode -ne 200) {
            throw "Graph API returned $($response.StatusCode): $($response.Content)"
        }
        $body = $response.Content | ConvertFrom-Json
        $apps += $body.value
        $graphUrl = $body.'@odata.nextLink'
    }

    Write-Output "  Found $($apps.Count) app registration(s) to inspect."

    if ($apps.Count -eq 0) {
        Write-Warning "No app registrations returned. The managed identity may lack Directory.Read.All permission."
    }

    foreach ($app in $apps) {
        # Password credentials (secrets)
        foreach ($cred in $app.passwordCredentials) {
            $endDt = [DateTime]::Parse($cred.endDateTime).ToUniversalTime()
            if ($endDt -ge $now -and $endDt -le $endWindow) {
                $allFindings += [PSCustomObject]@{
                    Category       = "ADAppPassword"
                    ResourceName   = $app.displayName
                    ResourceId     = $app.appId
                    CredentialName = $cred.displayName
                    KeyId          = $cred.keyId
                    ExpirationDate = $endDt.ToString("o")
                    DaysRemaining  = [math]::Floor(($endDt - $now).TotalDays)
                }
            }
        }

        # Key credentials (certificates)
        foreach ($cred in $app.keyCredentials) {
            $endDt = [DateTime]::Parse($cred.endDateTime).ToUniversalTime()
            if ($endDt -ge $now -and $endDt -le $endWindow) {
                $allFindings += [PSCustomObject]@{
                    Category       = "ADAppCertificate"
                    ResourceName   = $app.displayName
                    ResourceId     = $app.appId
                    CredentialName = $cred.displayName
                    KeyId          = $cred.keyId
                    ExpirationDate = $endDt.ToString("o")
                    DaysRemaining  = [math]::Floor(($endDt - $now).TotalDays)
                }
            }
        }
    }
}
catch {
    Write-Warning "AD app scan failed (missing Directory.Read.All?): $_"
    Write-Output "Continuing with App Service certificate check..."
}

# ── 2. App Service SSL certificates ──────────────────────────────────────

Write-Output "Scanning App Service certificates across subscriptions..."

$subscriptions = Get-AzSubscription | Where-Object { $_.State -eq "Enabled" }

foreach ($sub in $subscriptions) {
    Set-AzContext -SubscriptionId $sub.Id | Out-Null

    try {
        $certs = Get-AzWebAppCertificate
    }
    catch {
        Write-Warning "Could not list certificates in subscription $($sub.Name): $_"
        continue
    }

    foreach ($cert in $certs) {
        $certExpiry = [DateTime]::Parse($cert.ExpirationDate).ToUniversalTime()
        if ($certExpiry -ge $now -and $certExpiry -le $endWindow) {
            $allFindings += [PSCustomObject]@{
                Category       = "AppServiceCert"
                ResourceName   = $cert.Name
                ResourceId     = $cert.Id
                CredentialName = $cert.SubjectName
                KeyId          = $cert.Thumbprint
                ExpirationDate = $certExpiry.ToString("o")
                DaysRemaining  = [math]::Floor(($certExpiry - $now).TotalDays)
            }
        }
    }
}

# ── 3. Send to Log Analytics ─────────────────────────────────────────────

$logType = "ExpiringCredentials"

function Send-LogAnalyticsData {
    param(
        [string]$WorkspaceId,
        [string]$SharedKey,
        [string]$Body,
        [string]$LogType
    )

    $method      = "POST"
    $contentType = "application/json"
    $resource    = "/api/logs"
    $date        = [DateTime]::UtcNow.ToString("r")
    $contentLen  = [System.Text.Encoding]::UTF8.GetByteCount($Body)

    $stringToSign = "$method`n$contentLen`n$contentType`nx-ms-date:$date`n$resource"
    $bytesToSign  = [System.Text.Encoding]::UTF8.GetBytes($stringToSign)
    $keyBytes     = [Convert]::FromBase64String($SharedKey)
    $hmac         = New-Object System.Security.Cryptography.HMACSHA256
    $hmac.Key     = $keyBytes
    $signature    = [Convert]::ToBase64String($hmac.ComputeHash($bytesToSign))
    $auth         = "SharedKey ${WorkspaceId}:${signature}"

    $uri = "https://${WorkspaceId}.ods.opinsights.azure.com${resource}?api-version=2016-04-01"

    $headers = @{
        "Authorization"        = $auth
        "Log-Type"             = $LogType
        "x-ms-date"           = $date
        "time-generated-field" = "ExpirationDate"
    }

    Invoke-RestMethod -Uri $uri -Method $method -ContentType $contentType `
        -Headers $headers -Body $Body
}

$count = $allFindings.Count

if ($count -eq 0) {
    Write-Output "No credentials expiring in the next $DaysAhead days."

    # Send a heartbeat record so the alert rule can detect missing data
    $heartbeat = @([PSCustomObject]@{
        Category       = "Heartbeat"
        ResourceName   = "NoExpiring"
        ResourceId     = ""
        CredentialName = ""
        KeyId          = ""
        ExpirationDate = $now.ToString("o")
        DaysRemaining  = -1
    })
    $body = $heartbeat | ConvertTo-Json -AsArray
    Send-LogAnalyticsData -WorkspaceId $WorkspaceId -SharedKey $WorkspaceSharedKey `
        -Body $body -LogType $logType
}
else {
    Write-Output "Found $count expiring credential(s). Sending to Log Analytics..."

    $body = $allFindings | ConvertTo-Json -AsArray
    Send-LogAnalyticsData -WorkspaceId $WorkspaceId -SharedKey $WorkspaceSharedKey `
        -Body $body -LogType $logType

    Write-Output "Data ingested into custom log table '${logType}_CL'."
}

# ── 4. Summary ────────────────────────────────────────────────────────────

Write-Output "`n=== Summary ==="
Write-Output "AD app passwords expiring:     $(($allFindings | Where-Object Category -eq 'ADAppPassword').Count)"
Write-Output "AD app certificates expiring:  $(($allFindings | Where-Object Category -eq 'ADAppCertificate').Count)"
Write-Output "App Service certs expiring:    $(($allFindings | Where-Object Category -eq 'AppServiceCert').Count)"
Write-Output "Total:                         $count"
