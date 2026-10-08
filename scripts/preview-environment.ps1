#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Previews what a pull request would change in each environment and in the cluster (runtime aks-argocd).

.DESCRIPTION
    Capability CAP-002. Runs in job preview of .github/workflows/env-checks.yml, signed in as id-<slug>-plan (Reader
    and the what-if role of the cluster's group), and writes a Markdown report to the job summary:

      Per environment
        Manifests      gitops/templates/environment of this commit, filled in with the environment's values the way
                       step "Apply environment" fills them, against gitops/environments/<env>/system (what Git says the
                       environment runs now). They reach the environment when this commit's release of <slug>-system
                       is deployed there.
        Applications   gitops/argocd/apps/environment-<env>.yaml against the base. Argo CD applies them on the merge.
      The whole cluster, on the merge
        GitOps         gitops/platform, gitops/argocd/root.yaml and apps/platform.yaml against the base.
        Azure          what-if of infra/cluster.bicep in the cluster's resource group (job cluster-apply applies it).

    The values follow octopus/variables.tf ("template_variables"): a template that uses a variable this script does not
    know fails the preview, so a new variable is added in both places. On main, every environment's manifests equal
    its folder: a difference there means the environment has not received the latest release of <slug>-system yet.

    -Base is the commit the pull request merges into (env-checks passes the pull request's base); without it the
    comparisons with the base are left out. -SkipWhatIf leaves out the Azure part (the kit's check, a local run).
#>
[CmdletBinding()]
param(
    [string] $Root = (Split-Path -Parent $PSScriptRoot),
    [string] $Base = $env:PREVIEW_BASE,
    [switch] $SkipWhatIf,
    # Where the Markdown report goes; the job summary by default.
    [string] $SummaryPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

# The Azure CLI checks once a day whether a newer Bicep exists and says so as a warning on the next command that
# reads a template: a warning in the log that is about nothing in it. The version in use is the installed one.
$env:AZURE_BICEP_CHECK_VERSION = 'false'

$system = Get-Content -LiteralPath (Join-Path $Root 'system.json') -Raw | ConvertFrom-Json -AsHashtable
$slug = [string] $system.system.slug
$summary = if ($SummaryPath) { $SummaryPath } elseif ($env:GITHUB_STEP_SUMMARY) { $env:GITHUB_STEP_SUMMARY } else { Join-Path ([IO.Path]::GetTempPath()) 'preview-summary.md' }
$templates = Join-Path $Root 'gitops' 'templates' 'environment'
# A long diff is cut in the summary; the job log keeps the whole of it.
$maxLines = 400

# What-if reports properties Azure fills in itself as Delete and expressions it cannot evaluate before deployment
# (reference(), such as the cluster's OIDC issuer) as Modify. Neither is a change this commit makes.
function Get-PropertyChange {
    param($Delta, [string] $Prefix = '')
    foreach ($item in @($Delta)) {
        if (-not $item) { continue }
        $path = if ($Prefix) { "$Prefix.$($item.path)" } else { [string] $item.path }
        if ($item.children) {
            Get-PropertyChange -Delta $item.children -Prefix $path
            continue
        }
        if ($item.propertyChangeType -in @('Delete', 'NoEffect')) { continue }
        if (($item.after | ConvertTo-Json -Depth 20 -Compress) -match '\[[a-zA-Z]+\(') { continue }
        $path
    }
}

function Get-TemplateValue {
    # The values step "Apply environment" fills in for one environment: octopus/variables.tf, "template_variables" and
    # "shared_variables", and the Octopus system variable of the environment's name.
    param([hashtable] $Entry, [int] $Position)
    $cpu = if ($Entry.ContainsKey('appCpu')) { [string] $Entry.appCpu } else { '0.5' }
    $memory = @{ '0.5' = '1Gi'; '1' = '2Gi'; '1.5' = '3Gi'; '2' = '4Gi' }
    @{
        'Octopus.Environment.Name' = [string] $Entry.name
        'System.Slug'              = $slug
        'Cluster.Domain'           = [string] $system.cluster.domain
        'Database.Name'            = $slug
        'Sql.Edition'              = [string] $system.sql.edition
        'Backup.StorageAccount'    = [string] $system.azure.backup.storageAccount
        'Backup.Container'         = [string] $system.azure.backup.container
        'Backup.ClientId'          = [string] $system.azure.identities.backup.clientId
        'Environment.Tier'         = [string] $Entry.tier
        'Telemetry.Secret'         = if (@($Entry['capabilities']) -contains 'telemetry') { 'telemetry' } else { 'telemetry-off' }
        # The nightly backups start ten minutes apart, in the order of the environments (sort_order starts at 1).
        'Backup.Minute'            = [string] ((($Position + 1) * 10) % 60)
        'App.CpuLimit'             = "$([Math]::Floor([double] $cpu * 1000))m"
        'App.MemoryLimit'          = $memory[$cpu]
    }
}

function Write-Rendered {
    # gitops/templates/environment, filled in for one environment, into a new folder.
    param([hashtable] $Values, [string] $Destination)
    foreach ($file in Get-ChildItem -LiteralPath $templates -Recurse -File) {
        $text = [IO.File]::ReadAllText($file.FullName)
        $unknown = @([regex]::Matches($text, '#\{([^}]+)\}') | ForEach-Object { $_.Groups[1].Value } | Where-Object { -not $Values.ContainsKey($_) } | Select-Object -Unique)
        if ($unknown.Count -gt 0) {
            throw "$([IO.Path]::GetRelativePath($Root, $file.FullName)) uses $(($unknown | ForEach-Object { "#{$_}" }) -join ', '), which this preview does not know: add it next to octopus/variables.tf in Get-TemplateValue."
        }
        $rendered = [regex]::Replace($text, '#\{([^}]+)\}', { param($match) $Values[$match.Groups[1].Value] })
        $target = Join-Path $Destination ([IO.Path]::GetRelativePath($templates, $file.FullName))
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        [IO.File]::WriteAllText($target, $rendered)
    }
}

function Get-FolderDiff {
    # git diff of two folders, with paths relative to them (nothing when they are equal).
    param([string] $Before, [string] $After)
    $PSNativeCommandUseErrorActionPreference = $false
    $lines = @(git diff --no-index --no-color --src-prefix=now/ --dst-prefix=next/ -- $Before $After 2>&1 | ForEach-Object { "$_" })
    $code = $LASTEXITCODE
    $PSNativeCommandUseErrorActionPreference = $true
    if ($code -gt 1) { throw "git diff failed: $($lines -join "`n")" }
    # git diff --no-index names the files by their full paths: show them relative to the folders.
    $beforePrefix = "$(($Before -replace '\\', '/').TrimStart('/'))/"
    $afterPrefix = "$(($After -replace '\\', '/').TrimStart('/'))/"
    $lines | ForEach-Object { $_.Replace($beforePrefix, '').Replace($afterPrefix, '') }
}

function Get-BaseDiff {
    # What this commit changes against the base in the given paths (nothing without a base).
    param([string[]] $Paths)
    if (-not $Base) { return @() }
    @(git -C $Root diff --no-color --src-prefix=now/ --dst-prefix=next/ $Base -- @Paths | ForEach-Object { "$_" })
}

function Add-Diff {
    param([string] $Title, [string[]] $Lines, [string] $When)
    if ($Lines.Count -eq 0) {
        Add-Content -LiteralPath $summary -Value "**$Title**: no change.`n"
        return
    }
    $files = @($Lines | Where-Object { $_ -match '^diff --git ' }).Count
    $shown = @($Lines | Select-Object -First $maxLines)
    $cut = if ($Lines.Count -gt $maxLines) { "`n... $($Lines.Count - $maxLines) more lines in the job log" } else { '' }
    Add-Content -LiteralPath $summary -Value "**$Title**: $files file(s) change, $When.`n`n``````diff`n$($shown -join "`n")$cut`n```````n"
    $Lines | ForEach-Object { Write-Host "  $_" }
}

if ($Base) {
    $PSNativeCommandUseErrorActionPreference = $false
    git -C $Root cat-file -e "$Base^{commit}" 2>$null
    $known = $LASTEXITCODE -eq 0
    $PSNativeCommandUseErrorActionPreference = $true
    if (-not $known) { throw "The base $Base is not in this clone: check out with fetch-depth 0." }
}

Add-Content -LiteralPath $summary -Value "## What this change does to each environment`n"
$work = Join-Path ([IO.Path]::GetTempPath()) "preview-$([Guid]::NewGuid().ToString('N'))"
try {
    $position = 0
    foreach ($entry in $system.environments) {
        $name = [string] $entry.name
        Add-Content -LiteralPath $summary -Value "### $name (namespace $slug-$name)`n"
        $rendered = Join-Path $work $name
        Write-Rendered -Values (Get-TemplateValue -Entry $entry -Position $position) -Destination $rendered
        $current = Join-Path $Root 'gitops' 'environments' $name 'system'
        if (-not (Test-Path -LiteralPath $current)) { New-Item -ItemType Directory -Path $current -Force | Out-Null }
        $manifests = @(Get-FolderDiff -Before $current -After $rendered)
        Add-Diff -Title 'Manifests' -Lines $manifests -When "when this commit's release of $slug-system is deployed to $name"
        $applications = @(Get-BaseDiff -Paths @("gitops/argocd/apps/environment-$name.yaml"))
        Add-Diff -Title 'Argo CD Applications' -Lines $applications -When 'on the merge'
        Write-Host "PASS preview ${name}: $(@($manifests | Where-Object { $_ -match '^diff --git ' }).Count) manifest file(s), $(@($applications | Where-Object { $_ -match '^diff --git ' }).Count) Application file(s) change"
        $position++
    }
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

Add-Content -LiteralPath $summary -Value "### The whole cluster (every environment, on the merge)`n"
$platform = @(Get-BaseDiff -Paths @('gitops/platform', 'gitops/argocd/root.yaml', 'gitops/argocd/apps/platform.yaml', 'cluster'))
Add-Diff -Title 'Platform and Argo CD' -Lines $platform -When 'on the merge'
Write-Host "PASS preview cluster: $(@($platform | Where-Object { $_ -match '^diff --git ' }).Count) platform file(s) change"

if ($SkipWhatIf) {
    Write-Host 'SKIP what-if of infra/cluster.bicep (-SkipWhatIf)'
    exit 0
}
$group = [string] $system.azure.resourceGroups.cluster
$PSNativeCommandUseErrorActionPreference = $false
# ProviderNoRbac: full validation, but only read permissions are checked, so id-<slug>-plan (Reader and the what-if
# role) can preview without any write right.
$raw = az deployment group what-if --resource-group $group --template-file (Join-Path $Root 'infra' 'cluster.bicep') `
    --validation-level ProviderNoRbac --result-format FullResourcePayloads --no-pretty-print --output json 2>&1
$ok = $LASTEXITCODE -eq 0
$PSNativeCommandUseErrorActionPreference = $true
if (-not $ok) {
    $message = (@($raw) | ForEach-Object { "$_" }) -join "`n"
    Add-Content -LiteralPath $summary -Value "**Azure (infra/cluster.bicep)**: what-if could not run.`n`n``````text`n$message`n```````n"
    Write-Host "SKIP what-if of infra/cluster.bicep: $(($message -split "`n" | Where-Object { $_ -match 'ERROR|Code|Message' } | Select-Object -First 3) -join ' ')"
    exit 0
}
$result = (@($raw) | ForEach-Object { "$_" }) -join "`n" | ConvertFrom-Json -AsHashtable
$changes = @($result.changes | Where-Object { $_.changeType -notin @('NoChange', 'Ignore') } | ForEach-Object {
        $properties = @(if ($_.changeType -eq 'Modify') { Get-PropertyChange -Delta $_.delta })
        if ($_.changeType -ne 'Modify' -or $properties.Count -gt 0) {
            @{ changeType = $_.changeType; resourceId = $_.resourceId; properties = $properties }
        }
    })
if ($changes.Count -eq 0) {
    Add-Content -LiteralPath $summary -Value "**Azure (infra/cluster.bicep in $group)**: no change.`n"
}
else {
    $rows = foreach ($change in $changes) { "| $($change.changeType) | ``$(($change.resourceId -split '/providers/')[-1])`` | $(@($change.properties | ForEach-Object { '`' + $_ + '`' }) -join ', ') |" }
    Add-Content -LiteralPath $summary -Value ((@("**Azure (infra/cluster.bicep in $group)**: job cluster-apply applies it on the merge.", '', '| Change | Resource | Properties |', '|---|---|---|') + $rows + '') -join "`n")
}
Write-Host "PASS what-if of infra/cluster.bicep: $($changes.Count) resource(s) change"
