// Deploys the full automation stack for credential expiry monitoring:
//   - Log Analytics workspace (or reference to existing one)
//   - Automation Account with system-assigned managed identity
//   - PowerShell runbook
//   - Weekly schedule + job link
//   - Scheduled query alert rule (Azure Monitor) that fires when expiring credentials are found

targetScope = 'resourceGroup'

@description('Azure region for all resources')
param location string = resourceGroup().location

@description('Base name prefix for all resources')
param namePrefix string = 'credcheck'

@description('Number of days ahead to check for expiring credentials')
param daysAhead int = 60

@description('Email address(es) to receive alert notifications')
param alertEmailAddresses string[]

@description('Log Analytics workspace ID to use. Leave empty to create a new one.')
param existingWorkspaceId string = ''

@description('URI of the runbook script in a storage account or GitHub raw URL')
param runbookScriptUri string = ''

@description('Current UTC time — used to compute schedule start. Do not set manually.')
param now string = utcNow()

// ── Log Analytics Workspace ──────────────────────────────────────────────

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = if (existingWorkspaceId == '') {
  name: '${namePrefix}-law'
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

var workspaceResourceId = existingWorkspaceId != '' ? existingWorkspaceId : workspace!.id

// ── Automation Account ───────────────────────────────────────────────────

resource automationAccount 'Microsoft.Automation/automationAccounts@2023-11-01' = {
  name: '${namePrefix}-automation'
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    sku: {
      name: 'Basic'
    }
  }
}

// ── Automation Variables (for Log Analytics ingestion) ────────────────────

resource varWorkspaceId 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = {
  parent: automationAccount
  name: 'LogAnalyticsWorkspaceId'
  properties: {
    description: 'Log Analytics Workspace ID for custom log ingestion'
    isEncrypted: false
    value: '"${existingWorkspaceId != '' ? existingWorkspaceId : workspace!.properties.customerId}"'
  }
}

// The shared key must be set manually after deployment (encrypted variable)
resource varSharedKey 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = {
  parent: automationAccount
  name: 'LogAnalyticsSharedKey'
  properties: {
    description: 'Log Analytics primary shared key (set manually after deployment)'
    isEncrypted: true
    value: '"REPLACE_AFTER_DEPLOYMENT"'
  }
}

// ── Runbook ──────────────────────────────────────────────────────────────

resource runbook 'Microsoft.Automation/automationAccounts/runbooks@2023-11-01' = {
  parent: automationAccount
  name: 'Check-ExpiringCredentials'
  location: location
  properties: {
    runbookType: 'PowerShell72'
    description: 'Checks for AD app credentials and App Service certificates expiring soon, sends results to Log Analytics'
    publishContentLink: runbookScriptUri != '' ? {
      uri: runbookScriptUri
    } : null
    logVerbose: false
    logProgress: false
  }
}

// ── Schedule (weekly, Monday 08:00 UTC) ──────────────────────────────────

resource schedule 'Microsoft.Automation/automationAccounts/schedules@2023-11-01' = {
  parent: automationAccount
  name: 'Weekly-CredentialCheck'
  properties: {
    description: 'Runs the credential expiry check every Monday at 08:00 UTC'
    startTime: dateTimeAdd(now, 'P1D')
    frequency: 'Week'
    interval: 1
    timeZone: 'UTC'
    advancedSchedule: {
      weekDays: ['Monday']
    }
  }
}

// Only create the job-schedule link when the runbook is published via URI.
// When runbookScriptUri is empty, deploy.sh uploads + publishes the runbook
// and links the schedule in a separate step.
resource jobSchedule 'Microsoft.Automation/automationAccounts/jobSchedules@2023-11-01' = if (runbookScriptUri != '') {
  parent: automationAccount
  name: guid(automationAccount.id, runbook.id, schedule.id)
  properties: {
    runbook: {
      name: runbook.name
    }
    schedule: {
      name: schedule.name
    }
    parameters: {
      DaysAhead: string(daysAhead)
    }
  }
}

// ── Action Group (email) ─────────────────────────────────────────────────

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: '${namePrefix}-alert-ag'
  location: 'global'
  properties: {
    groupShortName: 'CredExpiry'
    enabled: true
    emailReceivers: [for (email, i) in alertEmailAddresses: {
      name: 'email-${i}'
      emailAddress: email
      useCommonAlertSchema: true
    }]
  }
}

// ── Scheduled Query Alert Rule ───────────────────────────────────────────
// Fires when ExpiringCredentials_CL has rows with DaysRemaining >= 0
// (i.e., real findings, not heartbeats)

resource alertRule 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = {
  name: '${namePrefix}-expiring-creds-alert'
  location: location
  properties: {
    displayName: 'Expiring Credentials Detected'
    description: 'Alerts when Azure AD app secrets/certs or App Service certificates are about to expire'
    severity: 2
    enabled: true
    evaluationFrequency: 'P1D'
    windowSize: 'P1D'
    scopes: [
      workspaceResourceId
    ]
    criteria: {
      allOf: [
        {
          query: '''
            ExpiringCredentials_CL
            | where DaysRemaining_d >= 0
            | summarize Count=count() by Category, ResourceName_s, TimeGenerated, DaysRemaining_d
            | order by DaysRemaining_d asc
          '''
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    skipQueryValidation: true
    actions: {
      actionGroups: [
        actionGroup.id
      ]
    }
    autoMitigate: false
  }
}

// ── Outputs ──────────────────────────────────────────────────────────────

@description('Automation Account principal ID — grant Directory.Read.All and Reader roles to this identity')
output automationPrincipalId string = automationAccount.identity.?principalId ?? ''

@description('Automation Account name')
output automationAccountName string = automationAccount.name

@description('Log Analytics Workspace ID (customer ID)')
output workspaceCustomerId string = existingWorkspaceId != '' ? existingWorkspaceId : workspace!.properties.customerId
