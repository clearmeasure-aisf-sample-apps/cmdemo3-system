#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Proves the capabilities of this system (runtime aks-argocd): one read-only check per capability, against GitHub,
    Octopus, Azure and the environments' public addresses.

.DESCRIPTION
    The nightly workflow "capabilities" runs it as the system's own identities (environment "capabilities": the plan
    identity in Azure, the system's service account in Octopus); the operator runs the same file through the kit's
    test-capabilities.ps1. It changes nothing. Each check names the capability it proves (CAP-NNN in the kit's
    docs/capabilities.md, section "Runtime aks-argocd"); a failed check fails the run, and the workflow opens an issue
    labelled "capability".

    No check enters the cluster: the plan identity is a reader of its resource group and holds no Kubernetes
    credential. What runs is read where it is recorded and where it shows: Git (Argo CD applies and repairs what
    gitops/ says), Octopus (the Argo CD instance and its health, the deployments and their logs, the runbook runs),
    Azure (the cluster's stack, the registry, the role assignments) and the answers of the apps themselves.

    Octopus: OCTOPUS_API_KEY when set (the operator), otherwise OCTOPUS_ACCESS_TOKEN (OctopusDeploy/login). GitHub: gh
    with GH_TOKEN or its own login. Azure: the current az login.
#>
[CmdletBinding()]
param(
    [string] $Root = (Split-Path -Parent $PSScriptRoot),
    [string[]] $Only = @(),
    [switch] $ListChecks,
    # Only wait until no Octopus task runs, then stop (the workflow waits before it signs in to Azure; see capabilities.yml).
    [switch] $WaitOnly,
    [int] $WaitMinutes = 90
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$ProgressPreference = 'SilentlyContinue'
$env:AZURE_CORE_DISABLE_PROGRESS_BAR = 'true'

# pwsh -File passes "CAP-001,CAP-004" as one string.
$Only = @($Only | ForEach-Object { $_ -split '[,\s]+' } | Where-Object { $_ })
if (-not $ListChecks) {
    $system = Get-Content -LiteralPath (Join-Path $Root 'system.json') -Raw | ConvertFrom-Json -AsHashtable
    $slug = [string] $system.system.slug
    $org = [string] $system.system.githubOrg
    $systemRepo = "$org/$($system.system.repository)"
    $deployable = [string] $system.deployables[0].name
    $appRepo = "$org/$($system.deployables[0].repository)"
    $systemProject = "$slug-system"
    $deployableProject = "$slug-$deployable"
    $space = [string] $system.octopus.spaceId
    $environments = @($system.environments | ForEach-Object { [string] $_.name })
    $first = $environments[0]
    $clusterGroup = [string] $system.azure.resourceGroups.cluster
    # Between classes the cluster is stopped (cluster.dormant): what only the running cluster can show is skipped.
    $dormant = $system.cluster.ContainsKey('dormant') -and [bool] $system.cluster.dormant
}

function Write-Pass { param([string] $Message) Write-Host "PASS $Message" }
function Write-Fail { param([string] $Message) Write-Host "FAIL $Message" }
function Invoke-Octopus([string] $Path) {
    $headers = if ($env:OCTOPUS_API_KEY) { @{ 'X-Octopus-ApiKey' = $env:OCTOPUS_API_KEY } } else { @{ Authorization = "Bearer $env:OCTOPUS_ACCESS_TOKEN" } }
    Invoke-RestMethod -Uri "$($system.octopus.url)$Path" -Headers $headers
}
function Get-RepoFile([string] $Repo, [string] $Path) {
    $content = gh api "repos/$Repo/contents/$Path" --jq .content
    [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String((($content -join '') -replace '\s', '')))
}
function Get-RequiredCheck([string] $Repo) {
    $id = gh api "repos/$Repo/rulesets" --jq '.[] | select(.name=="default-branch") | .id'
    @(gh api "repos/$Repo/rulesets/$id" --jq '.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks[].context')
}
function Get-Project([string] $Slug) { Invoke-Octopus "/api/$space/projects/$Slug" }
function Get-ProcessStep([string] $Slug) { @((Invoke-Octopus "/api/$space/projects/$((Get-Project $Slug).Id)/deploymentprocesses").Steps) }
function Get-EnvironmentId([string] $Name) {
    # Nothing when Octopus has no such environment: an index into an empty list would throw in strict mode.
    (Invoke-Octopus "/api/$space/environments?partialName=$Name&take=100").Items | Where-Object Name -eq $Name | Select-Object -First 1 | ForEach-Object Id
}
# A capability whose precondition does not exist yet (no app deployment, no prod-tier environment, a runbook not due
# yet) is skipped with the reason, not failed: a new system's first builds run every check. Only facts skip a check;
# once the precondition exists, the check proves or fails.
class CheckSkipped : System.Exception {
    CheckSkipped([string] $Message) : base($Message) {}
}
function Skip-Check([string] $Reason) { throw [CheckSkipped]::new($Reason) }
function Find-LastDeployment([string] $Slug, [string] $Environment) {
    # The latest successful deployment of a project to an environment, or $null when there is none yet.
    $project = Get-Project $Slug
    $deployment = @((Invoke-Octopus "/api/$space/deployments?projects=$($project.Id)&environments=$(Get-EnvironmentId $Environment)&take=10").Items |
            Where-Object { (Invoke-Octopus "/api/tasks/$($_.TaskId)").State -eq 'Success' }) | Select-Object -First 1
    if (-not $deployment) { return $null }
    $deployment | Add-Member -NotePropertyName Log -NotePropertyValue (Invoke-Octopus "/api/tasks/$($deployment.TaskId)/raw") -PassThru |
        Add-Member -NotePropertyName Version -NotePropertyValue (Invoke-Octopus "/api/$space/releases/$($deployment.ReleaseId)").Version -PassThru
}
function Get-LastDeployment([string] $Slug, [string] $Environment) {
    $deployment = Find-LastDeployment $Slug $Environment
    if (-not $deployment) { Skip-Check "no successful $Slug deployment in $Environment yet" }
    $deployment
}
function Get-ProdEnvironment {
    $prod = @($system.environments | Where-Object { $_.tier -eq 'prod' } | ForEach-Object { [string] $_.name })
    if ($prod.Count -eq 0) { Skip-Check 'no prod-tier environment yet' }
    $prod
}
function Assert-AppRepository {
    $PSNativeCommandUseErrorActionPreference = $false
    gh api "repos/$appRepo" --jq .id *> $null
    $exists = $LASTEXITCODE -eq 0
    $PSNativeCommandUseErrorActionPreference = $true
    if (-not $exists) { Skip-Check "app repository $appRepo does not exist yet" }
}
function Get-SystemAge {
    # Days since the system's first release: a runbook on a schedule cannot have run before its first due date.
    $project = Get-Project $systemProject
    $releases = @((Invoke-Octopus "/api/$space/projects/$($project.Id)/releases?take=1000").Items)
    if ($releases.Count -eq 0) { return 0 }
    ([datetimeoffset]::UtcNow - [datetimeoffset] $releases[-1].Assembled).TotalDays
}
function Get-NoisyDeployment {
    # No broken windows: the deployment each environment runs now, per project, logged no Error or Warning line and did
    # not end SuccessWithWarning. Current deployments rather than the last N: a fixed warning stops counting once the
    # environment is redeployed, without deployments made only to push it out of a window.
    foreach ($project in $systemProject, $deployableProject) {
        foreach ($e in $environments) {
            $deployment = Find-LastDeployment $project $e
            if (-not $deployment) { continue }
            $details = Invoke-Octopus "/api/tasks/$($deployment.TaskId)/details?verbose=false"
            $warned = @($details.ActivityLogs[0].Children | Where-Object { $_.Status -eq 'SuccessWithWarning' })
            $lines = @($deployment.Log -split "`n" | Where-Object { $_ -match '^\S+\s+(Error|Warning)\s+\|' })
            if ($warned.Count -gt 0 -or $lines.Count -gt 0) { "$project $($deployment.Version) in $e" }
        }
    }
}
function Assert-Awake {
    if ($dormant) { Skip-Check 'the cluster is dormant (cluster.dormant in system.json): nothing runs until it wakes' }
}
function Get-Pin([string] $Environment) {
    # What Git says the environment runs of the first deployable: the image and the tag that step "Update deployable"
    # (Update Argo CD Application Image Tags) commits, and Argo CD applies.
    $path = "gitops/environments/$Environment/$deployable/kustomization.yaml"
    $match = [regex]::Match((Get-RepoFile $systemRepo $path), '(?m)^\s*-\s*name:\s*(\S+)\s*\r?\n\s*newTag:\s*"?([^"\s]+)"?')
    if (-not $match.Success) { throw "$path pins no image (images: name and newTag)" }
    @{ image = $match.Groups[1].Value; tag = $match.Groups[2].Value }
}
function Get-AppUrl([string] $Environment) {
    # The public address of the first deployable in the environment, as its HTTPRoute in Git declares it.
    $path = "gitops/environments/$Environment/system/apps/$deployable/route.yaml"
    $match = [regex]::Match((Get-RepoFile $systemRepo $path), 'hostnames:\s*\r?\n\s*-\s*"?([^"\s]+)"?')
    if (-not $match.Success) { throw "$path declares no host name" }
    "https://$($match.Groups[1].Value)"
}
function Get-RunningVersion([string] $Environment) {
    # The version the app itself reports: the build stamps it in (<release>+<commit>).
    [string] (Invoke-RestMethod -Uri "$(Get-AppUrl $Environment)/_version" -TimeoutSec 120).version
}
function Get-RoleName([string] $Group, [string] $PrincipalId) {
    # Assignments at, above and below the group that name the principal; role names from their definitions.
    $subscription = [string] $system.azure.subscriptionId
    $uri = "https://management.azure.com/subscriptions/$subscription/resourceGroups/$Group/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&`$filter=assignedTo('$PrincipalId')"
    foreach ($assignment in @((az rest --method get --url $uri --output json | ConvertFrom-Json -AsHashtable).value)) {
        $definition = ($assignment.properties.roleDefinitionId -split '/')[-1]
        [string] (az rest --method get --url "https://management.azure.com/subscriptions/$subscription/resourceGroups/$Group/providers/Microsoft.Authorization/roleDefinitions/$($definition)?api-version=2022-04-01" --query properties.roleName --output tsv)
    }
}
function Get-RecentRun([string] $Runbook, [int] $Days) {
    $runs = @((Invoke-Octopus "/api/$space/tasks?name=RunbookRun&take=100").Items |
            Where-Object { $_.Description -like "*$Runbook*" -and $_.State -eq 'Success' -and [datetimeoffset] $_.CompletedTime -gt [datetimeoffset]::UtcNow.AddDays(-$Days) })
    if ($runs.Count -eq 0 -and (Get-SystemAge) -lt $Days) { Skip-Check "the system is younger than $Days days: $Runbook is not due yet" }
    $runs
}
function Assert-That([bool] $Condition, [string] $Message) { if (-not $Condition) { throw $Message } }

$checks = [ordered] @{
    'CAP-001' = { $rules = gh api "repos/$systemRepo/rulesets" --jq '[.[] | select(.name=="default-branch" and .enforcement=="active")] | length'; Assert-That ([int] $rules -eq 1) 'no active default-branch ruleset'; 'ruleset default-branch active' }
    'CAP-002' = { Assert-That ((Get-RepoFile $systemRepo '.github/workflows/env-checks.yml') -match 'preview-environment\.ps1') 'env-checks has no preview'; 'env-checks previews every environment and the cluster' }
    'CAP-003' = { Assert-AppRepository; $s = Get-RequiredCheck $systemRepo; $a = Get-RequiredCheck $appRepo; Assert-That ($s -contains 'env-checks' -and $a -contains 'Build result') "required: $s / $a"; "system: $($s -join ', '); app: $($a -join ', ')" }
    'CAP-004' = {
        # The deployment records the version: step "Update deployable" is Octopus's step "Update Argo CD Application
        # Image Tags", and the tag in Git is the release Octopus deployed last. A failed deployment leaves its tag in
        # Git (CAP-005 is Partial in this runtime), and this check then names the difference.
        $step = @(Get-ProcessStep $deployableProject | Where-Object Name -eq 'Update deployable')
        Assert-That ($step.Count -eq 1 -and $step[0].Actions[0].ActionType -eq 'Octopus.ArgoCDUpdateImageTags') 'step "Update deployable" is not Update Argo CD Application Image Tags'
        $checked = @(foreach ($e in $environments) {
                $deployment = Find-LastDeployment $deployableProject $e
                if (-not $deployment) { continue }
                $pinned = (Get-Pin $e).tag
                Assert-That ($pinned -eq $deployment.Version) "$e pins $pinned in Git, the last successful deployment is $($deployment.Version)"
                $e
            })
        if ($checked.Count -eq 0) { Skip-Check "no successful $deployableProject deployment yet" }
        "newTag in Git equals the deployed release in $($checked -join ', ')"
    }
    'CAP-005' = {
        # After a failed deployment Git names the version that runs: step "Revert pin" runs only on failure and commits
        # the previous tag back (test-failed-deployment.ps1 proves it with a release that cannot start).
        $step = @(Get-ProcessStep $deployableProject | Where-Object Name -eq 'Revert pin')
        Assert-That ($step.Count -eq 1 -and $step[0].Condition -eq 'Failure') 'no Revert pin on failure'
        $names = @(Get-ProcessStep $deployableProject | ForEach-Object Name)
        Assert-That ($names.IndexOf('Revert pin') -gt $names.IndexOf('Update deployable')) 'Revert pin stands before Update deployable'
        'Revert pin runs on failure, after Update deployable'
    }
    'CAP-010' = { Assert-AppRepository; Assert-That ((Get-RequiredCheck $appRepo) -contains 'Build result') 'Build result not required'; 'Build result required on the app' }
    'CAP-011' = { $noisy = @(Get-NoisyDeployment); Assert-That ($noisy.Count -eq 0) "warnings in: $($noisy -join '; ')"; 'the current deployment of every project and environment logged no warning or error' }
    'CAP-012' = {
        # env-checks is the only workflow a pull request starts. Its one credentialed job, the preview, runs only for
        # branches of the repository; it reads no secret and does not use the trigger that runs a fork's code with the
        # repository's rights.
        $workflow = Get-RepoFile $systemRepo '.github/workflows/env-checks.yml'
        Assert-That ($workflow -match 'head\.repo\.full_name == github\.repository' -and $workflow -notmatch '\bsecrets\.' -and $workflow -notmatch 'pull_request_target') 'a pull request from a fork can reach a credential'
        'the credentialed preview runs only for branches of the repository; env-checks reads no secret'
    }
    'CAP-013' = {
        Assert-Awake
        $v = (Get-LastDeployment $deployableProject $first).Version
        $pinned = (Get-Pin $first).tag
        Assert-That ($pinned -eq $v) "$first pins image tag $pinned for release $v"
        $running = Get-RunningVersion $first
        Assert-That ($running -eq $v -or $running.StartsWith("$v+")) "$first runs $running for release $v"
        "release $v = image tag in Git = the version the app reports in $first"
    }
    'CAP-014' = {
        $files = @(gh api "repos/$systemRepo/contents/scripts" --jq '.[].name' | Where-Object { $_ -like '*.ps1' })
        foreach ($f in $files) { $t = Get-RepoFile $systemRepo "scripts/$f"; Assert-That ($t -match "ErrorActionPreference = 'Stop'" -and $t -match 'PSNativeCommandUseErrorActionPreference = \$true') "$f lacks the preamble" }
        "$($files.Count) step scripts stop on errors"
    }
    'CAP-020' = {
        # Every environment pins the same repository of the system's registry, and environments on the same version
        # report the same build (the app's version carries its commit).
        Assert-Awake
        $repository = "$($system.azure.registry.loginServer)/$slug/$deployable"
        $builds = @{}
        $shown = foreach ($e in $environments) {
            $deployment = Find-LastDeployment $deployableProject $e
            if (-not $deployment) { continue }
            $pin = Get-Pin $e
            Assert-That ($pin.image -eq $repository) "$e runs $($pin.image), not $repository"
            $running = Get-RunningVersion $e
            Assert-That ($running -eq $pin.tag -or $running.StartsWith("$($pin.tag)+")) "$e pins $($pin.tag) and runs $running"
            if ($builds.ContainsKey($pin.tag)) { Assert-That ($builds[$pin.tag] -eq $running) "$($pin.tag) differs: $($builds[$pin.tag]) / $running" } else { $builds[$pin.tag] = $running }
            "$e $($pin.tag)"
        }
        if (-not $shown) { Skip-Check "no successful $deployableProject deployment yet" }
        "one image per version: $($shown -join ', ')"
    }
    'CAP-021' = { $v = (Get-LastDeployment $deployableProject $first).Version; $w = az acr repository show --name $system.azure.registry.name --image "$($slug)/${deployable}:$v" --query 'changeableAttributes.writeEnabled' --output tsv; Assert-That ($w -eq 'false') "$v is writable"; "$($slug)/${deployable}:$v is write-locked" }
    'CAP-030' = { $l = (Invoke-Octopus "/api/$space/lifecycles?partialName=$($slug)-lifecycle&take=100").Items | Where-Object { $_.Name -eq "$($slug)-lifecycle" } | Select-Object -First 1; Assert-That ($null -ne $l) "no lifecycle $slug-lifecycle"; Assert-That (@($l.Phases[0].AutomaticDeploymentTargets).Count -eq 1 -and @($l.Phases | Select-Object -Skip 1 | Where-Object { $_.AutomaticDeploymentTargets.Count -gt 0 }).Count -eq 0) 'lifecycle phases wrong'; "first phase automatic, $($l.Phases.Count - 1) by promotion" }
    'CAP-031' = {
        # What the pipeline creates, where it is recorded: the cluster's stack, the Argo CD instance Octopus knows (one,
        # healthy), the worker in the cluster, and per environment its Octopus environment, its registration with the
        # Argo CD instance and its Applications in Git.
        Assert-Awake
        $stack = az stack group show --name "stack-$slug-cluster" --resource-group $clusterGroup --query provisioningState --output tsv
        Assert-That ($stack -eq 'succeeded') "stack-$slug-cluster is $stack"
        $instances = @((Invoke-Octopus "/api/$space/argocdinstances/summaries").Resources)
        Assert-That ($instances.Count -eq 1) "the space has $($instances.Count) Argo CD instances, not one"
        $instance = $instances[0]
        Assert-That ($instance.HealthStatus -eq 'Healthy') "Argo CD instance $($instance.Name) is $($instance.HealthStatus) in Octopus"
        $workers = @((Invoke-Octopus "/api/$space/workers?take=100").Items | Where-Object { $_.Endpoint.CommunicationStyle -eq 'KubernetesTentacle' -and -not $_.IsDisabled -and $_.HealthStatus -eq 'Healthy' })
        Assert-That ($workers.Count -ge 1) 'no healthy Octopus worker in the cluster'
        foreach ($e in $environments) {
            $id = Get-EnvironmentId $e
            Assert-That ([bool] $id) "$e missing in Octopus"
            Assert-That (@($instance.EnvironmentIds) -contains $id) "Argo CD instance $($instance.Name) is not registered for $e"
            $applications = Get-RepoFile $systemRepo "gitops/argocd/apps/environment-$e.yaml"
            foreach ($project in $systemProject, $deployableProject) { Assert-That ($applications -match "(?m)^\s*name: $([regex]::Escape("$project-$e"))\s*$") "no Argo CD Application $project-$e in Git" }
        }
        "$($environments.Count) environments in Octopus, in Git and in Argo CD instance $($instance.Name) (healthy); the cluster's stack succeeded"
    }
    'CAP-033' = {
        # The size system.json declares is the limit in the environment's manifests in Git, which Argo CD applies.
        foreach ($entry in $system.environments) {
            $want = if ($entry.ContainsKey('appCpu')) { [double] $entry.appCpu } else { 0.5 }
            $path = "gitops/environments/$($entry.name)/system/apps/$deployable/deployment.yaml"
            $match = [regex]::Match((Get-RepoFile $systemRepo $path), 'limits:\s*\r?\n\s*cpu:\s*"?(\d+(?:\.\d+)?)(m?)"?')
            Assert-That $match.Success "$path sets no CPU limit"
            $got = if ($match.Groups[2].Value) { [double] $match.Groups[1].Value / 1000 } else { [double] $match.Groups[1].Value }
            Assert-That ($want -eq $got) "$($entry.name) has a limit of $got vCPU, system.json $want"
        }
        'app sizes in Git follow system.json'
    }
    'CAP-034' = { $n = @(Get-ProcessStep $deployableProject | ForEach-Object Name); Assert-That ($n.IndexOf('Migrate database') -ge 0 -and $n.IndexOf('Migrate database') -lt $n.IndexOf('Update deployable')) 'Update before Migrate'; 'Migrate database before Update deployable' }
    'CAP-035' = {
        # Fail fast with the reason: the image step gives a rollout five minutes, and the steps after it name the pod's
        # reason (Verify deployable while it waits, Revert pin after a failure).
        $update = @(Get-ProcessStep $deployableProject | Where-Object Name -eq 'Update deployable')[0]
        $timeout = $update.Actions[0].Properties.PSObject.Properties['Octopus.Action.ArgoCD.StepVerification.Timeout']
        Assert-That ($null -ne $timeout -and [int] [string] $timeout.Value -le 300) "Update deployable waits $(if ($timeout) { $timeout.Value } else { 'without a limit' }) seconds for a healthy rollout"
        foreach ($f in 'verify-environment.ps1', 'revert-pin.ps1') { Assert-That ((Get-RepoFile $systemRepo "scripts/$f") -match 'Get-PodProblem') "$f does not name the reason a pod cannot start" }
        "a rollout that is not healthy in $($timeout.Value) s fails, and Verify and Revert pin name the pod's reason"
    }
    'CAP-036' = { Assert-That (@(Get-ProcessStep $systemProject | Where-Object Name -eq 'Verify environment').Count -eq 1 -and @(Get-ProcessStep $deployableProject | Where-Object Name -eq 'Verify deployable').Count -eq 1) 'a verify step is missing'; 'both projects end with a verify step' }
    'CAP-037' = {
        # test-rollback.ps1 redeploys the previous release and then the current one: the first environment's history
        # shows an older release deployed successfully after a newer one.
        $project = Get-Project $deployableProject
        $versions = @((Invoke-Octopus "/api/$space/deployments?projects=$($project.Id)&environments=$(Get-EnvironmentId $first)&take=30").Items |
                Where-Object { (Invoke-Octopus "/api/tasks/$($_.TaskId)").State -eq 'Success' } |
                ForEach-Object { [version] (Invoke-Octopus "/api/$space/releases/$($_.ReleaseId)").Version })
        if (@($versions | Select-Object -Unique).Count -lt 2) { Skip-Check "fewer than two releases deployed in $first" }
        $rolledBack = $false; for ($i = 0; $i -lt $versions.Count - 1; $i++) { if ($versions[$i] -lt $versions[$i + 1]) { $rolledBack = $true } }
        Assert-That $rolledBack "no successful redeployment of an older release in $first"; "an older release was redeployed successfully in $first (test-rollback.ps1)"
    }
    'CAP-038' = {
        # The sign-off step is in the process from the start (it excludes the first environment), so a release made
        # while the system had one environment still stops at it in every environment added later. Its responsible
        # team is "<slug> approvers" (octopus/approvers.tf: the people of system.json octopus.approvers and the operator).
        $teamName = "$slug approvers"
        $team = @((Invoke-Octopus "/api/$space/teams?partialName=$([uri]::EscapeDataString($teamName))&take=100").Items | Where-Object { $_.Name -eq $teamName -and $_.SpaceId -eq $space }) | Select-Object -First 1
        Assert-That ($null -ne $team) "no team '$teamName' in the space"
        foreach ($project in $systemProject, $deployableProject) {
            $s = Get-ProcessStep $project | Select-Object -First 1
            Assert-That ($null -ne $s -and $s.Name -eq 'Sign-off' -and $s.Actions[0].ActionType -eq 'Octopus.Manual') "$project does not start with Sign-off"
            $responsible = $s.Actions[0].Properties.PSObject.Properties['Octopus.Action.Manual.ResponsibleTeamIds']
            $responsibleIds = if ($responsible) { [string] $responsible.Value } else { '' }
            Assert-That ($responsibleIds -eq $team.Id) "the Sign-off of $project is for '$responsibleIds', not for team '$teamName' ($($team.Id))"
        }
        Assert-That ((Get-RepoFile $systemRepo 'octopus/projects.tf') -match 'octopusdeploy_project_deployment_freeze') 'no freeze support'; "Sign-off first in both projects, for team '$teamName'; freezes from system.json"
    }
    'CAP-040' = { $d = Get-LastDeployment $deployableProject $first; Assert-That ($d.Log -match 'Acceptance tests passed') "the last deployment to $first ran no passing acceptance tests"; "$($d.Version) passed the acceptance tests in $first" }
    'CAP-041' = { $d = Get-LastDeployment $deployableProject $first; Assert-That ($d.Log -match 'test data was reloaded') 'no ZDataLoader'; "test data reloaded after $($d.Version)" }
    'CAP-042' = { $d = Get-LastDeployment $deployableProject $first; $m = [regex]::Match($d.Log, 'effective parallelism ([\d.]+)'); Assert-That $m.Success 'no parallelism reported'; "effective parallelism $($m.Groups[1].Value)" }
    'CAP-043' = { $d = Get-LastDeployment $deployableProject $first; $a = @((Invoke-Octopus "/api/$space/artifacts?regarding=$($d.TaskId)").Items | Where-Object Filename -like '*.trx'); Assert-That ($a.Count -ge 1) 'no TRX artifact'; "$($a[0].Filename)" }
    'CAP-044' = {
        # Every current deployment that ran step "Measure availability" logged no downtime.
        $measured = 0
        foreach ($project in $systemProject, $deployableProject) {
            foreach ($e in $environments) {
                $deployment = Find-LastDeployment $project $e
                if (-not $deployment) { continue }
                $lines = @($deployment.Log -split "`n" | Where-Object { $_ -match 'Availability of ' })
                if ($lines.Count -eq 0) { continue }
                $down = @($lines | Where-Object { $_ -match 'downtime period' })
                if ($down.Count -gt 0) { throw "$project $($deployment.Version) in ${e}: $($down[0])" }
                $measured++
            }
        }
        if ($measured -eq 0) { Skip-Check 'no current deployment has measured availability yet' }
        "$measured current deployments measured, no downtime"
    }
    'CAP-046' = {
        # Every environment's address is a host name on the cluster's one public address, which the seed created as a
        # static address outside the cluster's stack: pods, nodes and the cluster itself change behind it. Each address
        # answers over HTTPS with a certificate the caller trusts.
        Assert-Awake
        $ip = [string] $system.cluster.ingressIp
        $address = az network public-ip show --name $system.cluster.ingressPublicIpName --resource-group $clusterGroup --query '{ip: ipAddress, method: publicIPAllocationMethod}' --output json | ConvertFrom-Json
        Assert-That ($address.ip -eq $ip -and $address.method -eq 'Static') "$($system.cluster.ingressPublicIpName) is $($address.ip) ($($address.method)); system.json names the static address $ip"
        $shown = foreach ($e in $environments) {
            $url = Get-AppUrl $e
            $resolved = @([Net.Dns]::GetHostAddresses(([uri] $url).Host) | ForEach-Object { $_.ToString() })
            Assert-That ($resolved -contains $ip) "$url resolves to $($resolved -join ', '), not to $ip"
            # Before the first app release the placeholder image has no health path: its page answers on /.
            $path = if (Find-LastDeployment $deployableProject $e) { [string] $system.deployables[0].healthPath } else { '/' }
            $status = [int] (Invoke-WebRequest -Uri "$url$path" -TimeoutSec 120 -SkipHttpErrorCheck).StatusCode
            Assert-That ($status -eq 200) "$url$path answered $status"
            $url
        }
        "one public address per environment on the static address ${ip}: $($shown -join ', ')"
    }
    'CAP-051' = {
        # Each identity holds its role where it works and nothing broader: the plan identity reads the three groups, the
        # cluster identity manages the cluster's group only, the nodes and the Octopus feed pull images, the build
        # pushes them, and the backup jobs write to their storage account.
        $ids = $system.azure.identities
        $groups = $system.azure.resourceGroups
        # @(...) at every call: a script block hands on nothing, not an empty list, when the identity holds no role.
        $roles = { param($Identity, $Group) Get-RoleName -Group $Group -PrincipalId $Identity.principalId }
        foreach ($group in $groups.cluster, $groups.nonprod, $groups.prod) {
            $held = @(& $roles $ids.plan $group)
            Assert-That ($held -contains 'Reader' -and $held -notcontains 'Contributor' -and $held -notcontains 'Owner') "plan in ${group}: $($held -join ', ')"
        }
        $held = @(& $roles $ids.cluster $groups.cluster)
        Assert-That ($held -contains 'Contributor' -and $held -notcontains 'Owner') "cluster in $($groups.cluster): $($held -join ', ')"
        foreach ($group in $groups.nonprod, $groups.prod) { $held = @(& $roles $ids.cluster $group); Assert-That ($held.Count -eq 0) "cluster in ${group}: $($held -join ', ')" }
        foreach ($name in 'kubelet', 'feed') { $held = @(& $roles $ids[$name] $groups.nonprod); Assert-That (($held -join ',') -eq 'AcrPull') "$name in $($groups.nonprod): $($held -join ', ')" }
        $held = @(& $roles $ids.acrPush $groups.nonprod)
        Assert-That ($held -contains 'AcrPush' -and $held -notcontains 'Contributor' -and $held -notcontains 'Owner') "acrPush in $($groups.nonprod): $($held -join ', ')"
        $held = @(& $roles $ids.backup $groups.cluster)
        Assert-That (($held -join ',') -eq 'Storage Blob Data Contributor') "backup in $($groups.cluster): $($held -join ', ')"
        'plan Reader of the three groups; cluster Contributor of its group only; kubelet and feed AcrPull; push AcrPush; backup writes its storage account only'
    }
    'CAP-053' = { $u = az account show --query user.type --output tsv; $me = Invoke-Octopus '/api/users/me'; Assert-That ($u -eq 'servicePrincipal' -and $me.IsService) "az $u, Octopus service $($me.IsService)"; "az as a service principal, Octopus as $($me.Username)" }
    'CAP-055' = { Assert-AppRepository; Assert-That ((Get-RequiredCheck $appRepo) -contains 'secret-scan' -and (Get-RepoFile $systemRepo '.github/workflows/env-checks.yml') -match 'gitleaks') 'secret scanning not enforced'; 'gitleaks in env-checks and the required check secret-scan' }
    'CAP-056' = {
        # Runbook "Rotate SQL passwords" ran in every environment in the last 35 days (it runs monthly).
        Assert-Awake
        $runs = @(Get-RecentRun 'Rotate SQL passwords' 35)
        $rotated = @($environments | Where-Object { $e = $_; @($runs | Where-Object { $_.Description -like "* on $e" -or $_.Description -like "* on $e *" }).Count -gt 0 })
        $missing = @($environments | Where-Object { $rotated -notcontains $_ })
        Assert-That ($missing.Count -eq 0) "no successful rotation in 35 days in $($missing -join ', ')"
        "SQL passwords rotated in the last 35 days in $($rotated -join ', ')"
    }
    'CAP-060' = {
        # The weekly restore test restores the environment's latest backup, whose name carries the time it was taken:
        # a test that passed on a backup older than a day and a half means the nightly backup did not run.
        Assert-Awake
        $runs = @(Get-RecentRun 'Restore test' 8)
        Assert-That ($runs.Count -ge 1) 'no successful restore test in 8 days'
        $line = [regex]::Match((Invoke-Octopus "/api/tasks/$($runs[0].Id)/raw"), 'Restore test of [^\r\n]*').Value
        $stamp = [regex]::Match($line, '(\d{8}T\d{6}Z)\.bak')
        Assert-That $stamp.Success "the restore test's log names no backup: $line"
        $taken = [datetimeoffset]::ParseExact($stamp.Groups[1].Value, "yyyyMMdd'T'HHmmss'Z'", [cultureinfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal)
        $hours = [int] [Math]::Floor(([datetimeoffset] $runs[0].CompletedTime - $taken).TotalHours)
        $completed = ([datetimeoffset] $runs[0].CompletedTime).ToUniversalTime().ToString('yyyy-MM-dd HH:mm', [cultureinfo]::InvariantCulture)
        Assert-That ($hours -lt 36) "the restore test of $completed UTC restored a backup $hours hours old: the nightly backup did not run"
        "restore test passed $completed UTC on a backup $hours hour(s) old"
    }
    'CAP-061' = { $prod = @(Get-ProdEnvironment)[0]; $d = Get-LastDeployment $deployableProject $prod; Assert-That ($d.Log -match 'Restore point before') "no restore point in the last $prod deployment"; "restore point recorded before $($d.Version) in $prod" }
    'CAP-071' = { $noisy = @(Get-NoisyDeployment); Assert-That ($noisy.Count -eq 0) "warnings in: $($noisy -join '; ')"; 'the logs of every current deployment are clean' }
    'CAP-080' = { $files = @(gh api "repos/$systemRepo/contents/docs/architecture" --jq '.[].name'); $missing = @($files | Where-Object { $_ -like '*.puml' -and $files -notcontains ($_ -replace '\.puml$', '.png') }); Assert-That ($missing.Count -eq 0 -and $files.Count -gt 0) "not rendered: $missing"; "$(@($files | Where-Object { $_ -like '*.png' }).Count) diagrams rendered" }
    'CAP-081' = {
        $build = Get-RepoFile $systemRepo '.github/workflows/system.yml'; $nightly = Get-RepoFile $systemRepo '.github/workflows/capabilities.yml'
        Assert-That ($build -match 'uses: \./\.github/workflows/capabilities\.yml' -and $nightly -match 'schedule:') 'the checks do not run with every system build and nightly'
        "$($checks.Count) checks, after every system build and nightly"
    }
}


if ($ListChecks) {
    $checks.Keys
    return
}
# Checks compare Git, Octopus and Azure; in the middle of a deployment or runbook run they differ by design, so the
# run waits until the space is quiet.
$deadline = [datetimeoffset]::UtcNow.AddMinutes($WaitMinutes)
while (@((Invoke-Octopus "/api/$space/tasks?states=Executing,Queued,Cancelling&take=10").Items).Count -gt 0) {
    if ([datetimeoffset]::UtcNow -gt $deadline) {
        if ($WaitOnly) { Write-Host "Octopus is still busy after $WaitMinutes minutes; the checks wait on."; exit 0 }
        Write-Fail "the space did not become quiet in $WaitMinutes minutes"
        exit 1
    }
    Write-Host 'Waiting for running Octopus tasks to finish.'
    Start-Sleep -Seconds 60
}
if ($WaitOnly) {
    Write-Host 'Octopus is quiet.'
    exit 0
}
# @(...) around the whole if: a single -Only ID would otherwise become a string, which has no Count in strict mode.
$ids = @(if ($Only) { $Only } else { $checks.Keys })
$failed = 0
$skipped = 0
foreach ($id in $ids) {
    if (-not $checks.Contains($id)) { Write-Fail "${id}: no check"; $failed++; continue }
    try { Write-Pass "${id}: $(& $checks[$id])" }
    catch [CheckSkipped] { Write-Host "SKIP ${id}: $($_.Exception.Message)"; $skipped++ }
    catch { Write-Fail "${id}: $($_.Exception.Message)"; $failed++ }
}
$skippedNote = if ($skipped -gt 0) { " ($skipped skipped: their preconditions do not exist yet)" } else { '' }
if ($failed -gt 0) {
    Write-Host "$failed of $($ids.Count) capabilities failed$skippedNote."
    exit 1
}
Write-Host "All $($ids.Count - $skipped) checked capabilities are proven$skippedNote."
