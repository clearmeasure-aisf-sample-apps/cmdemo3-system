#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Creates or updates the cluster and what Octopus Deploy needs in it: Argo CD, the Octopus Argo CD Gateway and the
    Octopus Kubernetes worker.

.DESCRIPTION
    Job cluster-apply of .github/workflows/system.yml, signed in to Azure as id-<slug>-cluster and to Octopus as the
    system's service account (GitHub OIDC; OCTOPUS_ACCESS_TOKEN is a token of one hour). Every step is safe to repeat:
      1. infra/cluster.bicep as the deployment stack stack-<slug>-cluster.
      2. Argo CD from its Helm chart with cluster/argocd-values.yaml, then the root Application
         (gitops/argocd/root.yaml): from here on Argo CD applies gitops/ by itself.
      3. Once: the Octopus Argo CD Gateway, the way Octopus documents it
         (https://octopus.com/docs/argo-cd/instances/automated-installation). An API token of Argo CD's account
         "octopus" is generated and handed to the chart, which keeps it in a Secret of the gateway's namespace; the
         gateway registers itself in the space with the one-hour Octopus token, for the environments of system.json.
         An instance that exists is given the environments of system.json when they changed.
      4. Once: the Octopus Kubernetes worker (Helm chart kubernetes-agent), registered with the same one-hour token
         into the worker pool <slug>-cluster.
      5. Waits for the ingress platform Argo CD installs, and restarts cert-manager once when it started before the
         Gateway API definitions existed (it issues certificates for a Gateway only when they existed at its start).
      6. Capability "telemetry": the connection string of each such environment's Application Insights, as Secret
         "telemetry" of its namespace.
    No token is printed or passed as an argument: Helm reads them from standard input. Octopus holds no credential of
    the cluster; the gateway and the worker connect out to Octopus.

    Dormant between classes: with cluster.dormant true in system.json the job only stops the cluster (az aks stop:
    its nodes go away, the disks, the public address and the registry stay) and reports dormant=true to the workflow,
    which then makes no release. Without it, a stopped cluster is started first, and the steps above run as always.
#>
[CmdletBinding()]
param(
    [string] $Root = (Split-Path -Parent $PSScriptRoot)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

# The Azure CLI checks once a day whether a newer Bicep exists and says so as a warning on the next command that
# reads a template: a warning in the log that is about nothing in it. The version in use is the installed one.
$env:AZURE_BICEP_CHECK_VERSION = 'false'
$ProgressPreference = 'SilentlyContinue'

$argoChartVersion = '10.9.6'
$gatewayChartVersion = '2.2.0'
$workerChartVersion = '3.15.2'

$system = Get-Content -LiteralPath (Join-Path $Root 'system.json') -Raw | ConvertFrom-Json -AsHashtable
$slug = [string] $system.system.slug
$resourceGroup = [string] $system.azure.resourceGroups.cluster
$clusterName = [string] $system.cluster.name
$octopusUrl = [string] $system.octopus.url
$octopusHost = ([uri] $octopusUrl).Host
$spaceId = [string] $system.octopus.spaceId
$spaceName = [string] $env:OCTOPUS_SPACE
$environments = @($system.environments | ForEach-Object { [string] $_.name })
$gatewayName = "argocd-$slug"
$gatewayNamespace = 'octopus-argocd-gateway'
$workerNamespace = 'octopus-worker'
$token = [string] $env:OCTOPUS_ACCESS_TOKEN
if (-not $token) { throw 'OCTOPUS_ACCESS_TOKEN is not set: the job signs in to Octopus first (OctopusDeploy/login).' }
if (-not $spaceName) { throw 'OCTOPUS_SPACE is not set (the space name).' }
$headers = @{ Authorization = "Bearer $token" }

function Test-HelmRelease {
    param([string] $Name, [string] $Namespace)
    return [bool] (helm list --namespace $Namespace --filter "^$Name$" --deployed --short)
}

function Set-JobOutput {
    param([string] $Name, [string] $Value)
    if ($env:GITHUB_OUTPUT) { Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "$Name=$Value" }
}

# The cluster's power state, or nothing before the first apply created it.
$PSNativeCommandUseErrorActionPreference = $false
$power = [string] (az aks show --resource-group $resourceGroup --name $clusterName --query powerState.code --output tsv 2>$null)
$PSNativeCommandUseErrorActionPreference = $true
$power = $power.Trim()
if ($system.cluster.ContainsKey('dormant') -and $system.cluster.dormant) {
    Write-Host "==> Cluster $clusterName is dormant (cluster.dormant in system.json)"
    Set-JobOutput -Name 'dormant' -Value 'true'
    if (-not $power) { throw "cluster.dormant is set, but $clusterName does not exist yet: create it awake first." }
    if ($power -eq 'Stopped') {
        Write-Host "SKIP $clusterName is stopped already"
    }
    else {
        az aks stop --resource-group $resourceGroup --name $clusterName --output none
        Write-Host "PASS $clusterName stopped: no nodes run until cluster.dormant is removed"
    }
    return
}
Set-JobOutput -Name 'dormant' -Value 'false'
if ($power -eq 'Stopped') {
    Write-Host "==> Cluster $clusterName wakes (cluster.dormant is no longer set)"
    az aks start --resource-group $resourceGroup --name $clusterName --output none
    Write-Host "PASS $clusterName started"
}

Write-Host "==> Cluster $clusterName (stack-$slug-cluster in $resourceGroup)"
az stack group create --name "stack-$slug-cluster" --resource-group $resourceGroup `
    --template-file (Join-Path $Root 'infra' 'cluster.bicep') `
    --action-on-unmanage detachAll --deny-settings-mode none --yes --output none
$env:KUBECONFIG = Join-Path ([IO.Path]::GetTempPath()) "kubeconfig-$slug"
# --only-show-errors: the CLI reports the merged context as a WARNING line.
az aks get-credentials --resource-group $resourceGroup --name $clusterName --admin --overwrite-existing --file $env:KUBECONFIG --only-show-errors --output none
kubectl wait --for=condition=Ready nodes --all --timeout=600s
Write-Host "PASS cluster $clusterName"

Write-Host '==> Argo CD'
helm upgrade --install argocd oci://ghcr.io/argoproj/argo-helm/argo-cd --version $argoChartVersion `
    --namespace argocd --create-namespace --values (Join-Path $Root 'cluster' 'argocd-values.yaml') --wait --timeout 15m | Out-Null
kubectl apply --filename (Join-Path $Root 'gitops' 'argocd' 'root.yaml')
Write-Host "PASS Argo CD (chart $argoChartVersion) and the root Application"

Write-Host "==> Octopus Argo CD Gateway $gatewayName"
if (Test-HelmRelease -Name $gatewayName -Namespace $gatewayNamespace) {
    # Registered before. The environments of the instance follow system.json (a new environment is a pull request
    # that adds it there). The provider has no resource for the instance, so this is the REST API: the instances are
    # listed as summaries, and a POST to the gateway changes it.
    $gateway = (Invoke-RestMethod -Uri "$octopusUrl/api/$spaceId/argocdinstances/summaries" -Headers $headers).Resources | Where-Object { $_.Name -eq $gatewayName } | Select-Object -First 1
    if (-not $gateway) { throw "The gateway's Helm release exists, but Octopus lists no Argo CD instance named $gatewayName in $spaceId." }
    $wanted = @((Invoke-RestMethod -Uri "$octopusUrl/api/$spaceId/environments/all" -Headers $headers) | Where-Object { $environments -contains $_.Slug } | ForEach-Object { [string] $_.Id } | Sort-Object)
    if (($wanted -join ',') -ne ((@($gateway.EnvironmentIds) | Sort-Object) -join ',')) {
        $body = @{ Id = $gateway.GatewayId; SpaceId = $spaceId; Name = $gatewayName; WebUIUri = $gateway.WebUIUri; EnvironmentIds = $wanted; TenantIds = @($gateway.TenantIds) } | ConvertTo-Json -Depth 5
        Invoke-RestMethod -Uri "$octopusUrl/api/$spaceId/argocdgateways/$($gateway.GatewayId)" -Method Post -Headers $headers -ContentType 'application/json' -Body $body | Out-Null
        $after = @((Invoke-RestMethod -Uri "$octopusUrl/api/$spaceId/argocdgateways/$($gateway.GatewayId)" -Headers $headers).Resource.EnvironmentIds | Sort-Object)
        if (($wanted -join ',') -ne ($after -join ',')) { throw "Octopus did not take the environments $($environments -join ', ') for the Argo CD instance $gatewayName (it lists $($after -join ', '))." }
        Write-Host "PASS gateway $gatewayName now serves $($environments -join ', ')"
    }
    else {
        Write-Host "PASS gateway $gatewayName serves $($environments -join ', ')"
    }
}
else {
    # An API token of Argo CD's account "octopus" (argocd account generate-token --account octopus, here through the
    # same API the CLI calls, over a port-forward): sign in as admin, then ask for the account's token.
    $forward = Start-Process -FilePath kubectl -ArgumentList 'port-forward', '--namespace', 'argocd', 'service/argocd-server', '18080:80' -PassThru -RedirectStandardOutput ([IO.Path]::GetTempFileName())
    try {
        Start-Sleep -Seconds 5
        $adminPassword = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String((kubectl get secret argocd-initial-admin-secret --namespace argocd --output 'jsonpath={.data.password}')))
        $session = Invoke-RestMethod -Uri 'http://localhost:18080/api/v1/session' -Method Post -ContentType 'application/json' -Body (@{ username = 'admin'; password = $adminPassword } | ConvertTo-Json)
        $argoToken = [string] (Invoke-RestMethod -Uri 'http://localhost:18080/api/v1/account/octopus/token' -Method Post -ContentType 'application/json' `
                -Headers @{ Authorization = "Bearer $($session.token)" } -Body (@{ name = 'octopus'; id = "octopus-gateway-$(Get-Date -Format yyyyMMddHHmm)" } | ConvertTo-Json)).token
    }
    finally {
        Stop-Process -Id $forward.Id -Force -ErrorAction SilentlyContinue
    }
    if (-not $argoToken) { throw 'Argo CD returned no API token for account octopus.' }
    Write-Host "::add-mask::$argoToken"

    $values = @{
        gateway      = @{
            octopus = @{ serverGrpcUrl = "grpc://${octopusHost}:8443" }
            argocd  = @{
                serverGrpcUrl       = 'argocd-server.argocd.svc.cluster.local:443'
                # Argo CD runs without TLS of its own (server.insecure): Octopus documents plaintext for that.
                plaintext           = $true
                insecure            = $false
                authenticationToken = $argoToken
            }
        }
        registration = @{
            octopus = @{
                name              = $gatewayName
                serverApiUrl      = $octopusUrl
                serverAccessToken = $token
                spaceId           = $spaceId
                environments      = $environments
            }
            argocd  = @{ webUiUrl = "https://argocd-$slug.$($system.cluster.domain)" }
        }
    } | ConvertTo-Json -Depth 10
    $values | helm upgrade --install --atomic $gatewayName oci://registry-1.docker.io/octopusdeploy/octopus-argocd-gateway-chart `
        --version $gatewayChartVersion --namespace $gatewayNamespace --create-namespace --values - --timeout 10m | Out-Null
    Write-Host "PASS gateway $gatewayName (chart $gatewayChartVersion) registered in $spaceId for $($environments -join ', ')"
}

Write-Host "==> Octopus Kubernetes worker $slug-worker"
if (Test-HelmRelease -Name "$slug-worker" -Namespace $workerNamespace) {
    Write-Host "PASS worker $slug-worker is installed"
}
else {
    $values = @{
        agent      = @{
            acceptEula           = 'Y'
            name                 = "$slug-worker"
            serverUrl            = $octopusUrl
            serverCommsAddresses = @("https://polling.$octopusHost")
            space                = $spaceName
            bearerToken          = $token
            worker               = @{ enabled = $true; initial = @{ workerPools = @("$slug-cluster") } }
        }
        scriptPods = @{
            # gitops/platform/worker-rbac.yaml grants this account its rights in the environments' namespaces.
            serviceAccount = @{ name = 'octopus-worker-scripts' }
        }
    } | ConvertTo-Json -Depth 10
    $values | helm upgrade --install --atomic "$slug-worker" oci://registry-1.docker.io/octopusdeploy/kubernetes-agent `
        --version $workerChartVersion --namespace $workerNamespace --create-namespace --values - --timeout 10m | Out-Null
    Write-Host "PASS worker $slug-worker (chart $workerChartVersion) registered in pool $slug-cluster"
}

Write-Host '==> Platform: ingress and certificates'
# Argo CD installs Envoy Gateway (with the Gateway API definitions) and cert-manager side by side. cert-manager issues
# certificates for a Gateway only when the Gateway API definitions existed when it started: restart it once otherwise.
$deadline = (Get-Date).AddMinutes(15)
while ($true) {
    $definition = kubectl get crd gateways.gateway.networking.k8s.io --ignore-not-found --output json | ConvertFrom-Json
    $pods = @((kubectl get pods --namespace cert-manager --selector 'app.kubernetes.io/component=controller' --ignore-not-found --output json | ConvertFrom-Json).items |
            Where-Object { $_.status.PSObject.Properties['startTime'] })
    if ($definition -and $pods.Count -gt 0) { break }
    if ((Get-Date) -gt $deadline) { throw 'Argo CD did not install the Gateway API definitions and cert-manager within 15 minutes: look at the Applications envoy-gateway and cert-manager.' }
    Start-Sleep -Seconds 10
}
if (@($pods | Where-Object { [datetime] $_.status.startTime -lt [datetime] $definition.metadata.creationTimestamp }).Count -gt 0) {
    kubectl rollout restart deployment --namespace cert-manager --selector 'app.kubernetes.io/component=controller' | Out-Null
    Write-Host 'cert-manager started before the Gateway API definitions existed: restarted.'
}
kubectl rollout status deployment --namespace cert-manager --selector 'app.kubernetes.io/component=controller' --timeout=300s | Out-Null
Write-Host 'PASS Gateway API definitions and cert-manager'

Write-Host '==> Telemetry'
# Capability "telemetry" (system.json environments[].capabilities): infra/cluster.bicep gave the environment its own
# Application Insights, and its app reads the connection string from Secret "telemetry" of its namespace (the
# Deployment names that Secret once the environment's system release says so). The string carries the component's
# instrumentation key and the repository is public, so it goes from Azure to the cluster here and never to Git; it
# reaches kubectl on standard input, not as an argument. An environment without the capability has no such Secret.
foreach ($entry in @($system.environments)) {
    $name = [string] $entry.name
    $namespace = "$slug-$name"
    $exists = [bool] (kubectl get namespace $namespace --ignore-not-found --output name)
    if (@($entry['capabilities']) -notcontains 'telemetry') {
        if ($exists -and (kubectl get secret telemetry --namespace $namespace --ignore-not-found --output name)) {
            kubectl delete secret telemetry --namespace $namespace | Out-Null
            Write-Host "PASS ${name}: telemetry is off; Secret telemetry removed"
        }
        continue
    }
    $connection = "$(az resource show --resource-group $resourceGroup --name "appi-$slug-$name" --resource-type Microsoft.Insights/components --query properties.ConnectionString --output tsv)".Trim()
    if (-not $connection) { throw "appi-$slug-$name in $resourceGroup has no connection string (infra/cluster.bicep creates it for an environment with capability telemetry)." }
    # The environment's first system deployment creates its namespace; before that, this job does.
    if (-not $exists) { kubectl create namespace $namespace --output name | Out-Null }
    @{
        apiVersion = 'v1'
        kind       = 'Secret'
        metadata   = @{ name = 'telemetry'; namespace = $namespace; labels = @{ system = $slug; environment = $name } }
        type       = 'Opaque'
        stringData = @{ 'connection-string' = $connection }
    } | ConvertTo-Json -Depth 5 | kubectl apply --filename - --output name | Out-Null
    Write-Host "PASS ${name}: Secret telemetry holds the connection string of appi-$slug-$name"
}
