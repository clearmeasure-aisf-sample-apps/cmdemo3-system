#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Verifies that an environment's SQL Server runs and its deployables answer over HTTPS.

.DESCRIPTION
    Last step of every Octopus project of the system ("Verify environment" in <slug>-system, "Verify deployable" in
    <slug>-<deployable>), on the Kubernetes worker in the cluster; octopus/projects.tf inlines this file.
      <slug>-system        SQL Server's pod is ready, and every deployable of System.Deployables answers 200 at its
                           public URL: at its health path once a version runs, at / while the placeholder image runs.
      <slug>-<deployable>  (Deployable.Name is set) the Deployment runs the release's version with every replica
                           available, and the health path answers 200.
    The deadline covers a first start: the image pull, the certificate of a new host name, the database. A pod that
    cannot start fails the step at once with the reason Kubernetes gives.
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
$only = [string] $OctopusParameters['Deployable.Name']
$release = [string] $OctopusParameters['Octopus.Release.Number']
# The tag the deployment pins: the image's package version (usually, not always, the release number).
$wantedTag = if ($only) { [string] $OctopusParameters["Octopus.Action[Update deployable].Package[$only].PackageVersion"] } else { '' }
if (-not $wantedTag) { $wantedTag = $release }
$namespace = "$slug-$environmentName"
$baseUrl = "https://$slug-$environmentName.$domain"
$deadline = (Get-Date).AddMinutes(15)
$deployables = @(([string] $OctopusParameters['System.Deployables']) | ConvertFrom-Json | Where-Object { -not $only -or $_.name -eq $only })
if ($deployables.Count -eq 0) {
    Fail-Step "System.Deployables lists no deployable$(if ($only) { " named $only" })."
}

function Get-PodProblem {
    # A container that cannot start: the reason Kubernetes gives (image pull, crash loop), or nothing.
    param([string] $Selector)
    $pods = @((kubectl get pods --namespace $namespace --selector $Selector --output json | ConvertFrom-Json).items)
    foreach ($pod in $pods) {
        foreach ($status in @($pod.status.PSObject.Properties['containerStatuses'] ? $pod.status.containerStatuses : @())) {
            $waiting = $status.state.PSObject.Properties['waiting'] ? $status.state.waiting : $null
            if ($waiting -and @('ImagePullBackOff', 'ErrImagePull', 'CrashLoopBackOff', 'CreateContainerConfigError', 'InvalidImageName') -contains $waiting.reason) {
                return "pod $($pod.metadata.name): $($waiting.reason) $($waiting.PSObject.Properties['message'] ? $waiting.message : '')".Trim()
            }
        }
    }
    return $null
}

if (-not $only) {
    Write-Host "Waiting for SQL Server of $environmentName."
    while ($true) {
        $set = kubectl get statefulset db --namespace $namespace --ignore-not-found --output json | ConvertFrom-Json
        $ready = if ($set -and $set.status.PSObject.Properties['readyReplicas']) { [int] $set.status.readyReplicas } else { 0 }
        if ($ready -ge 1) { break }
        $problem = Get-PodProblem -Selector 'app.kubernetes.io/name=db'
        if ($problem) { Fail-Step "SQL Server of $environmentName cannot start: $problem" }
        if ((Get-Date) -gt $deadline) { Fail-Step "SQL Server of $environmentName is not ready (StatefulSet db in $namespace)." }
        Start-Sleep -Seconds 10
    }
    Write-Host "SQL Server of $environmentName is ready."
}

foreach ($deployable in $deployables) {
    $name = [string] $deployable.name
    $path = '/'
    Write-Host "Waiting for $name in $environmentName."
    while ($true) {
        $deployment = kubectl get deployment $name --namespace $namespace --ignore-not-found --output json | ConvertFrom-Json
        if ($deployment) {
            $tag = ([string] $deployment.spec.template.spec.containers[0].image) -replace '^.*:', ''
            $wanted = [int] $deployment.spec.replicas
            $status = $deployment.status
            $updated = $status.PSObject.Properties['updatedReplicas'] ? [int] $status.updatedReplicas : 0
            $available = $status.PSObject.Properties['availableReplicas'] ? [int] $status.availableReplicas : 0
            $total = $status.PSObject.Properties['replicas'] ? [int] $status.replicas : 0
            $rolledOut = $updated -eq $wanted -and $available -eq $wanted -and $total -eq $wanted
            if ($rolledOut -and (-not $only -or $tag -eq $wantedTag)) {
                $path = if ($tag -eq '0.0.0-placeholder') { '/' } else { [string] $deployable.healthPath }
                break
            }
        }
        $problem = Get-PodProblem -Selector "app.kubernetes.io/name=$name"
        if ($problem) { Fail-Step "$name of $environmentName cannot start: $problem" }
        if ((Get-Date) -gt $deadline) {
            Fail-Step "$name of $environmentName did not roll out$(if ($only) { " image tag $wantedTag" }) (Deployment $name in $namespace)."
        }
        Start-Sleep -Seconds 10
    }

    $url = "$baseUrl$path"
    $reason = ''
    while ($true) {
        try {
            $response = Invoke-WebRequest -Uri $url -TimeoutSec 20 -SkipHttpErrorCheck
            if ($response.StatusCode -eq 200) { break }
            $reason = "HTTP $($response.StatusCode)"
        }
        catch {
            $reason = $_.Exception.Message
        }
        if ((Get-Date) -gt $deadline) { Fail-Step "$url did not answer 200: $reason" }
        Start-Sleep -Seconds 10
    }
    Write-Highlight "$name of $environmentName answers at $url (image tag $tag)."
}
