#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Reports whether every deployable of an environment answers at its public address (runtime aks-argocd).

.DESCRIPTION
    Runbook "Health report" of <slug>-system, hourly in every environment, on the Kubernetes worker in the cluster;
    octopus/runbooks.tf inlines this file. Capability CAP-076: the runbook's last run per environment is green or red
    in Octopus. One line per deployable of System.Deployables, at https://<slug>-<env><suffix>.<cluster.domain>: an
    app is asked /alive (does the process answer; the health check with its database is the deployments' business)
    and /_version, a static site its start page. Three attempts each. The run fails when one does not answer 200.
    The last line names the health dashboard, when the system has one.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$ProgressPreference = 'SilentlyContinue'

$environmentName = [string] $OctopusParameters['Octopus.Environment.Name']
$slug = [string] $OctopusParameters['System.Slug']
$domain = [string] $OctopusParameters['Cluster.Domain']
$deployables = @(([string] $OctopusParameters['System.Deployables']) | ConvertFrom-Json)
if ($deployables.Count -eq 0) { Fail-Step 'System.Deployables lists no deployable.' }

function Get-Answer {
    # The status of a GET (0: no answer) and how long it took, after at most three attempts 10 seconds apart.
    param([string] $Uri)
    for ($attempt = 1; ; $attempt++) {
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $status = try { [int] (Invoke-WebRequest -Uri $Uri -TimeoutSec 30 -SkipHttpErrorCheck).StatusCode } catch { 0 }
        if ($status -eq 200 -or $attempt -ge 3) { return @{ Status = $status; Milliseconds = [int] $clock.ElapsedMilliseconds } }
        Start-Sleep -Seconds 10
    }
}

$unhealthy = 0
$dashboard = ''
foreach ($deployable in $deployables) {
    $name = [string] $deployable.name
    $suffix = $deployable.PSObject.Properties['hostSuffix'] ? [string] $deployable.hostSuffix : ''
    $static = $deployable.PSObject.Properties['hosting'] -and [string] $deployable.hosting -eq 'staticsite'
    $url = "https://$slug-$environmentName$suffix.$domain"
    if ($static -and -not $dashboard) { $dashboard = $url }
    $answer = Get-Answer -Uri "$url$(if ($static) { '/' } else { '/alive' })"
    $note = ''
    if (-not $static -and $answer.Status -eq 404) {
        # No release yet: the placeholder image answers on its start page only.
        $answer = Get-Answer -Uri "$url/"
        $note = ', no release yet'
    }
    $version = ''
    if (-not $static -and -not $note -and $answer.Status -eq 200) {
        $version = try { ([string] (Invoke-RestMethod -Uri "$url/_version" -TimeoutSec 30).version) -replace '\+.*$', '' } catch { '' }
    }
    $healthy = $answer.Status -eq 200
    if (-not $healthy) { $unhealthy++ }
    $state = if ($healthy) { 'Healthy' } elseif ($answer.Status -eq 0) { 'Unreachable' } else { 'Unhealthy' }
    $kind = if ($static) { 'static site' } else { 'app' }
    $line = "$state  $name in ${environmentName}, ${kind}: $(if ($answer.Status) { "HTTP $($answer.Status) in $($answer.Milliseconds) ms" } else { 'no answer' })$(if ($version) { ", version $version" })$note  $url"
    # An unhealthy deployable is this run's result, said once by the failure below: its line is information.
    if ($healthy) { Write-Highlight $line } else { Write-Host $line }
}
if ($dashboard) { Write-Highlight "Live view of every node of every environment: $dashboard" }
if ($unhealthy -gt 0) {
    Fail-Step "$unhealthy of $($deployables.Count) deployable(s) of $environmentName are not healthy."
}
Write-Highlight "All $($deployables.Count) deployable(s) of $environmentName are healthy."
