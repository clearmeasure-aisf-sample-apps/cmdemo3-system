#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Creates the environment's database and the app's login on its SQL Server.

.DESCRIPTION
    Step "Initialize database" of the Octopus project <slug>-system, on the Kubernetes worker in the cluster, after
    Argo CD has started the environment's SQL Server; octopus/projects.tf inlines this file. It logs in as sa with the
    password of Secret db-credentials (waiting up to five minutes for a server that still starts), creates the database
    when it is missing, and creates the app's login with the password of the same Secret, or sets that password again.
    The login owns its database: the app creates its own messaging tables at startup. A second run changes nothing.
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
$server = "db.$namespace.svc.cluster.local"
foreach ($name in $database, $login) {
    if ($name -cnotmatch '^[A-Za-z][A-Za-z0-9_-]{0,62}$') { Fail-Step "'$name' is not a name this step accepts for a database or login." }
}

$secret = (kubectl get secret db-credentials --namespace $namespace --output json | ConvertFrom-Json).data
$saPassword = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($secret.'sa-password'))
$appPassword = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($secret.'app-password'))
if ($appPassword -cnotmatch '^[A-Za-z0-9]+$') { Fail-Step 'The app password of Secret db-credentials holds other characters than letters and digits.' }

$builder = [System.Data.SqlClient.SqlConnectionStringBuilder]::new()
$builder['Data Source'] = "tcp:$server,1433"
$builder['Initial Catalog'] = 'master'
$builder['User ID'] = 'sa'
$builder['Password'] = $saPassword
$builder['Encrypt'] = $true
$builder['TrustServerCertificate'] = $true
$builder['Connect Timeout'] = 15

function Invoke-Sql {
    param([string] $Catalog, [string] $Statement)
    $builder['Initial Catalog'] = $Catalog
    $connection = [System.Data.SqlClient.SqlConnection]::new($builder.ConnectionString)
    try {
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandText = $Statement
        $null = $command.ExecuteNonQuery()
    }
    finally {
        $connection.Dispose()
    }
}

$deadline = (Get-Date).AddMinutes(5)
for ($attempt = 1; ; $attempt++) {
    try {
        Invoke-Sql -Catalog 'master' -Statement 'SELECT 1'
        break
    }
    catch {
        $reason = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }
        if ((Get-Date) -gt $deadline) { Fail-Step "SQL Server $server did not accept a login within 5 minutes: $reason" }
        Write-Host "Waiting for SQL Server $server (attempt $attempt)."
        Start-Sleep -Seconds 10
    }
}

Invoke-Sql -Catalog 'master' -Statement "IF DB_ID(N'$database') IS NULL CREATE DATABASE [$database];"
Invoke-Sql -Catalog 'master' -Statement @"
IF SUSER_ID(N'$login') IS NULL
    CREATE LOGIN [$login] WITH PASSWORD = N'$appPassword', DEFAULT_DATABASE = [$database], CHECK_POLICY = OFF;
ELSE
    ALTER LOGIN [$login] WITH PASSWORD = N'$appPassword', CHECK_POLICY = OFF;
"@
Invoke-Sql -Catalog $database -Statement @"
IF USER_ID(N'$login') IS NULL CREATE USER [$login] FOR LOGIN [$login];
ELSE ALTER USER [$login] WITH LOGIN = [$login];
ALTER ROLE [db_owner] ADD MEMBER [$login];
"@
Write-Highlight "Database $database of $environmentName exists, with login $login."
