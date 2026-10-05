#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Gives an environment's SQL Server new passwords: the app's login and sa.

.DESCRIPTION
    Runbook "Rotate SQL passwords" of <slug>-system (runtime aks-argocd), monthly in every environment, on the Kubernetes
    worker in the cluster. Capability CAP-056. The passwords live only in the environment's Secret db-credentials
    (created by step "Prepare environment"); nothing here prints or passes one as an argument. Its rights in the
    namespace come with the environment (gitops/templates/environment/rotation-rbac.yaml).
      1. The app's login: a new password is set in SQL Server, then in the Secret (app-password and
         app-connection-string), and every Deployment of the namespace restarts (kubectl rollout restart: new pods
         first, maxUnavailable 0) so the apps read it. Pooled connections keep working until then.
      2. sa: the new password goes into the Secret first. SQL Server's own probes read it from the mounted file, so as
         soon as the kubelet has written the file into the SQL Server pod, the password is changed in SQL Server
         (with a connection opened before), and the new one is tried. If the file does not change within 3 minutes,
         the Secret gets the old password back and the run fails.
      3. Every app answers its health path again.
    The automation that signs in as sa (migrations, restore point, backups, restore test) reads the Secret each time.
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
$server = "db.$namespace.svc.cluster.local"
$deployables = @(([string] $OctopusParameters['System.Deployables']) | ConvertFrom-Json)

function New-Password {
    # Letters and digits only: safe inside SQL and a connection string. SQL Server wants three character classes.
    $alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'
    do {
        $value = -join (1..32 | ForEach-Object { $alphabet[[Security.Cryptography.RandomNumberGenerator]::GetInt32($alphabet.Length)] })
    } until ($value -cmatch '[A-Z]' -and $value -cmatch '[a-z]' -and $value -match '\d')
    return $value
}

function Get-Secret {
    $data = (kubectl get secret db-credentials --namespace $namespace --output json | ConvertFrom-Json).data
    $values = @{}
    foreach ($property in $data.PSObject.Properties) { $values[$property.Name] = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($property.Value)) }
    $values
}

function Set-Secret {
    # The whole Secret through standard input: no value on a command line. replace, not apply: the Secret was created
    # without the annotation apply keeps, and apply would warn about it.
    param([hashtable] $Values)
    @{
        apiVersion = 'v1'
        kind       = 'Secret'
        metadata   = @{ name = 'db-credentials'; namespace = $namespace; labels = @{ system = $slug; environment = $environmentName } }
        type       = 'Opaque'
        stringData = $Values
    } | ConvertTo-Json -Depth 5 | kubectl replace --filename - --output name | Out-Null
}

function New-SaConnection {
    param([string] $Secret)
    $builder = [System.Data.SqlClient.SqlConnectionStringBuilder]::new()
    $builder['Data Source'] = "tcp:$server,1433"
    $builder['Initial Catalog'] = 'master'
    $builder['User ID'] = 'sa'
    $builder['Password'] = $Secret
    $builder['Encrypt'] = $true
    $builder['TrustServerCertificate'] = $true
    $builder['Connect Timeout'] = 15
    $builder['Pooling'] = $false
    $connection = [System.Data.SqlClient.SqlConnection]::new($builder.ConnectionString)
    $connection.Open()
    $connection
}

function Invoke-Statement {
    param([System.Data.SqlClient.SqlConnection] $Connection, [string] $Statement)
    $command = $Connection.CreateCommand()
    $command.CommandText = $Statement
    $null = $command.ExecuteNonQuery()
}

if ($login -cnotmatch '^[A-Za-z][A-Za-z0-9_-]{0,62}$') { Fail-Step "'$login' is not a login name this runbook accepts." }
$secret = Get-Secret
foreach ($key in 'sa-password', 'app-password', 'app-connection-string') {
    if (-not $secret.ContainsKey($key)) { Fail-Step "Secret db-credentials of $namespace has no ${key}: deploy $slug-system to $environmentName first." }
}

# 1. The app's login.
$appPassword = New-Password
$connection = New-SaConnection -Secret $secret['sa-password']
try { Invoke-Statement -Connection $connection -Statement "ALTER LOGIN [$login] WITH PASSWORD = N'$appPassword';" }
finally { $connection.Dispose() }
$secret['app-password'] = $appPassword
$secret['app-connection-string'] = "Server=tcp:db,1433;Database=$database;User ID=$login;Password=$appPassword;Encrypt=True;TrustServerCertificate=True;"
Set-Secret -Values $secret
foreach ($deployable in $deployables) {
    $name = [string] $deployable.name
    kubectl rollout restart "deployment/$name" --namespace $namespace | Out-Null
    kubectl rollout status "deployment/$name" --namespace $namespace --timeout 5m | Out-Null
}
Write-Host "The login $login has a new password, and $(($deployables | ForEach-Object name) -join ', ') restarted with it."

# 2. sa: the Secret first, then SQL Server as soon as its pod sees the new file.
$oldSa = $secret['sa-password']
$newSa = New-Password
$connection = New-SaConnection -Secret $oldSa
try {
    $secret['sa-password'] = $newSa
    Set-Secret -Values $secret
    $deadline = (Get-Date).AddMinutes(3)
    while ($true) {
        $mounted = [string] (kubectl exec db-0 --namespace $namespace --container mssql -- cat /etc/db-credentials/sa-password)
        if ($mounted -ceq $newSa) { break }
        if ((Get-Date) -gt $deadline) {
            $secret['sa-password'] = $oldSa
            Set-Secret -Values $secret
            Fail-Step "SQL Server's pod in $namespace did not see the new sa password within 3 minutes; the Secret has the old one again, and sa keeps it."
        }
        Start-Sleep -Seconds 2
    }
    Invoke-Statement -Connection $connection -Statement "ALTER LOGIN [sa] WITH PASSWORD = N'$newSa';"
}
finally { $connection.Dispose() }
$check = New-SaConnection -Secret $newSa
$check.Dispose()
Write-Host 'sa has a new password; SQL Server accepts it.'

# 3. The apps answer again.
foreach ($deployable in $deployables) {
    $url = "https://$slug-$environmentName.$domain$([string] $deployable.healthPath)"
    $deadline = (Get-Date).AddMinutes(3)
    while ([int] (Invoke-WebRequest -Uri $url -TimeoutSec 20 -SkipHttpErrorCheck).StatusCode -ne 200) {
        if ((Get-Date) -gt $deadline) { Fail-Step "$url does not answer 200 after the rotation." }
        Start-Sleep -Seconds 5
    }
}
Write-Highlight "SQL passwords of $environmentName rotated: sa and $login; every app restarted with its new password and answers."
