// The one cluster of the system (runtime aks-argocd): every environment of system.json is a namespace of it. Applied
// by job cluster-apply of .github/workflows/system.yml as the deployment stack stack-<slug>-cluster in the cluster's
// resource group, as id-<slug>-cluster. The seed created what the cluster needs first: its own identity
// (id-<slug>-aks), the kubelet identity that pulls the app images (id-<slug>-kubelet) and the ingress IP.
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
    // Upgrades restart the nodes, and with them every SQL Server: a person starts them, not a schedule.
    autoUpgradeProfile: {
      upgradeChannel: 'none'
      nodeOSUpgradeChannel: 'None'
    }
  }
}

output clusterName string = aks.name
output kubernetesVersion string = aks.properties.currentKubernetesVersion
output oidcIssuer string = aks.properties.oidcIssuerProfile.issuerURL
