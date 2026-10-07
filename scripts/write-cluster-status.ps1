#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Writes what Azure itself says about the system's AKS cluster: its health, whether it runs, its node pools and its
    use of CPU, memory and disk (runtime aks-argocd).

.DESCRIPTION
    Workflow cluster-status of the system repository runs this several times an hour and after every run of workflow system, as the plan identity, a reader of the
    cluster's resource group, and publishes the file as aks.json on branch "cluster-status". The health dashboard reads
    it from the visitor's browser (topology.json cluster.serviceUrl) next to the live status the cluster serves about
    itself: these facts come from outside the cluster, so the page can still say "Azure reports the cluster stopped"
    or "available and running" when the cluster's own status file does not answer.

    From Azure Resource Manager, for the cluster of system.json (cluster.name in azure.resourceGroups.cluster):
      availability   Azure Resource Health's verdict (Available, Unavailable, Degraded or Unknown) with its summary
      powerState, provisioningState, kubernetesVersion, tier, and per node pool its mode, count, size and state
      metrics        the cluster's platform metrics, averaged over the last 15 minutes, in percent: node CPU, memory
                     (working set) and disk, and the CPU and memory of the control plane's API server; each null
                     when Azure has no value (a stopped cluster; the disk metric where Azure does not emit it)
    A fact Azure does not return is null or "Unknown"; only a cluster that cannot be read at all fails the script.

.EXAMPLE
    pwsh -NoProfile -File scripts/write-cluster-status.ps1 -Path aks.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Path,
    [string] $Root = (Split-Path -Parent $PSScriptRoot)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$system = Get-Content -LiteralPath (Join-Path $Root 'system.json') -Raw | ConvertFrom-Json -AsHashtable
$name = [string] $system.cluster.name
$resourceGroup = [string] $system.azure.resourceGroups.cluster
$id = "/subscriptions/$([string] $system.azure.subscriptionId)/resourceGroups/$resourceGroup/providers/Microsoft.ContainerService/managedClusters/$name"

Write-Host "==> $name in $resourceGroup"
$cluster = az aks show --name $name --resource-group $resourceGroup --only-show-errors --output json | ConvertFrom-Json -AsHashtable
$power = if ($cluster['powerState']) { [string] $cluster.powerState['code'] } else { 'Unknown' }
Write-Host "PASS $power, $([string] $cluster['provisioningState']), Kubernetes $([string] $cluster['currentKubernetesVersion'])"

# Resource Health and the metrics are extras: a refusal or an empty answer leaves that part unknown and is said.
$availability = [ordered] @{ state = 'Unknown'; summary = $null; reason = $null; occurredAt = $null }
$PSNativeCommandUseErrorActionPreference = $false
$answer = az rest --method get --url "https://management.azure.com$id/providers/Microsoft.ResourceHealth/availabilityStatuses/current?api-version=2020-05-01" --only-show-errors --output json 2>$null
$code = $LASTEXITCODE
$PSNativeCommandUseErrorActionPreference = $true
if ($code -eq 0 -and $answer) {
    $health = ($answer | Out-String | ConvertFrom-Json -AsHashtable)['properties']
    if ($health) {
        $occurred = $health['occuredTime']
        $availability = [ordered] @{
            state      = if ($health['availabilityState']) { [string] $health.availabilityState } else { 'Unknown' }
            summary    = if ($health['summary']) { [string] $health.summary } else { $null }
            reason     = if ($health['reasonType']) { [string] $health.reasonType } else { $null }
            occurredAt = if ($occurred -is [datetime]) { $occurred.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture) } elseif ($occurred) { [string] $occurred } else { $null }
        }
    }
    Write-Host "PASS Resource Health: $($availability.state)"
}
else {
    Write-Host "SKIP Resource Health did not answer (exit code $code): the verdict is Unknown"
}

$windowMinutes = 15
$names = [ordered] @{
    nodeCpuPercent         = 'node_cpu_usage_percentage'
    nodeMemoryPercent      = 'node_memory_working_set_percentage'
    nodeDiskPercent        = 'node_disk_usage_percentage'
    apiServerCpuPercent    = 'apiserver_cpu_usage_percentage'
    apiServerMemoryPercent = 'apiserver_memory_usage_percentage'
}
$metrics = [ordered] @{ windowMinutes = $windowMinutes }
foreach ($key in $names.Keys) { $metrics[$key] = $null }
$start = [datetime]::UtcNow.AddMinutes(-$windowMinutes).ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
$PSNativeCommandUseErrorActionPreference = $false
$answer = az monitor metrics list --resource $id --metrics @($names.Values) --aggregation Average --interval PT5M --start-time $start --only-show-errors --output json 2>$null
$code = $LASTEXITCODE
$PSNativeCommandUseErrorActionPreference = $true
if ($code -eq 0 -and $answer) {
    foreach ($metric in @(($answer | Out-String | ConvertFrom-Json -AsHashtable)['value'] | Where-Object { $_ })) {
        $key = @($names.Keys | Where-Object { $names[$_] -eq [string] $metric.name.value }) | Select-Object -First 1
        $values = @($metric['timeseries'] | Where-Object { $_ } | ForEach-Object { $_['data'] } | Where-Object { $_ -and $null -ne $_['average'] } | ForEach-Object { [double] $_.average })
        if ($key -and $values.Count -gt 0) { $metrics[$key] = [math]::Round(($values | Measure-Object -Average).Average, 1) }
    }
    $said = @($names.Keys | ForEach-Object { "$_ $(if ($null -eq $metrics[$_]) { 'none' } else { $metrics[$_] })" }) -join ', '
    Write-Host "PASS metrics of the last $windowMinutes minutes: $said"
}
else {
    Write-Host "SKIP the metrics did not answer (exit code $code): each is null"
}

$status = [ordered] @{
    generated         = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
    name              = $name
    resourceGroup     = $resourceGroup
    location          = [string] $cluster['location']
    availability      = $availability
    powerState        = $power
    provisioningState = [string] $cluster['provisioningState']
    kubernetesVersion = [string] $cluster['currentKubernetesVersion']
    tier              = if ($cluster['sku']) { [string] $cluster.sku['tier'] } else { $null }
    pools             = @($cluster['agentPoolProfiles'] | Where-Object { $_ } | ForEach-Object {
            [ordered] @{
                name              = [string] $_['name']
                mode              = [string] $_['mode']
                count             = [int] $_['count']
                size              = [string] $_['vmSize']
                osDiskGb          = if ($_['osDiskSizeGb']) { [int] $_.osDiskSizeGb } else { $null }
                powerState        = if ($_['powerState']) { [string] $_.powerState['code'] } else { 'Unknown' }
                provisioningState = [string] $_['provisioningState']
                kubernetesVersion = [string] $_['currentOrchestratorVersion']
            }
        })
    metrics           = $metrics
}
$status | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Path -Encoding utf8NoBOM
Write-Host "PASS $Path written"
