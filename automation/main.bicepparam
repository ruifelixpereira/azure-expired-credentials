using 'main.bicep'

param namePrefix = 'credcheck'
param daysAhead = 60
param alertEmailAddresses = ['team@example.com']
param existingWorkspaceId = ''
param runbookScriptUri = ''
