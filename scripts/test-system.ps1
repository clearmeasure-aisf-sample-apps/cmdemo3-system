#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Checks system.json and the gitops/ files that follow from it (runtime aks-argocd).

.DESCRIPTION
    Run by env-checks on every pull request and by the demo-environment skill before the first push. One PASS or FAIL
    line per rule; exits 1 when a rule fails. The rules: the names system.json may hold, who signs off
    (octopus.approvers, octopus.operator), the cluster and SQL settings, and for every environment its Argo CD
    Applications and its folders under gitops/environments, with no folder for an environment system.json does not
    declare.

.EXAMPLE
    pwsh -NoProfile -File scripts/test-system.ps1
#>
[CmdletBinding()]
param(
    [string] $Root = (Split-Path -Parent $PSScriptRoot)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$failures = [Collections.Generic.List[string]]::new()
function Test-Rule {
    param([string] $Name, [bool] $Condition, [string] $Detail = '')
    if ($Condition) {
        Write-Host "PASS $Name"
    }
    else {
        Write-Host "FAIL $Name$(if ($Detail) { ": $Detail" })"
        $failures.Add($Name)
    }
}

$system = Get-Content -LiteralPath (Join-Path $Root 'system.json') -Raw | ConvertFrom-Json -AsHashtable
$slug = [string] $system.system.slug
Test-Rule 'slug' ($slug -cmatch '^[a-z][a-z0-9]{2,9}$') "'$slug' must be 3 to 10 lowercase letters and digits, starting with a letter"
Test-Rule 'runtime' ([string] $system.system['runtime'] -ceq 'aks-argocd') 'system.runtime must be aks-argocd in this repository'

# Who signs off (octopus/approvers.tf): octopus.approvers, the people in the space team "<slug> approvers" by Octopus
# username or email address ([] or left out: only automation signs off), and octopus.operator, the operator identity
# that answers a sign-off with a recorded reason ("ai-ops" when left out).
if ($system.octopus.ContainsKey('approvers')) {
    $approvers = $system.octopus.approvers
    $valid = $approvers -is [array] -and @($approvers | Where-Object { $_ -isnot [string] -or $_ -cnotmatch '^\S(?:.*\S)?$' }).Count -eq 0
    Test-Rule 'octopus.approvers' $valid 'a list of Octopus usernames or email addresses ([] when only automation signs off)'
    if ($valid) {
        $logins = @($approvers | ForEach-Object { $_.ToLowerInvariant() })
        Test-Rule 'octopus.approvers each once' (@($logins | Select-Object -Unique).Count -eq $logins.Count) 'a username or email address appears twice (Octopus compares them without case)'
        Test-Rule 'octopus.approvers without the service account' ($logins -notcontains "$slug-github") "$slug-github applies the configuration; the people who sign off are others"
    }
}
if ($system.octopus.ContainsKey('operator')) {
    Test-Rule 'octopus.operator' ($system.octopus.operator -is [string] -and $system.octopus.operator -cmatch '^\S(?:.*\S)?$') 'the Octopus username of the operator identity, for example ai-ops'
}

$cluster = if ($system.ContainsKey('cluster')) { $system.cluster } else { @{} }
foreach ($key in 'name', 'nodeSize', 'domain', 'ingressIp', 'ingressPublicIpName') {
    Test-Rule "cluster.$key" (-not [string]::IsNullOrWhiteSpace([string] $cluster[$key]))
}
Test-Rule 'cluster.nodeCount' ($cluster['nodeCount'] -is [long] -and $cluster.nodeCount -ge 1 -and $cluster.nodeCount -le 5) '1 to 5 nodes'
Test-Rule 'sql.edition' ($system.ContainsKey('sql') -and @('Express', 'Developer') -ccontains [string] $system.sql['edition']) 'Express or Developer'
Test-Rule 'cluster resource group' (-not [string]::IsNullOrWhiteSpace([string] $system.azure.resourceGroups['cluster']))
foreach ($identity in 'cluster', 'aks', 'kubelet', 'feed', 'backup') {
    Test-Rule "identity $identity" ($system.azure.identities.ContainsKey($identity)) 'the seed creates it; run phase 2 again'
}

Test-Rule 'backup storage' ($system.azure.ContainsKey('backup') -and -not [string]::IsNullOrWhiteSpace([string] $system.azure.backup['storageAccount']) -and -not [string]::IsNullOrWhiteSpace([string] $system.azure.backup['container'])) 'azure.backup.storageAccount and container: the seed creates them; run phase 2 again'
$deployableNames = @($system.deployables | ForEach-Object { [string] $_.name })
Test-Rule 'deployables present' ($deployableNames.Count -gt 0)
foreach ($name in $deployableNames) {
    Test-Rule "deployable $name name" ($name -cmatch '^[a-z](?:[a-z0-9]|-(?=[a-z0-9])){1,9}$') 'lowercase letters, digits and inner hyphens, 2 to 10'
    Test-Rule "deployable $name is not 'system'" ($name -cne 'system') 'the Octopus project <slug>-system is the environments project'
    Test-Rule "deployable $name templates" (Test-Path -LiteralPath (Join-Path $Root 'gitops' 'templates' 'environment' 'apps' $name 'deployment.yaml')) 'run scripts/write-gitops.ps1'
}
Test-Rule 'deployable names unique' (@($deployableNames | Select-Object -Unique).Count -eq $deployableNames.Count)

$environmentNames = @($system.environments | ForEach-Object { [string] $_.name })
Test-Rule 'environments present' ($environmentNames.Count -gt 0)
Test-Rule 'environment names unique' (@($environmentNames | Select-Object -Unique).Count -eq $environmentNames.Count)
foreach ($environment in $system.environments) {
    $name = [string] $environment.name
    Test-Rule "environment $name name" ($name -cmatch '^[a-z][a-z0-9]{1,7}$') 'lowercase letters and digits, 2 to 8'
    Test-Rule "environment $name tier" (@('nonprod', 'prod') -ccontains [string] $environment.tier)
    Test-Rule "environment $name is not 'argocd'" ($name -cne 'argocd') 'the ingress listener https-argocd is the Argo CD web UI'
    if ($environment.ContainsKey('appCpu')) {
        Test-Rule "environment $name appCpu" (@('0.5', '1', '1.5', '2') -contains [string] $environment.appCpu) '0.5, 1, 1.5 or 2'
    }
    Test-Rule "environment $name Applications" (Test-Path -LiteralPath (Join-Path $Root 'gitops' 'argocd' 'apps' "environment-$name.yaml")) 'run scripts/write-gitops.ps1'
    Test-Rule "environment $name folder" (Test-Path -LiteralPath (Join-Path $Root 'gitops' 'environments' $name 'system' 'kustomization.yaml')) 'run scripts/write-gitops.ps1'
    foreach ($deployableName in $deployableNames) {
        Test-Rule "environment $name pin of $deployableName" (Test-Path -LiteralPath (Join-Path $Root 'gitops' 'environments' $name $deployableName 'kustomization.yaml')) 'run scripts/write-gitops.ps1'
    }
}

$environmentsFolder = Join-Path $Root 'gitops' 'environments'
if (Test-Path -LiteralPath $environmentsFolder) {
    foreach ($folder in Get-ChildItem -Path $environmentsFolder -Directory) {
        Test-Rule "folder gitops/environments/$($folder.Name) is declared" ($environmentNames -contains $folder.Name) 'add it to system.json or remove the folder'
    }
}
foreach ($file in Get-ChildItem -Path (Join-Path $Root 'gitops' 'argocd' 'apps') -Filter 'environment-*.yaml' -ErrorAction SilentlyContinue) {
    $name = $file.BaseName -replace '^environment-', ''
    Test-Rule "Applications of $name are declared" ($environmentNames -contains $name) 'add the environment to system.json or remove the file'
}

if ($failures.Count -gt 0) {
    Write-Host "$($failures.Count) check(s) failed."
    exit 1
}
Write-Host 'All system checks passed.'
