// The one cluster of the system (runtime aks-argocd): every environment of system.json is a namespace of it. Applied
// by job cluster-apply of .github/workflows/system.yml as the deployment stack stack-<slug>-cluster in the cluster's
// resource group, as id-<slug>-cluster. The seed created what the cluster needs first: its own identity
// (id-<slug>-aks), the kubelet identity that pulls the app images (id-<slug>-kubelet), the ingress IP, and the
// storage account and identity of the SQL backups (this stack adds that identity's federated credentials).
// With capability "telemetry" an environment gets its own Log Analytics workspace and Application Insights here; the
// cluster job hands the connection string to the environment's namespace as a Secret (cluster/apply-cluster.ps1).
targetScope = 'resourceGroup'

var system = loadJsonContent('../system.json')
var slug = system.system.slug

resource aks 'Microsoft.ContainerService/managedClusters@2025-05-01' = {
  name: system.cluster.name
  location: system.system.location
  tags: {
    system: slug
    purpose: 'demo'
    tier: 'cluster'
  }
  sku: {
    name: 'Base'
    tier: 'Free'
  }
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${system.azure.identities.aks.resourceId}': {}
    }
  }
  properties: {
    dnsPrefix: system.cluster.name
    nodeResourceGroup: '${system.azure.resourceGroups.cluster}-nodes'
    identityProfile: {
      kubeletidentity: {
        resourceId: system.azure.identities.kubelet.resourceId
        clientId: system.azure.identities.kubelet.clientId
        objectId: system.azure.identities.kubelet.principalId
      }
    }
    agentPoolProfiles: [
      {
        name: 'system'
        mode: 'System'
        type: 'VirtualMachineScaleSets'
        osType: 'Linux'
        osSKU: 'AzureLinux'
        vmSize: system.cluster.nodeSize
        count: system.cluster.nodeCount
        // A low pod limit keeps the memory the kubelet reserves small (20 MB per pod).
        maxPods: 60
      }
    ]
    networkProfile: {
      networkPlugin: 'azure'
      networkPluginMode: 'overlay'
      loadBalancerSku: 'standard'
    }
    oidcIssuerProfile: {
      enabled: true
    }
    // The backup jobs sign in to Azure as id-<slug>-backup with their Kubernetes service account token.
    securityProfile: {
      workloadIdentity: {
        enabled: true
      }
    }
    // Upgrades restart the nodes, and with them every SQL Server: a person starts them, not a schedule.
    autoUpgradeProfile: {
      upgradeChannel: 'none'
      nodeOSUpgradeChannel: 'None'
    }
  }
}

// One federated credential per environment: the service account db-backup of the environment's namespace may sign in
// as the seed's backup identity. One at a time: Azure refuses concurrent writes to the credentials of one identity.
resource backupIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: system.azure.identities.backup.name
}

@batchSize(1)
resource backupCredentials 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = [
  for environment in system.environments: {
    parent: backupIdentity
    name: 'db-backup-${environment.name}'
    properties: {
      issuer: aks.properties.oidcIssuerProfile.issuerURL
      subject: 'system:serviceaccount:${slug}-${environment.name}:db-backup'
      audiences: ['api://AzureADTokenExchange']
    }
  }
]

// Capability "telemetry" (system.json environments[].capabilities): where the app's OpenTelemetry export lands, one
// component per environment so each environment's numbers and its daily cap are its own. The plan identity, a reader
// of this group, may query them: the capability checks do.
var telemetryEnvironments = filter(system.environments, e => contains(e.?capabilities ?? [], 'telemetry'))

resource workspaces 'Microsoft.OperationalInsights/workspaces@2023-09-01' = [
  for environment in telemetryEnvironments: {
    name: 'log-${slug}-${environment.name}'
    location: system.system.location
    tags: {
      system: slug
      purpose: 'demo'
      environment: environment.name
      tier: environment.tier
    }
    properties: {
      sku: {
        name: 'PerGB2018'
      }
      retentionInDays: 30
      workspaceCapping: {
        dailyQuotaGb: 1
      }
    }
  }
]

resource insights 'Microsoft.Insights/components@2020-02-02' = [
  for (environment, i) in telemetryEnvironments: {
    name: 'appi-${slug}-${environment.name}'
    location: system.system.location
    kind: 'web'
    tags: {
      system: slug
      purpose: 'demo'
      environment: environment.name
      tier: environment.tier
    }
    properties: {
      Application_Type: 'web'
      WorkspaceResourceId: workspaces[i].id
    }
  }
]

output clusterName string = aks.name
output kubernetesVersion string = aks.properties.currentKubernetesVersion
output oidcIssuer string = aks.properties.oidcIssuerProfile.issuerURL
