#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Runs the app's DbUp migrations against the environment's database.

.DESCRIPTION
    Step "Migrate database" of the Octopus project <slug>-<deployable>, on the Kubernetes worker in the cluster (SQL
    Server is reachable only there); octopus/projects.tf inlines this file. The package reference "database" is the
    app's database package (ChurchBulletin.Database for the bootcamp app), at the release's version. The step logs in
    as sa with the password of the environment's Secret db-credentials, through Service db-localhost: the migration
    tool validates the server certificate of every server whose name does not contain "localhost", and SQL Server's
    own certificate is self-signed. The .NET 10 runtime is installed into a temporary folder when the container lacks
    it.

    Known limit: the bootcamp's database tool takes the password as a positional argument (DatabaseOptions), so it is
    visible to processes of the single-use script pod while the tool runs.
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
$assemblyName = [string] $OctopusParameters['Database.Assembly']
$package = [string] $OctopusParameters['Octopus.Action.Package[database].ExtractedPath']
$namespace = "$slug-$environmentName"
$server = "db-localhost.$namespace.svc.cluster.local"

# The package also carries build intermediates (obj/, ref/) that cannot run: take a copy with its runtimeconfig.json,
# Release before Debug.
$assembly = Get-ChildItem -Path $package -Filter $assemblyName -Recurse |
    Where-Object { $_.FullName -notmatch '[\\/]obj[\\/]' -and (Test-Path -LiteralPath (Join-Path $_.DirectoryName "$($_.BaseName).runtimeconfig.json")) } |
    Sort-Object { if ($_.FullName -match '[\\/]Release[\\/]') { 0 } else { 1 } }, { $_.FullName.Length } |
    Select-Object -First 1
if (-not $assembly) {
    Fail-Step "$assemblyName is not in the database package ($package)."
}
$scripts = Join-Path $package 'scripts'
if (-not (Test-Path -LiteralPath $scripts)) {
    Fail-Step "The database package has no scripts folder ($scripts)."
}

# .NET 10 runtime: the execution container may carry an older one.
$dotnetCommand = Get-Command dotnet -ErrorAction SilentlyContinue
$dotnet = if ($dotnetCommand) { $dotnetCommand.Source } else { $null }
$hasRuntime = $dotnet -and (@(& $dotnet --list-runtimes) -match '^Microsoft\.NETCore\.App 10\.')
if (-not $hasRuntime) {
    $installDir = Join-Path ([IO.Path]::GetTempPath()) 'dotnet10'
    $installer = Join-Path ([IO.Path]::GetTempPath()) 'dotnet-install.ps1'
    Invoke-WebRequest -Uri 'https://dot.net/v1/dotnet-install.ps1' -OutFile $installer
    & $installer -Channel 10.0 -Runtime dotnet -InstallDir $installDir -NoPath
    $dotnet = Join-Path $installDir 'dotnet'
    Write-Host "Installed the .NET 10 runtime into $installDir"
}

$secret = (kubectl get secret db-credentials --namespace $namespace --output json | ConvertFrom-Json).data
$password = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($secret.'sa-password'))
$builder = [System.Data.SqlClient.SqlConnectionStringBuilder]::new()
$builder['Data Source'] = "tcp:$server,1433"
$builder['Initial Catalog'] = $database
$builder['User ID'] = 'sa'
$builder['Password'] = $password
$builder['Encrypt'] = $true
$builder['TrustServerCertificate'] = $true
$builder['Connect Timeout'] = 15
$deadline = (Get-Date).AddMinutes(5)
for ($attempt = 1; ; $attempt++) {
    $connection = [System.Data.SqlClient.SqlConnection]::new($builder.ConnectionString)
    $reason = $null
    try {
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandText = 'SELECT 1'
        $null = $command.ExecuteScalar()
    }
    catch {
        $reason = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }
    }
    finally {
        $connection.Dispose()
    }
    if (-not $reason) { break }
    if ((Get-Date) -gt $deadline) {
        Fail-Step "Database $database of $environmentName did not accept a login within 5 minutes: $reason"
    }
    Write-Host "Waiting for database $database (attempt $attempt)."
    Start-Sleep -Seconds 10
}

Write-Host "Migrating $database on $server with $($assembly.Name)"
& $dotnet $assembly.FullName update $server $database $scripts sa $password
if ($LASTEXITCODE -ne 0) {
    Fail-Step "The database migration failed (exit code $LASTEXITCODE)."
}
Write-Highlight "Database $database of $environmentName is migrated."
