// Optional add-on: Flask API wrapper that starts the existing COBOL ACA Job.
// This file creates only the API Container App and grants it access to the existing Job.
targetScope = 'resourceGroup'

@description('API Container App name')
param apiAppName string = 'pb-job-api'

@description('Existing Container Apps environment name')
param acaEnvName string = 'cae-practicebank'

@description('Existing ACR name that stores the API image')
param acrName string

@description('API container image, for example myacr.azurecr.io/practice-bank-api:latest')
param image string

@description('Existing COBOL Container Apps Job name')
param targetJobName string = 'pb-batch'

@description('Expose the API publicly. Keep false for internal-only ingress.')
param externalIngress bool = false

@description('Azure subscription id used by the API to call ARM')
param subscriptionId string = subscription().subscriptionId

@description('Allowed Job names exposed by the API')
param allowedJobs string = targetJobName

var acrPullRoleDefinitionId = '7f951dda-4ed3-4680-a7ca-43fe172d538d'
var contributorRoleDefinitionId = 'b24988ac-6180-42a0-ab88-20f7382dd24c'

resource acaEnv 'Microsoft.App/managedEnvironments@2024-03-01' existing = {
  name: acaEnvName
}

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: acrName
}

resource targetJob 'Microsoft.App/jobs@2024-03-01' existing = {
  name: targetJobName
}

resource apiApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: apiAppName
  location: resourceGroup().location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    managedEnvironmentId: acaEnv.id
    configuration: {
      ingress: {
        external: externalIngress
        targetPort: 8000
        transport: 'auto'
      }
      registries: [
        {
          server: '${acr.name}.azurecr.io'
          identity: 'system'
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'api'
          image: image
          env: [
            {
              name: 'AZURE_SUBSCRIPTION_ID'
              value: subscriptionId
            }
            {
              name: 'AZURE_RESOURCE_GROUP'
              value: resourceGroup().name
            }
            {
              name: 'AZURE_CONTAINERAPP_JOB_NAME'
              value: targetJobName
            }
            {
              name: 'AZURE_CONTAINERAPP_ALLOWED_JOBS'
              value: allowedJobs
            }
          ]
          resources: {
            cpu: json('0.25')
            memory: '0.5Gi'
          }
        }
      ]
      scale: {
        minReplicas: 0
        maxReplicas: 2
      }
    }
  }
}

resource acrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, apiApp.id, 'acr-pull')
  scope: acr
  properties: {
    principalId: apiApp.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', acrPullRoleDefinitionId)
  }
}

resource jobContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(targetJob.id, apiApp.id, 'job-start-read')
  scope: targetJob
  properties: {
    principalId: apiApp.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', contributorRoleDefinitionId)
  }
}

output apiAppFqdn string = apiApp.properties.configuration.ingress.fqdn
output apiPrincipalId string = apiApp.identity.principalId