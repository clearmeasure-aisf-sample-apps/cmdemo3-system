#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Backs the environment's database up before a release changes it, and records where the backup is.

.DESCRIPTION
    Step "Record restore point" of the Octopus project <slug>-<deployable>, first after the sign-off in the prod-tier
    environments, on the Kubernetes worker in the cluster; octopus/projects.tf inlines this file. It starts a job from
    the environment's CronJob db-backup (gitops/templates/environment/backup.yaml), named after the release, and waits
    for it: SQL Server writes a verified backup to the system's storage account. The deployment log then names the
    backup and how to return the data to it. A backup that fails stops the deployment before anything changed.
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
$database = [string] $OctopusParameters['Database.Name']
$release = "$($OctopusParameters['Octopus.Project.Name']) $($OctopusParameters['Octopus.Release.Number'])"
$namespace = "$slug-$environmentName"
# A job name: lowercase letters, digits and hyphens, unique per deployment.
$job = ("restore-point-$($OctopusParameters['Octopus.Release.Number'])-$($OctopusParameters['Octopus.Deployment.Id'])".ToLowerInvariant() -replace '[^a-z0-9-]', '-')
if ($job.Length -gt 52) { $job = $job.Substring(0, 52).TrimEnd('-') }

kubectl create job $job --from=cronjob/db-backup --namespace $namespace --output name
$deadline = (Get-Date).AddMinutes(20)
while ($true) {
    $status = (kubectl get job $job --namespace $namespace --output json | ConvertFrom-Json).status
    if ($status.PSObject.Properties['succeeded'] -and [int] $status.succeeded -ge 1) { break }
    $failed = $status.PSObject.Properties['failed'] ? [int] $status.failed : 0
    $conditions = @($status.PSObject.Properties['conditions'] ? $status.conditions : @())
    $ended = @($conditions | Where-Object { $_.type -eq 'Failed' -and $_.status -eq 'True' }).Count -gt 0
    if ($ended -or (Get-Date) -gt $deadline) {
        $PSNativeCommandUseErrorActionPreference = $false
        kubectl logs "job/$job" --namespace $namespace --all-containers --tail 40 | ForEach-Object { Write-Host $_ }
        $PSNativeCommandUseErrorActionPreference = $true
        Fail-Step "The backup of $database in $environmentName did not succeed (job $job in $namespace, $failed failed attempt(s)): nothing was deployed."
    }
    Start-Sleep -Seconds 10
}
$log = @(kubectl logs "job/$job" --namespace $namespace --container backup --tail 40)
$backup = (@($log | Where-Object { $_ -match '^db-backup: (\S+)$' })[-1] -replace '^db-backup: ', '')
if (-not $backup) {
    Fail-Step "Job $job succeeded but did not name its backup."
}
Set-OctopusVariable -name 'RestorePoint' -value $backup
Write-Highlight "Restore point before ${release}: $backup"
Write-Host "To return the data to it: RESTORE DATABASE [$database] FROM URL = N'$backup' WITH REPLACE, on SQL Server of $namespace (service db), with a credential for the storage container as the backup job creates it (gitops/templates/environment/backup.yaml)."
