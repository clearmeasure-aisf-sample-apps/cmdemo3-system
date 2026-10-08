#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Verifies a dashboard outside the cluster after its deployment: the site answers, and it serves what Git says the
    deployment wrote (runtime aks-argocd).

.DESCRIPTION
    Step "Verify deployable" of the Octopus project of a site with hosting "staticwebapp", on the hosted worker pool;
    octopus/projects.tf inlines this file. Reads gitops/environments/<env>/<name>/site.json on main through the
    GitHub API (GitHub.Token, never printed), where step "Update deployable" recorded the site's address, the release
    and the time of its topology, then asks the site for its start page and its topology.json. Fails when the record is
    not of this release, or the site does not answer 200, or its topology is another one.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$ProgressPreference = 'SilentlyContinue'

$environmentName = [string] $OctopusParameters['Octopus.Environment.Name']
$repository = [string] $OctopusParameters['System.Repository']
$name = [string] $OctopusParameters['Deployable.Name']
$release = [string] $OctopusParameters['Octopus.Release.Number']
# The site may exist in some environments only (system.json deployables[].environments): elsewhere there is nothing
# to verify, and the release passes through.
$siteEnvironments = @(if ($OctopusParameters['Site.Environments']) { ([string] $OctopusParameters['Site.Environments']) | ConvertFrom-Json })
if ($siteEnvironments.Count -gt 0 -and $siteEnvironments -notcontains $environmentName) {
    Write-Highlight "$name has no site in $environmentName (its site exists in $($siteEnvironments -join ', ')): nothing to verify."
    return
}
$path = "gitops/environments/$environmentName/$name/site.json"
$headers = @{
    Authorization          = "Bearer $([string] $OctopusParameters['GitHub.Token'])"
    Accept                 = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
}
$file = Invoke-RestMethod -Uri "https://api.github.com/repos/$repository/contents/${path}?ref=main" -Headers $headers
$text = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($file.content -replace '\s', '')))
# By pattern, not as JSON: ConvertFrom-Json turns a time into a date, in the worker's own format (lesson 57).
$field = { param([string] $Key) if ($text -match "`"$Key`"\s*:\s*`"([^`"]*)`"") { $Matches[1] } else { '' } }
$url = & $field 'url'
$version = & $field 'version'
$generated = & $field 'generated'
if ($version -ne $release) { Fail-Step "$path records $name $version, not ${release}: step Update deployable did not finish." }
if ($url -notmatch '^https://') { Fail-Step "$path records no address." }

foreach ($page in '/', '/topology.json') {
    $status = 0
    $body = ''
    for ($attempt = 1; $attempt -le 6 -and $status -ne 200; $attempt++) {
        if ($attempt -gt 1) { Start-Sleep -Seconds 10 }
        try {
            $answer = Invoke-WebRequest -Uri "$url$page" -Headers @{ 'Cache-Control' = 'no-cache' } -TimeoutSec 30 -SkipHttpErrorCheck
            $status = [int] $answer.StatusCode
            $body = if ($answer.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($answer.Content) } else { [string] $answer.Content }
        }
        catch { $status = 0 }
    }
    if ($status -ne 200) { Fail-Step "$url$page answers $(if ($status) { "HTTP $status" } else { 'nothing' }) after six attempts." }
    if ($page -eq '/topology.json') {
        $served = if ($body -match '"generated"\s*:\s*"([^"]*)"') { $Matches[1] } else { '' }
        if ($served -ne $generated) { Fail-Step "$url/topology.json is the topology of '$served', and $path records $generated." }
    }
}
Write-Highlight "$name $release answers in ${environmentName}: $url, with the topology of $generated"
