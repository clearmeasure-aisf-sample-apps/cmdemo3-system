#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    After a failed deployment and its revert, asks whether the deployable is in service: every replica available, and
    its health path answering over HTTPS.

.DESCRIPTION
    Step "Verify revert" of the Octopus project <slug>-<deployable> (runtime aks-argocd), right after "Revert pin" and,
    like it, only when an earlier step failed; on the Kubernetes worker in the cluster; octopus/projects.tf inlines
    this file. "Revert pin" commits the previous tag back and waits until the Deployment runs it; this step then asks
    what a user would: the public address, at the health path. A rollback nobody verifies can leave an environment
    down while the deployment reads as rolled back (the kit's decision 0018).

    It verifies whatever the environment runs after the failure, also when "Revert pin" had nothing to revert (a step
    before the pin failed, or the release redeployed is the one that ran) and when "Revert pin" itself failed: the
    Deployment's image tag is named in the result, and it is not compared with a tag, because which one is right is
    the pin's business and Git's.
      1. No Deployment of that name in the namespace (a first deployment that failed before Argo CD created it):
         nothing ran before, nothing is asked.
      2. Waits, five minutes at most, until the Deployment has every replica updated and available. A pod that cannot
         start fails the step at once with the reason Kubernetes gives.
      3. Asks https://<host>/<healthPath> until it answers 200 (at / while the placeholder image runs), within the
         same five minutes.
    A failure here says the environment is down after the revert, which the failed deployment alone does not say. The
    step reads the cluster and the public address only: it needs no GitHub credential.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandArgumentPassing = 'Standard'
$PSNativeCommandUseErrorActionPreference = $true
$ProgressPreference = 'SilentlyContinue'

$environmentName = [string] $OctopusParameters['Octopus.Environment.Name']
$slug = [string] $OctopusParameters['System.Slug']
$domain = [string] $OctopusParameters['Cluster.Domain']
$name = [string] $OctopusParameters['Deployable.Name']
$namespace = "$slug-$environmentName"
$deployable = @(([string] $OctopusParameters['System.Deployables']) | ConvertFrom-Json | Where-Object { $_.name -eq $name }) | Select-Object -First 1
if (-not $deployable) {
    Fail-Step "System.Deployables lists no deployable named $name."
}
# The deployable's public address: the first one has the environment's own host name, every other one
# <slug>-<env>-<name> (System.Deployables hostSuffix), as scripts/verify-environment.ps1 reads it.
$suffix = $deployable.PSObject.Properties['hostSuffix'] ? [string] $deployable.hostSuffix : ''
$base = "https://$slug-$environmentName$suffix.$domain"
$deadline = (Get-Date).AddMinutes(5)

function Get-PodProblem {
    # A container that cannot start: the reason Kubernetes gives (image pull, crash loop), or nothing.
    param([string] $Selector)
    $pods = @((kubectl get pods --namespace $namespace --selector $Selector --output json | ConvertFrom-Json).items)
    foreach ($pod in $pods) {
        foreach ($status in @($pod.status.PSObject.Properties['containerStatuses'] ? $pod.status.containerStatuses : @())) {
            $waiting = $status.state.PSObject.Properties['waiting'] ? $status.state.waiting : $null
            if ($waiting -and @('ImagePullBackOff', 'ErrImagePull', 'CrashLoopBackOff', 'CreateContainerConfigError', 'CreateContainerError', 'InvalidImageName') -contains $waiting.reason) {
                return "pod $($pod.metadata.name) ($(([string] $status.image) -replace '^.*:', '')): $($waiting.reason) $($waiting.PSObject.Properties['message'] ? $waiting.message : '')".Trim()
            }
        }
    }
    return $null
}

if (-not (kubectl get deployment $name --namespace $namespace --ignore-not-found --output name)) {
    Write-Highlight "$name has no Deployment in $environmentName yet: nothing ran before this deployment, nothing to verify."
    return
}

Write-Host "Waiting for every replica of $name in $environmentName."
$tag = ''
while ($true) {
    $deployment = kubectl get deployment $name --namespace $namespace --output json | ConvertFrom-Json
    $tag = ([string] $deployment.spec.template.spec.containers[0].image) -replace '^.*:', ''
    $wanted = [int] $deployment.spec.replicas
    $status = $deployment.status
    $updated = $status.PSObject.Properties['updatedReplicas'] ? [int] $status.updatedReplicas : 0
    $available = $status.PSObject.Properties['availableReplicas'] ? [int] $status.availableReplicas : 0
    $total = $status.PSObject.Properties['replicas'] ? [int] $status.replicas : 0
    if ($updated -eq $wanted -and $available -eq $wanted -and $total -eq $wanted) { break }
    $problem = Get-PodProblem -Selector "app.kubernetes.io/name=$name"
    if ($problem) { Fail-Step "After the revert, $name of $environmentName is not in service: $problem" }
    if ((Get-Date) -gt $deadline) {
        Fail-Step "After the revert, $name of $environmentName is not in service: Deployment $name in $namespace (image tag $tag) has $available of $wanted replica(s) available."
    }
    Start-Sleep -Seconds 10
}

$path = if ($tag -eq '0.0.0-placeholder') { '/' } else { [string] $deployable.healthPath }
$url = "$base$path"
$reason = ''
while ($true) {
    try {
        $response = Invoke-WebRequest -Uri $url -TimeoutSec 20 -SkipHttpErrorCheck
        if ($response.StatusCode -eq 200) { break }
        $reason = "HTTP $($response.StatusCode)"
    }
    catch {
        $reason = (("$($_.Exception.Message)" -split '\r?\n')[0]).Trim()
    }
    if ((Get-Date) -gt $deadline) { Fail-Step "After the revert, $name of $environmentName does not answer: $url gave $reason (image tag $tag, every replica available)." }
    Start-Sleep -Seconds 10
}
Write-Highlight "After the revert, $name of $environmentName is in service: $url answers 200 (image tag $tag, every replica available)."
