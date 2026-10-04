#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Adds the app's demo employees to the environment's database with the seeder of the release's test package.

.DESCRIPTION
    Step "Seed demo employees" of the Octopus project <slug>-<deployable>, right after "Migrate database", on the
    Kubernetes worker in the cluster, in every environment without acceptance tests; octopus/projects.tf inlines this
    file. An environment with acceptance tests gets the same employees from ZDataLoader, which empties its database
    first.

    The employees are the app's own list: the step runs one explicit test of the data loader assembly, selected by its
    full name ($seederTest below), with the app's login from the environment's Secret db-credentials. The seeder only
    inserts what is missing (a role by name, an employee by user name, an employee-role link) and never changes or
    deletes a row, so a second run adds nothing. A release whose package has no seeder yet is logged and skipped.
    dotnet test needs a .NET 10 SDK: the container's when it has one, otherwise one installed into a temporary folder.
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
$package = [string] $OctopusParameters['Octopus.Action.Package[tests].ExtractedPath']
$loaderAssembly = Join-Path $package ([string] $OctopusParameters['DataLoader.Assembly'])
$namespace = "$slug-$environmentName"
# The seeder of the bootcamp app (src/IntegrationTests/DemoData/DemoEmployeeSeeder.cs): an [Explicit] test, so it runs
# only when selected by this name, and outside the namespace whose SetUpFixture starts the test host.
$seederTest = 'ClearMeasure.Bootcamp.DemoData.DemoEmployeeSeeder.SeedDemoEmployees'

if (-not (Test-Path -LiteralPath $loaderAssembly)) {
    Fail-Step "The acceptance-test package has no $([IO.Path]::GetFileName($loaderAssembly)) ($package)."
}

function Get-DotnetSdk {
    # The container's dotnet when it has a .NET 10 SDK, otherwise one installed into a temporary folder.
    $command = Get-Command dotnet -ErrorAction SilentlyContinue
    if ($command -and (@(& $command.Source --list-sdks) -match '^10\.')) {
        return $command.Source
    }
    $installDir = Join-Path ([IO.Path]::GetTempPath()) 'dotnet10-sdk'
    $installer = Join-Path ([IO.Path]::GetTempPath()) 'dotnet-install.ps1'
    Invoke-WebRequest -Uri 'https://dot.net/v1/dotnet-install.ps1' -OutFile $installer
    & $installer -Channel 10.0 -InstallDir $installDir -NoPath
    $env:DOTNET_ROOT = $installDir
    $env:PATH = "${installDir}:$env:PATH"
    Write-Host "Installed the .NET 10 SDK into $installDir"
    return (Join-Path $installDir 'dotnet')
}

$secret = (kubectl get secret db-credentials --namespace $namespace --output json | ConvertFrom-Json).data
$password = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($secret.'app-password'))
$connectionString = "Server=tcp:db.$namespace.svc.cluster.local,1433;Database=$database;User ID=$login;Password=$password;Encrypt=True;TrustServerCertificate=True;"

$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_NOLOGO = '1'
$dotnet = Get-DotnetSdk
$results = Join-Path ([IO.Path]::GetTempPath()) "seed-$([Guid]::NewGuid().ToString('N'))"
$env:ConnectionStrings__SqlConnectionString = $connectionString
$PSNativeCommandUseErrorActionPreference = $false
& $dotnet test $loaderAssembly --filter "FullyQualifiedName=$seederTest" `
    --logger 'trx;LogFileName=seed.trx' --logger 'console;verbosity=minimal' --results-directory $results
$exitCode = $LASTEXITCODE
$PSNativeCommandUseErrorActionPreference = $true
Remove-Item -Path Env:ConnectionStrings__SqlConnectionString

$trxFile = Join-Path $results 'seed.trx'
if (-not (Test-Path -LiteralPath $trxFile)) {
    Fail-Step "dotnet test wrote no results for $seederTest (exit code $exitCode, output above)."
}
[xml] $trx = Get-Content -LiteralPath $trxFile -Raw
$counters = $trx.TestRun.ResultSummary.Counters
if ([int] $counters.total -eq 0) {
    Write-Host "The release's test package has no $seederTest (built before the seeder): no demo employees to add to $environmentName."
    return
}
if ($exitCode -ne 0 -or [int] $counters.total -ne 1 -or [int] $counters.passed -ne 1) {
    Fail-Step "The demo-employee seeder failed in $environmentName (exit code $exitCode, $($counters.passed) of $($counters.total) passed; output above). It saves in one transaction, so it added nothing."
}
$output = $trx.SelectSingleNode("//*[local-name()='UnitTestResult']/*[local-name()='Output']/*[local-name()='StdOut']")
$summary = if ($output) { $output.InnerText.Trim() } else { 'Demo employees: the seeder passed and printed no counts.' }
Write-Highlight ($summary -replace '^Demo employees:', "Demo employees in ${environmentName}:")
