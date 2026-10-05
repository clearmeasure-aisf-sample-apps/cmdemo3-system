#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    When a deployment fails, names why the new version cannot start and puts the previous image tag back in Git.

.DESCRIPTION
    Step "Revert pin" of the Octopus project <slug>-<deployable> (runtime aks-argocd), which runs only when an earlier
    step failed, on the Kubernetes worker in the cluster; octopus/projects.tf inlines this file. Step "Update
    deployable" commits the release's tag to gitops/environments/<env>/<deployable>/kustomization.yaml before Argo CD
    rolls it out; when the rollout does not become healthy (or a step before it fails), this step:
      1. Logs the reason Kubernetes gives for the new pods (image pull, crash loop) and the last lines of a crashed
         container, so the failed deployment says why.
      2. Commits the tag of the release that ran before (Octopus.Release.CurrentForEnvironment.Number, the placeholder
         when there was none) back to the file, so Git again names what runs. Argo CD rolls back to it; the old pods
         kept serving meanwhile (maxUnavailable 0).
      3. Waits until the Deployment runs that tag with every replica available.
    It changes nothing when the file does not pin this release (the step before it never committed, or a later
    deployment moved it). The commit goes through the GitHub API with GitHub.Token, as the pin commits of the other
    runtime do; the token is never printed or passed as an argument.
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
$repository = [string] $OctopusParameters['System.Repository']
$deployable = [string] $OctopusParameters['Deployable.Name']
$release = [string] $OctopusParameters['Octopus.Release.Number']
$deployment = [string] $OctopusParameters['Octopus.Deployment.Id']
$previous = [string] $OctopusParameters['Octopus.Release.CurrentForEnvironment.Number']
if (-not $previous -or $previous -eq $release) { $previous = '0.0.0-placeholder' }
$namespace = "$slug-$environmentName"

function Get-PodProblem {
    # A container that cannot start: the reason Kubernetes gives (image pull, crash loop), or nothing.
    param([string] $Selector)
    $pods = @((kubectl get pods --namespace $namespace --selector $Selector --output json | ConvertFrom-Json).items)
    foreach ($pod in $pods) {
        foreach ($status in @($pod.status.PSObject.Properties['containerStatuses'] ? $pod.status.containerStatuses : @())) {
            $waiting = $status.state.PSObject.Properties['waiting'] ? $status.state.waiting : $null
            if ($waiting -and @('ImagePullBackOff', 'ErrImagePull', 'CrashLoopBackOff', 'CreateContainerConfigError', 'CreateContainerError', 'InvalidImageName') -contains $waiting.reason) {
                return @{ pod = [string] $pod.metadata.name; text = "pod $($pod.metadata.name) ($(([string] $status.image) -replace '^.*:', '')): $($waiting.reason) $($waiting.PSObject.Properties['message'] ? $waiting.message : '')".Trim() }
            }
        }
    }
    return $null
}

# 1. Why the new version did not run.
$problem = Get-PodProblem -Selector "app.kubernetes.io/name=$deployable"
if ($problem) {
    Write-Highlight "$deployable $release in $environmentName cannot start: $($problem.text)"
    $PSNativeCommandUseErrorActionPreference = $false
    $lines = @(kubectl logs $problem.pod --namespace $namespace --previous --tail 20 2>$null)
    $PSNativeCommandUseErrorActionPreference = $true
    if ($lines.Count -gt 0) {
        Write-Host "Last lines of the crashed container:"
        $lines | ForEach-Object { Write-Host "  $_" }
    }
}
else {
    Write-Host "No pod of $deployable in $namespace reports a start problem; the reason is in the failed step above."
}

# 2. The previous tag back in Git, unless the file does not pin this release.
$path = "gitops/environments/$environmentName/$deployable/kustomization.yaml"
$uri = "https://api.github.com/repos/$repository/contents/$path"
$headers = @{
    Authorization          = "Bearer $([string] $OctopusParameters['GitHub.Token'])"
    Accept                 = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
}
$reverted = $false
for ($attempt = 1; $attempt -le 4; $attempt++) {
    $file = Invoke-RestMethod -Uri "${uri}?ref=main" -Headers $headers
    $text = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($file.content -replace '\s', '')))
    $pinned = [regex]::Match($text, '(?m)^(\s*newTag:\s*)"?([^"\s]+)"?\s*$')
    if (-not $pinned.Success -or $pinned.Groups[2].Value -ne $release) {
        Write-Highlight "$path does not pin $deployable $release$(if ($pinned.Success) { " (it pins $($pinned.Groups[2].Value))" }): nothing to revert."
        break
    }
    $content = $text.Substring(0, $pinned.Index) + "$($pinned.Groups[1].Value)`"$previous`"" + $text.Substring($pinned.Index + $pinned.Length)
    $body = @{
        message = "Revert pin of $deployable $release in $environmentName ($deployment failed)"
        content = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($content))
        branch  = 'main'
        sha     = $file.sha
    }
    try {
        $commit = Invoke-RestMethod -Uri $uri -Method Put -Headers $headers -Body ($body | ConvertTo-Json) -ContentType 'application/json'
        Write-Highlight "Reverted $deployable in $environmentName to ${previous}: $($commit.commit.html_url)"
        $reverted = $true
        break
    }
    catch {
        # 409: the file changed between the read and the write (another environment's pin); read it again.
        if ($_.Exception.Response -and [int] $_.Exception.Response.StatusCode -eq 409 -and $attempt -lt 4) {
            Write-Host "$path changed while reverting (attempt $attempt of 4); reading it again."
            Start-Sleep -Seconds (5 * $attempt)
            continue
        }
        throw
    }
}
if (-not $reverted) { return }

# 3. Argo CD applies the revert within a minute (timeout.reconciliation); the old pods served all along.
$deadline = (Get-Date).AddMinutes(5)
while ($true) {
    $state = kubectl get deployment $deployable --namespace $namespace --output json | ConvertFrom-Json
    $tag = ([string] $state.spec.template.spec.containers[0].image) -replace '^.*:', ''
    $wanted = [int] $state.spec.replicas
    $status = $state.status
    $updated = $status.PSObject.Properties['updatedReplicas'] ? [int] $status.updatedReplicas : 0
    $available = $status.PSObject.Properties['availableReplicas'] ? [int] $status.availableReplicas : 0
    $total = $status.PSObject.Properties['replicas'] ? [int] $status.replicas : 0
    if ($tag -eq $previous -and $updated -eq $wanted -and $available -eq $wanted -and $total -eq $wanted) { break }
    if ((Get-Date) -gt $deadline) {
        Fail-Step "Argo CD did not roll $deployable in $environmentName back to $previous within 5 minutes (Deployment $deployable in $namespace runs $tag)."
    }
    Start-Sleep -Seconds 10
}
Write-Highlight "$deployable of $environmentName runs $previous again, every replica available."
