#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Measures the availability of an environment's apps while an Argo CD step changes it, and fails on downtime.

.DESCRIPTION
    Step "Measure availability" (runtime aks-argocd), on the Kubernetes worker in the cluster, started together with
    the Argo CD step it watches; octopus/projects.tf inlines this file. Capability CAP-044.
      <slug>-<deployable>  next to "Update deployable": until the Deployment runs the pinned tag with every replica
                           available, then 15 seconds more (the old pods go away); at most 7 minutes. When the new
                           pods cannot start, it stops once that is clear: "Update deployable" fails for it.
      <slug>-system        next to "Apply environment": at least 90 seconds (Argo CD finds the commit within one
                           minute), then until every Deployment and StatefulSet of the namespace has been rolled out
                           and steady for 30 seconds; at most 15 minutes.
    Every 3 seconds it asks each app's health path at its public address. Before an app's first 200 (a new
    environment, the placeholder image) nothing counts; after it, two checks in a row without a 200 (about 6 seconds)
    are a downtime period, and any downtime fails the step. The log gives each app's checks and when it answered.
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
$tag = if ($only) { [string] $OctopusParameters["Octopus.Action[Update deployable].Package[$only].PackageVersion"] } else { '' }
if (-not $tag) { $tag = $release }
$namespace = "$slug-$environmentName"
$baseUrl = "https://$slug-$environmentName.$domain"
$deployables = @(([string] $OctopusParameters['System.Deployables']) | ConvertFrom-Json | Where-Object { -not $only -or $_.name -eq $only })
$started = Get-Date
$deadline = $started.AddMinutes($(if ($only) { 7 } else { 15 }))

function Get-Workload {
    # The namespace's Deployments and StatefulSets: name, image tag, and whether the latest spec is rolled out.
    $items = @((kubectl get deployments,statefulsets --namespace $namespace --output json | ConvertFrom-Json).items)
    foreach ($item in $items) {
        $status = $item.status
        $wanted = [int] $item.spec.replicas
        $ready = $status.PSObject.Properties['readyReplicas'] ? [int] $status.readyReplicas : 0
        $updated = $status.PSObject.Properties['updatedReplicas'] ? [int] $status.updatedReplicas : 0
        $total = $status.PSObject.Properties['replicas'] ? [int] $status.replicas : 0
        $observed = $status.PSObject.Properties['observedGeneration'] ? [long] $status.observedGeneration : 0
        [pscustomobject] @{
            Name     = "$($item.kind)/$($item.metadata.name)"
            Short    = [string] $item.metadata.name
            Tag      = ([string] $item.spec.template.spec.containers[0].image) -replace '^.*:', ''
            Done     = $observed -ge [long] $item.metadata.generation -and $ready -eq $wanted -and $updated -eq $wanted -and $total -eq $wanted
        }
    }
}

function Test-StartProblem {
    # True when a pod of the deployable cannot start (image pull, crash loop).
    param([string] $Name)
    $pods = @((kubectl get pods --namespace $namespace --selector "app.kubernetes.io/name=$Name" --output json | ConvertFrom-Json).items)
    foreach ($pod in $pods) {
        foreach ($status in @($pod.status.PSObject.Properties['containerStatuses'] ? $pod.status.containerStatuses : @())) {
            $waiting = $status.state.PSObject.Properties['waiting'] ? $status.state.waiting : $null
            if ($waiting -and @('ImagePullBackOff', 'ErrImagePull', 'CrashLoopBackOff', 'CreateContainerConfigError', 'CreateContainerError', 'InvalidImageName') -contains $waiting.reason) { return $true }
        }
    }
    return $false
}

