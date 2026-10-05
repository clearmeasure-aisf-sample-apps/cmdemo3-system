#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Proves that the environment's latest database backup restores.

.DESCRIPTION
    Runbook "Restore test" of the Octopus project <slug>-system (weekly, in the first environment), on the Kubernetes
    worker in the cluster; octopus/runbooks.tf inlines this file. It starts a job from the environment's CronJob
    db-restore-test (gitops/templates/environment/backup.yaml) and waits for it: SQL Server restores the latest backup
    in the system's storage account into a temporary database, counts its tables and drops it. The environment's own
    database is not touched. No backup yet, or a backup that does not restore, fails the run.
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
$namespace = "$slug-$environmentName"
$job = "restore-test-$((Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss'))"

kubectl create job $job --from=cronjob/db-restore-test --namespace $namespace --output name
$deadline = (Get-Date).AddMinutes(20)
while ($true) {
    $status = (kubectl get job $job --namespace $namespace --output json | ConvertFrom-Json).status
    if ($status.PSObject.Properties['succeeded'] -and [int] $status.succeeded -ge 1) { break }
    $conditions = @($status.PSObject.Properties['conditions'] ? $status.conditions : @())
    $ended = @($conditions | Where-Object { $_.type -eq 'Failed' -and $_.status -eq 'True' }).Count -gt 0
    if ($ended -or (Get-Date) -gt $deadline) {
        $PSNativeCommandUseErrorActionPreference = $false
        kubectl logs "job/$job" --namespace $namespace --all-containers --tail 40 | ForEach-Object { Write-Host $_ }
        $PSNativeCommandUseErrorActionPreference = $true
        Fail-Step "The restore test of $environmentName failed (job $job in $namespace)."
    }
    Start-Sleep -Seconds 10
}
$log = @(kubectl logs "job/$job" --namespace $namespace --container restore-test --tail 40)
$tables = $log | Where-Object { $_ -match '^db-restore-test: \d+ tables restored' } | Select-Object -Last 1
$source = $log | Where-Object { $_ -match '^db-restore-test: https://' } | Select-Object -Last 1
if (-not $tables -or -not $source) {
    Fail-Step "Job $job succeeded but did not report what it restored."
}
Write-Highlight "Restore test of ${environmentName}: $($tables -replace '^db-restore-test: ', ''). $($source -replace '^db-restore-test: ', '')."
