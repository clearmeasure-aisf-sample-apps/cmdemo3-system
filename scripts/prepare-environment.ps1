#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Creates the environment's namespace and its database credentials, once.

.DESCRIPTION
    Step "Prepare environment" of the Octopus project <slug>-system, on the Kubernetes worker in the cluster;
    octopus/projects.tf inlines this file. The environment is the namespace <slug>-<env>. Its Secret db-credentials
    holds the passwords SQL Server starts with and the app's connection string. They are generated here, inside the
    cluster, and never reach Git, Octopus or a log; a Secret that exists is left as it is, so a second run changes
    nothing. Argo CD applies the rest of the environment from Git (step "Apply environment").
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
$login = [string] $OctopusParameters['Database.AppLogin']
$namespace = "$slug-$environmentName"

function New-Password {
    # Letters and digits only: safe inside SQL and a connection string. SQL Server wants three character classes.
    $alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'
    do {
        $value = -join (1..32 | ForEach-Object { $alphabet[[Security.Cryptography.RandomNumberGenerator]::GetInt32($alphabet.Length)] })
    } until ($value -cmatch '[A-Z]' -and $value -cmatch '[a-z]' -and $value -match '\d')
    return $value
}

if (-not (kubectl get namespace $namespace --ignore-not-found --output name)) {
    kubectl create namespace $namespace --output name
}
else {
    Write-Host "Namespace $namespace exists."
}

if (kubectl get secret db-credentials --namespace $namespace --ignore-not-found --output name) {
    Write-Host "Secret db-credentials of $namespace exists: its passwords stay as they are."
}
else {
    $appPassword = New-Password
    $manifest = @{
        apiVersion = 'v1'
        kind       = 'Secret'
        metadata   = @{ name = 'db-credentials'; namespace = $namespace; labels = @{ system = $slug; environment = $environmentName } }
        type       = 'Opaque'
        stringData = @{
            'sa-password'           = New-Password
            'app-password'          = $appPassword
            'app-connection-string' = "Server=tcp:db,1433;Database=$database;User ID=$login;Password=$appPassword;Encrypt=True;TrustServerCertificate=True;"
        }
    } | ConvertTo-Json -Depth 5
    $manifest | kubectl create --filename - --output name
}
Write-Highlight "Namespace $namespace and its database credentials are in place."