$samples = [Collections.Generic.List[object]]::new()
$tick = 0
$doneSince = $null
$problemSince = $null
$stopReason = ''
$lastLook = [datetime]::MinValue
while ($true) {
    $tick++
    $now = Get-Date
    if (($now - $lastLook).TotalSeconds -ge 10) {
        $lastLook = $now
        $workload = @(Get-Workload)
        if ($only) {
            $mine = @($workload | Where-Object { $_.Name -eq "Deployment/$only" })
            $done = $mine.Count -eq 1 -and $mine[0].Tag -eq $tag -and $mine[0].Done
            if (Test-StartProblem -Name $only) { if (-not $problemSince) { $problemSince = $now } } else { $problemSince = $null }
            if ($problemSince -and ($now - $problemSince).TotalSeconds -ge 30) { $stopReason = "the new pods of $only cannot start (Update deployable reports it)"; break }
            $settle = 15
        }
        else {
            $done = ($now - $started).TotalSeconds -ge 90 -and @($workload | Where-Object { -not $_.Done }).Count -eq 0
            $settle = 30
        }
        if ($done) { if (-not $doneSince) { $doneSince = $now } } else { $doneSince = $null }
        if ($doneSince -and ($now - $doneSince).TotalSeconds -ge $settle) { $stopReason = 'rolled out and steady'; break }
    }
    if ($now -gt $deadline) { $stopReason = "the limit of $([int] ($deadline - $started).TotalMinutes) minutes"; break }
    foreach ($deployable in $deployables) {
        $name = [string] $deployable.name
        $mine = @($workload | Where-Object { $_.Name -eq "Deployment/$name" })
        # The placeholder image of a new environment has no health path: its page answers on /.
        $path = if ($mine.Count -eq 1 -and $mine[0].Tag -eq '0.0.0-placeholder') { '/' } else { [string] $deployable.healthPath }
        $failure = ''
        $status = try { [int] (Invoke-WebRequest -Uri "$baseUrl$path" -TimeoutSec 10 -SkipHttpErrorCheck).StatusCode } catch { $failure = $_.Exception.Message; 0 }
        $samples.Add([pscustomobject] @{ Tick = $tick; Time = Get-Date; Deployable = $name; Status = $status; Failure = $failure })
    }
    Start-Sleep -Seconds 3
}
Write-Host "Measured from $($started.ToString('HH:mm:ss')) to $((Get-Date).ToString('HH:mm:ss')): stopped at $stopReason."

$downtimes = 0
foreach ($group in @($samples | Group-Object Deployable)) {
    $ordered = @($group.Group | Sort-Object Tick)
    $own = 0
    $seenHealthy = $false
    $missed = 0
    $gapStart = $null
    $lastFailure = ''
    foreach ($sample in $ordered) {
        if ($sample.Status -eq 200) {
            if ($missed -ge 2) {
                $own++
                Write-Host "Downtime of $($group.Name): no 200 from $($gapStart.ToString('HH:mm:ss')) to $($sample.Time.ToString('HH:mm:ss')) ($lastFailure)"
            }
            $seenHealthy = $true
            $missed = 0
        }
        elseif ($seenHealthy) {
            if ($missed -eq 0) { $gapStart = $sample.Time }
            $missed++
            $lastFailure = if ($sample.Failure) { $sample.Failure } else { "HTTP $($sample.Status)" }
        }
    }
    if ($seenHealthy -and $missed -ge 2) {
        $own++
        Write-Host "Downtime of $($group.Name): no 200 from $($gapStart.ToString('HH:mm:ss')) to the end of the measurement ($lastFailure)"
    }
    $healthy = @($ordered | Where-Object Status -eq 200)
    $summary = if (-not $seenHealthy) { 'not available yet (nothing to keep up)' } else { "answered 200 from $($healthy[0].Time.ToString('HH:mm:ss')) to $($healthy[-1].Time.ToString('HH:mm:ss'))" }
    $downtimes += $own
    Write-Highlight "Availability of $($group.Name) in ${environmentName}: $($ordered.Count) checks, $(if ($own) { "$own downtime period(s)" } else { 'no downtime' }); $summary"
}
if ($downtimes -gt 0) {
    Fail-Step "The change caused $downtimes downtime period(s) in $environmentName; the timeline is above."
}
