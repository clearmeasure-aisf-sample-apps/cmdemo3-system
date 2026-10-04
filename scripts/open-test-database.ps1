#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Hands the acceptance tests the app's URL and the database connection of the environment.

.DESCRIPTION
    Step "Open test database" of the Octopus project <slug>-<deployable>, on the Kubernetes worker in the cluster, in
    the environments with "acceptanceTests": true; octopus/projects.tf inlines this file. The test step runs in the
    Playwright image, which has no kubectl, so this step reads the app's login from the environment's Secret
    db-credentials and passes the connection string on as a sensitive output variable, with the app's public URL.
    Nothing has to be opened or closed: the worker is inside the cluster, where SQL Server listens.
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
$database = [string] $OctopusParameters['Database.Name']
$login = [string] $OctopusParameters['Database.AppLogin']
$namespace = "$slug-$environmentName"
$baseUrl = "https://$slug-$environmentName.$domain"

$secret = (kubectl get secret db-credentials --namespace $namespace --output json | ConvertFrom-Json).data
$password = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($secret.'app-password'))
$connectionString = "Server=tcp:db.$namespace.svc.cluster.local,1433;Database=$database;User ID=$login;Password=$password;Encrypt=True;TrustServerCertificate=True;"
Set-OctopusVariable -name 'SqlConnectionString' -value $connectionString -sensitive
Set-OctopusVariable -name 'ApplicationBaseUrl' -value $baseUrl
Write-Highlight "Acceptance tests of $environmentName target $baseUrl"
