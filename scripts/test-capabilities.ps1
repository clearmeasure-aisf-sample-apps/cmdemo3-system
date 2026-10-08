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

    The checks compare Git, Octopus and Azure at rest. The run first waits until no Octopus task runs (-WaitMinutes).
    A deployment or runbook run that starts after that is noticed when a check fails: the run then asks Octopus once
    whether a deployment or runbook run ran since the checks began, and if so waits for the space to be quiet again
    (-AgainMinutes) and runs the failed checks once more. Only what fails then is a failure; the output names the
    checks that ran again and the task that was the reason. FAIL lines come after the last check for that reason.

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
    [int] $WaitMinutes = 90,
    # How long the failed checks wait for Octopus to become quiet again before they run once more (see the end of this
    # file). Short: the workflow's sign-ins to Azure and Octopus last an hour.
    [int] $AgainMinutes = 20
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
    $domain = [string] $system.cluster.domain
    # The health dashboard (hosting "staticsite" in the cluster, "staticwebapp" outside it) is no app: the apps are the
    # others.
    $apps = @($system.deployables | Where-Object { [string] $_['hosting'] -notin 'staticsite', 'staticwebapp' })
    $dashboards = @($system.deployables | Where-Object { [string] $_['hosting'] -in 'staticsite', 'staticwebapp' })
    $telemetryEnvironments = @($system.environments | Where-Object { @($_['capabilities']) -contains 'telemetry' } | ForEach-Object { [string] $_.name })
    # Between classes the cluster is stopped (cluster.dormant): what only the running cluster can show is skipped.
    $dormant = $system.cluster.ContainsKey('dormant') -and [bool] $system.cluster.dormant
}

function Write-Pass { param([string] $Message) Write-Host "PASS $Message" }
function Write-Fail { param([string] $Message) Write-Host "FAIL $Message" }
function Invoke-Octopus([string] $Path) {
    $headers = if ($env:OCTOPUS_API_KEY) { @{ 'X-Octopus-ApiKey' = $env:OCTOPUS_API_KEY } } else { @{ Authorization = "Bearer $env:OCTOPUS_ACCESS_TOKEN" } }
    # Octopus limits the requests of a minute, and the checks ask a lot: a 429 is a known transient (principle 004),
    # retried after the wait it names; any other answer fails at once.
    for ($attempt = 1; ; $attempt++) {
        try {
            return Invoke-RestMethod -Uri "$($system.octopus.url)$Path" -Headers $headers
        }
        catch {
            $response = $_.Exception.PSObject.Properties['Response'] ? $_.Exception.Response : $null
            if (-not $response -or [int] $response.StatusCode -ne 429 -or $attempt -ge 6) { throw }
            $after = $response.Headers.RetryAfter
            $wait = if ($after -and $after.Delta) { [Math]::Max(1, [int] $after.Delta.TotalSeconds) } else { 10 * $attempt }
            Start-Sleep -Seconds ([Math]::Min($wait, 60))
        }
    }
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
function Get-DeployableUrl([string] $Name, [string] $Environment) {
    # A deployable's public address by the runtime's convention: the first one has the environment's own host name.
    # A site outside the cluster (hosting "staticwebapp") is where Azure put it: its deployment recorded the address
    # in Git (gitops/environments/<env>/<name>/site.json).
    $entry = @($system.deployables | Where-Object { [string] $_.name -eq $Name }) | Select-Object -First 1
    if ($entry -and [string] $entry['hosting'] -eq 'staticwebapp') {
        $record = Get-RepoFile $systemRepo "gitops/environments/$Environment/$Name/site.json"
        if ($record -notmatch '"url"\s*:\s*"(https://[^"]+)"') { throw "gitops/environments/$Environment/$Name/site.json records no address" }
        return $Matches[1]
    }
    $suffix = if ($Name -eq [string] $system.deployables[0].name) { '' } else { "-$Name" }
    "https://$slug-$Environment$suffix.$domain"
}
function Get-Text($Answer) {
    # The body of a web answer as text (a JSON file may come as bytes).
    if ($Answer.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($Answer.Content) } else { [string] $Answer.Content }
}
function Test-OpenOrigin($Answer, [string] $Origin) {
    # Any origin may read the answer: the app says "*", or the Gateway's CORS policy answers with the asking origin.
    $allowed = "$($Answer.Headers['Access-Control-Allow-Origin'])"
    $allowed -eq '*' -or $allowed -eq $Origin
}
function Get-InsightsCount([string] $Environment, [string] $Query) {
    # A count from the environment's Application Insights (in the cluster's group), as a reader, over 30 days.
    $component = "/subscriptions/$($system.azure.subscriptionId)/resourceGroups/$clusterGroup/providers/Microsoft.Insights/components/appi-$slug-$Environment"
    $body = @{ query = $Query; timespan = 'P30D' } | ConvertTo-Json -Compress
    [int] (az rest --method post --url "https://management.azure.com$component/query?api-version=2018-04-20" --body $body --query 'tables[0].rows[0][0]' --output tsv)
}
function Get-TelemetryState {
    # Capability "telemetry" reaches an environment with its system release: the Deployment in Git then reads Secret
    # "telemetry" under the app's own name. On: the environments where Git says so. Waiting: the ones the newest
    # system release has not reached yet; that is promotion's matter (the fleet reports a release that stays behind),
    # not a capability that fails. An environment that runs the newest release without it is a failure.
    $role = "$slug-$deployable"
    $newest = [string] @((Invoke-Octopus "/api/$space/projects/$((Get-Project $systemProject).Id)/releases?take=1").Items)[0].Version
    $state = @{ On = @(); Waiting = @() }
    foreach ($e in $telemetryEnvironments) {
        $manifest = Get-RepoFile $systemRepo "gitops/environments/$e/system/apps/$deployable/deployment.yaml"
        if ($manifest -match 'APPLICATIONINSIGHTS_CONNECTION_STRING[\s\S]{0,160}name:\s*"?telemetry"?\s' -and $manifest -match "OTEL_SERVICE_NAME[\s\S]{0,60}value:\s*`"?$([regex]::Escape($role))`"?\s") {
            $state.On += $e
            continue
        }
        $deployment = Find-LastDeployment $systemProject $e
        Assert-That (-not $deployment -or $deployment.Version -ne $newest) "the Deployment of $deployable in $e does not read Secret telemetry under the name $role, although system release $newest runs there"
        $state.Waiting += $e
    }
    $state
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
    # The runbook's own successful runs, newest first. Asked by runbook: the hourly "Health report" alone fills the
    # first page of all runbook runs within a day and a half, and a monthly run would drop out of it.
    # Into a variable first: a JSON array answer goes down a pipeline as one object, and nothing would match.
    $runbooks = Invoke-Octopus "/api/$space/runbooks/all"
    $ids = @($runbooks | Where-Object { $_.Name -eq $Runbook } | ForEach-Object { [string] $_.Id })
    $all = @(foreach ($id in $ids) { (Invoke-Octopus "/api/$space/tasks?name=RunbookRun&runbook=$id&states=Success&take=100").Items })
    $runs = @($all | Where-Object { $_ -and [datetimeoffset] $_.CompletedTime -gt [datetimeoffset]::UtcNow.AddDays(-$Days) } |
            Sort-Object { [datetimeoffset] $_.CompletedTime } -Descending)
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
    'CAP-070' = {
        # Telemetry is proven where it lands: in every environment with capability "telemetry", Git says the app gets
        # its connection string (from Secret "telemetry") and its own name, and requests under that name
        # (OTEL_SERVICE_NAME, <slug>-<deployable>) arrived in the environment's Application Insights in 30 days.
        if ($telemetryEnvironments.Count -eq 0) { Skip-Check 'no environment has capability telemetry yet' }
        $role = "$slug-$deployable"
        $telemetry = Get-TelemetryState
        if ($telemetry.On.Count -eq 0) { Skip-Check "telemetry awaits the system release in $($telemetry.Waiting -join ', ')" }
        foreach ($e in $telemetry.On) {
            Assert-That ((Get-InsightsCount $e "requests | where cloud_RoleName == '$role' | summarize count()") -gt 0) "no requests of $role in appi-$slug-$e in 30 days"
        }
        "requests of $role arriving in Application Insights in $($telemetry.On -join ', ')$(if ($telemetry.Waiting.Count -gt 0) { "; $($telemetry.Waiting -join ', ') get it with the system release" })"
    }
    'CAP-071' = { $noisy = @(Get-NoisyDeployment); Assert-That ($noisy.Count -eq 0) "warnings in: $($noisy -join '; ')"; 'the logs of every current deployment are clean' }
    'CAP-074' = {
        # Metrics land where telemetry does: metrics of the app under its own name arrived in 30 days.
        if ($telemetryEnvironments.Count -eq 0) { Skip-Check 'no environment has capability telemetry yet' }
        $role = "$slug-$deployable"
        $telemetry = Get-TelemetryState
        if ($telemetry.On.Count -eq 0) { Skip-Check "telemetry awaits the system release in $($telemetry.Waiting -join ', ')" }
        foreach ($e in $telemetry.On) {
            Assert-That ((Get-InsightsCount $e "customMetrics | where cloud_RoleName == '$role' | summarize count()") -gt 0) "no metrics of $role in appi-$slug-$e in 30 days"
        }
        "metrics of $role arriving in Application Insights in $($telemetry.On -join ', ')$(if ($telemetry.Waiting.Count -gt 0) { "; $($telemetry.Waiting -join ', ') get it with the system release" })"
    }
    'CAP-075' = {
        # One page shows every node: every dashboard of the system (a deployable with hosting "staticsite", in the
        # cluster, or "staticwebapp", outside it) serves, in every environment it runs in, the topology its deployment
        # wrote: every environment of system.json and, for each app, its node <namespace>/<app>. A topology older than
        # system.json fails: deploy the dashboard again. Its Runtime view has, in runtime/index.json, every environment
        # with a manifest and an SVG the site serves.
        if ($dashboards.Count -eq 0) { Skip-Check 'no dashboard (a deployable with hosting staticsite or staticwebapp) yet' }
        $want = @(foreach ($e in $environments) { foreach ($app in $apps) { "$e/$($app.name)/$slug-$e/$($app.name)" } })
        $shown = foreach ($dashboard in $dashboards) {
            $dashboardName = [string] $dashboard.name
            # A site outside the cluster answers while the cluster sleeps; one inside it does not.
            if ([string] $dashboard.hosting -eq 'staticsite' -and $dormant) { continue }
            # A site outside the cluster may exist in some environments only (deployables[].environments).
            $homes = if ($dashboard['environments']) { @($dashboard.environments | ForEach-Object { [string] $_ }) } else { $environments }
            foreach ($e in $homes) {
                if (-not (Find-LastDeployment "$slug-$dashboardName" $e)) { continue }
                $url = Get-DeployableUrl $dashboardName $e
                $topology = Get-Text (Invoke-WebRequest -Uri "$url/topology.json" -TimeoutSec 120) | ConvertFrom-Json -AsHashtable
                $listed = @($topology['environments'] | Where-Object { $_ })
                $absent = @($environments | Where-Object { @($listed | ForEach-Object { [string] $_['name'] }) -notcontains $_ })
                Assert-That ($absent.Count -eq 0) "$dashboardName in $e does not list $($absent -join ', '): deploy the release of $slug-$dashboardName to $e again"
                $got = @(foreach ($entry in $listed) { foreach ($d in @($entry['deployables'] | Where-Object { $_ })) { foreach ($node in @($d['nodes'] | Where-Object { $_ })) { "$($entry['name'])/$($d['name'])/$($node['name'])" } } })
                $lost = @($want | Where-Object { $got -notcontains $_ })
                Assert-That ($lost.Count -eq 0) "$dashboardName in $e does not list the node(s) $($lost -join ', '): deploy the release of $slug-$dashboardName to $e again"
                $answer = Invoke-WebRequest -Uri "$url/runtime/index.json" -TimeoutSec 120 -SkipHttpErrorCheck
                Assert-That ($answer.StatusCode -eq 200) "$dashboardName in $e has no runtime/index.json (HTTP $($answer.StatusCode)): deploy the release of $slug-$dashboardName to $e again"
                $drawn = @((Get-Text $answer | ConvertFrom-Json -AsHashtable)['environments'] | Where-Object { $_ })
                $undrawn = @($environments | Where-Object { @($drawn | ForEach-Object { [string] $_['name'] }) -notcontains $_ })
                Assert-That ($undrawn.Count -eq 0) "the Runtime view of $dashboardName in $e has no diagram of $($undrawn -join ', '): deploy the release of $slug-$dashboardName to $e again"
                foreach ($entry in $drawn) {
                    foreach ($file in @([string] $entry['manifest'], [string] $entry['svg'])) {
                        $part = Invoke-WebRequest -Uri "$url/runtime/$file" -TimeoutSec 120 -SkipHttpErrorCheck
                        Assert-That ($part.StatusCode -eq 200 -and $part.RawContentLength -gt 0) "the Runtime view of $dashboardName in $e does not serve runtime/$file (HTTP $($part.StatusCode))"
                    }
                }
                "$dashboardName $e $url"
            }
        }
        if (-not $shown) { Skip-Check 'no successful deployment of a dashboard that answers now' }
        "$($environments.Count) environment(s) and $($want.Count) node(s) on one page, with a runtime diagram each: $(@($shown) -join '; ')"
    }
    'CAP-076' = {
        # The delivery tool shows each environment's health: a "Health report" run of the last three hours succeeded
        # in every environment (the runbook is hourly, and fails when a deployable does not answer).
        Assert-Awake
        $since = [datetimeoffset]::UtcNow.AddHours(-3)
        $everRun = @((Invoke-Octopus "/api/$space/tasks?name=RunbookRun&take=200").Items | Where-Object { $_.Description -like '*Health report*' })
        # A runbook that has never run is new (the system, or the template that brought it): its first hourly run is due.
        if ($everRun.Count -eq 0) { Skip-Check 'runbook "Health report" has not run yet: its hourly trigger is due within the hour' }
        $runs = @($everRun | Where-Object { [datetimeoffset] $_.QueueTime -gt $since })
        $shown = foreach ($e in $environments) {
            $last = @($runs | Where-Object { $_.Description -like "* $e" -or $_.Description -like "* $e *" }) | Sort-Object { [datetimeoffset] $_.QueueTime } -Descending | Select-Object -First 1
            Assert-That ($null -ne $last) "no Health report run in $e in three hours"
            Assert-That ($last.State -eq 'Success') "the last Health report in $e is $($last.State)"
            "$e $(([datetimeoffset] $last.QueueTime).ToUniversalTime().ToString('HH:mm'))"
        }
        "the last hourly health report succeeded in $($shown -join ', ') (UTC)"
    }
    'CAP-077' = {
        # Calls are counted where they happen: every app with a telemetryPath answers it, in every environment that
        # runs a release of it, with its counts of the last minute, readable from any origin, so the dashboard's
        # runtime view shows calls per minute on the arrows.
        $counted = @($apps | Where-Object { $_['telemetryPath'] })
        if ($counted.Count -eq 0) { Skip-Check 'no app has a telemetryPath in system.json' }
        Assert-Awake
        $origin = 'https://capability-check.example'
        $shown = foreach ($app in $counted) {
            foreach ($e in $environments) {
                if (-not (Find-LastDeployment "$slug-$($app.name)" $e)) { continue }
                $url = "$(Get-DeployableUrl ([string] $app.name) $e)$($app.telemetryPath)"
                $answer = Invoke-WebRequest -Uri $url -Headers @{ Origin = $origin } -TimeoutSec 120 -SkipHttpErrorCheck
                Assert-That ($answer.StatusCode -eq 200) "$url answers HTTP $($answer.StatusCode): deploy a release of $slug-$($app.name) that has the endpoint"
                Assert-That (Test-OpenOrigin $answer $origin) "$url does not allow other origins to read it"
                $counts = Get-Text $answer | ConvertFrom-Json -AsHashtable
                Assert-That ($counts['requests'] -is [hashtable] -and $null -ne $counts.requests['perMinute'] -and $counts['sql'] -is [hashtable]) "$url answers without the counts of requests and SQL commands"
                "$e $($app.name) $($counts.requests.perMinute) req/min, $($counts.sql.perMinute) SQL/min"
            }
        }
        if (-not $shown) { Skip-Check 'no successful deployment of an app with a telemetryPath yet' }
        "every app counts its calls: $($shown -join '; ')"
    }
    'CAP-078' = {
        # Delivery facts where a browser can read them: workflow delivery publishes delivery.json on branch status
        # (one commit, no commit on main), with every environment and, in each, the first app and the system project
        # at the release Octopus last deployed. A deployment of the last 90 minutes may be ahead of the file: the
        # workflow waits for the deployment that triggered it.
        $branches = @(gh api "repos/$systemRepo/branches" --paginate --jq '.[].name')
        if ($branches -notcontains 'status') { Skip-Check 'workflow delivery has not published branch status yet' }
        $delivery = Get-RepoFile $systemRepo 'delivery.json?ref=status' | ConvertFrom-Json -AsHashtable
        $listed = @($delivery['environments'] | Where-Object { $_ })
        $compared = foreach ($e in $environments) {
            $entry = @($listed | Where-Object { $_['name'] -eq $e }) | Select-Object -First 1
            Assert-That ($null -ne $entry) "delivery.json on branch status does not list $e"
            foreach ($name in @($deployable, 'system')) {
                $fact = @($entry['deployables'] | Where-Object { $_ -and $_['name'] -eq $name }) | Select-Object -First 1
                Assert-That ($null -ne $fact) "delivery.json does not list $name in $e"
                $deployment = Find-LastDeployment "$slug-$name" $e
                if (-not $deployment) { continue }
                $settled = [datetimeoffset] (Invoke-Octopus "/api/tasks/$($deployment.TaskId)").CompletedTime -lt [datetimeoffset]::UtcNow.AddMinutes(-90)
                Assert-That (-not $settled -or [string] $fact['version'] -eq $deployment.Version) "delivery.json says $name $($fact['version']) in $e, Octopus deployed $($deployment.Version): run workflow delivery"
                "$e $name $($fact['version'])"
            }
        }
        "delivery facts on branch status: $(@($compared).Count) deployment(s) match Octopus"
    }
    'CAP-079' = {
        # Each deployed process says what it was built from: every deployable with a buildPath (an app, a dashboard) answers it, from any origin,
        # in every environment that runs a release of it, with that release's version, the commit and the count of
        # its lines of code. The quality sections (tests, coverage, complexity, CRAP, analysis) may be null: the
        # Build run's artifacts expire.
        $described = @($system.deployables | Where-Object { $_['buildPath'] })
        if ($described.Count -eq 0) { Skip-Check 'no deployable has a buildPath in system.json' }
        Assert-Awake
        $origin = 'https://capability-check.example'
        $shown = foreach ($app in $described) {
            # A dashboard outside the cluster may exist in some environments only (deployables[].environments).
            $homes = if ($app['environments']) { @($app.environments | ForEach-Object { [string] $_ }) } else { $environments }
            foreach ($e in $homes) {
                $deployment = Find-LastDeployment "$slug-$($app.name)" $e
                if (-not $deployment) { continue }
                $url = "$(Get-DeployableUrl ([string] $app.name) $e)$($app.buildPath)"
                $answer = Invoke-WebRequest -Uri $url -Headers @{ Origin = $origin } -TimeoutSec 120 -SkipHttpErrorCheck
                Assert-That ($answer.StatusCode -eq 200) "$url answers HTTP $($answer.StatusCode): deploy a release of $slug-$($app.name) that has the endpoint"
                Assert-That (Test-OpenOrigin $answer $origin) "$url does not allow other origins to read it"
                $facts = Get-Text $answer | ConvertFrom-Json -AsHashtable
                Assert-That ([string] $facts['version'] -eq $deployment.Version) "$url says it is build $($facts['version']), Octopus deployed $($deployment.Version)"
                Assert-That ([string] $facts['commit'] -match '^[0-9a-f]{40}$') "$url names no commit"
                Assert-That ($facts['code'] -is [hashtable] -and [int] $facts.code['linesOfCode'] -gt 0) "$url counts no lines of code"
                "$e $($app.name) $($facts['version']) $(([string] $facts['commit']).Substring(0, 7))"
            }
        }
        if (-not $shown) { Skip-Check 'no successful deployment of an app with a buildPath yet' }
        "every app describes its build: $(@($shown) -join '; ')"
    }
    'CAP-080' = { $files = @(gh api "repos/$systemRepo/contents/docs/architecture" --jq '.[].name'); $missing = @($files | Where-Object { $_ -like '*.puml' -and $files -notcontains ($_ -replace '\.puml$', '.png') }); Assert-That ($missing.Count -eq 0 -and $files.Count -gt 0) "not rendered: $missing"; "$(@($files | Where-Object { $_ -like '*.png' }).Count) diagrams rendered" }
    'CAP-081' = {
        $build = Get-RepoFile $systemRepo '.github/workflows/system.yml'; $nightly = Get-RepoFile $systemRepo '.github/workflows/capabilities.yml'
        Assert-That ($build -match 'uses: \./\.github/workflows/capabilities\.yml' -and $nightly -match 'schedule:') 'the checks do not run with every system build and nightly'
        "$($checks.Count) checks, after every system build and nightly"
    }
    'CAP-082' = {
        # The platform under the environments is on the page too, from two sources a browser can read. Live, from the
        # cluster itself (the collector of gitops/platform/cluster-status.yaml): a file no older than two minutes, any
        # origin may read it, every node of system.json with its CPU and memory use, and pods in every environment's
        # namespace. From outside it (workflow cluster-status, branch "cluster-status"): Azure's facts about the AKS
        # service, no older than two hours, with Resource Health's verdict and whether the cluster runs. The check proves
        # that both report, not that all is healthy; while the cluster sleeps, that Azure's facts say so.
        if ($dashboards.Count -eq 0) { Skip-Check 'no dashboard yet: the cluster reports its status only for one' }
        $branches = @(gh api "repos/$systemRepo/branches" --paginate --jq '.[].name')
        if ($branches -notcontains 'cluster-status') { Skip-Check 'workflow cluster-status has not published branch cluster-status yet' }
        $facts = Get-RepoFile $systemRepo 'aks.json?ref=cluster-status'
        Assert-That ($facts -match '"generated"\s*:\s*"([^"]+)"') 'aks.json on branch cluster-status has no time'
        $age = [datetimeoffset]::UtcNow - [datetimeoffset]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal)
        # GitHub starts the ten-minute schedule every 10 to 45 minutes (cmdemo3, 2026-10-06): two hours is a workflow that stopped.
        Assert-That ($age.TotalMinutes -lt 120) "Azure's facts about the cluster are $([int] $age.TotalMinutes) minutes old: workflow cluster-status is not running"
        $service = $facts | ConvertFrom-Json -AsHashtable
        Assert-That ($service['availability'] -is [hashtable] -and $service.availability['state'] -and $service['powerState']) 'aks.json has no verdict of Azure Resource Health or no power state'
        if ($dormant) {
            # Workflow cluster-status publishes after every run of workflow system, and this check is the end of that
            # run: facts from before the cluster stopped are not wrong yet. An hour later they are.
            if ([string] $service.powerState -ne 'Stopped' -and $age.TotalMinutes -lt 60) {
                Skip-Check "the cluster is dormant, and Azure's facts ($([int] $age.TotalMinutes) min old) still say $($service.powerState): the next run of workflow cluster-status publishes the stop"
            }
            Assert-That ([string] $service.powerState -eq 'Stopped') "the cluster is dormant, and Azure's facts say $($service.powerState)"
            return "the cluster sleeps and Azure's facts say so ($($service.availability.state), $($service.powerState), $([int] $age.TotalMinutes) min old)"
        }
        $url = "https://$slug-cluster.$domain/cluster.json"
        $origin = 'https://capability-check.example'
        $answer = Invoke-WebRequest -Uri $url -Headers @{ Origin = $origin } -TimeoutSec 60 -SkipHttpErrorCheck
        Assert-That ($answer.StatusCode -eq 200) "$url answers HTTP $($answer.StatusCode)"
        Assert-That (Test-OpenOrigin $answer $origin) "$url does not allow other origins to read it"
        $text = Get-Text $answer
        Assert-That ($text -match '"generated"\s*:\s*"([^"]+)"') "$url has no time"
        $liveAge = [datetimeoffset]::UtcNow - [datetimeoffset]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal)
        Assert-That ($liveAge.TotalSeconds -lt 120) "$url was written $([int] $liveAge.TotalSeconds) seconds ago: the collector has stopped"
        $live = $text | ConvertFrom-Json -AsHashtable
        $nodes = @($live['nodes'] | Where-Object { $_ })
        Assert-That ($nodes.Count -ge [int] $system.cluster.nodeCount) "$url lists $($nodes.Count) node(s), system.json has $($system.cluster.nodeCount)"
        Assert-That (@($nodes | Where-Object { $null -eq $_.cpu['usage'] -or $null -eq $_.memory['usage'] }).Count -eq 0) "$url has a node without CPU or memory use: the metrics API does not answer"
        $spaces = @($live['namespaces'] | Where-Object { $_ })
        foreach ($e in $environments) {
            $space = @($spaces | Where-Object { [string] $_['name'] -eq "$slug-$e" }) | Select-Object -First 1
            Assert-That ($space -and @($space['pods'] | Where-Object { $_ }).Count -gt 0) "$url lists no pod of namespace $slug-$e"
        }
        $pods = @($spaces | ForEach-Object { $_['pods'] } | Where-Object { $_ })
        "live from the cluster ($($nodes.Count) node(s), $($pods.Count) pod(s) in $($spaces.Count) namespaces, $([int] $liveAge.TotalSeconds) s old) and from Azure ($($service.availability.state), $($service.powerState), $([int] $age.TotalMinutes) min old)"
    }
    'CAP-083' = {
        # What each environment costs, where a browser can read it: workflow delivery publishes cost.json next to
        # delivery.json on branch status, no older than two days (Azure's cost data is a day behind), with every
        # environment, what they share, and the system's month so far. One cluster runs every environment, so each
        # one also has an estimate of its part of it, unless the cluster sleeps (the estimate needs its status file).
        $branches = @(gh api "repos/$systemRepo/branches" --paginate --jq '.[].name')
        if ($branches -notcontains 'status') { Skip-Check 'workflow delivery has not published branch status yet' }
        $files = @(gh api "repos/$systemRepo/contents?ref=status" --jq '.[].name')
        if ($files -notcontains 'cost.json') { Skip-Check 'branch status has no cost.json yet: the hourly run of workflow delivery writes it' }
        $cost = Get-RepoFile $systemRepo 'cost.json?ref=status' | ConvertFrom-Json -AsHashtable
        $asOf = [datetime]::ParseExact([string] $cost['asOf'], 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal)
        Assert-That ($asOf -gt [datetime]::UtcNow.AddDays(-3)) "cost.json on branch status is as of $($cost['asOf']): workflow delivery has not read the cost for more than two days"
        $entries = @($cost['environments'] | Where-Object { $_ })
        $named = @($entries | ForEach-Object { [string] $_['name'] })
        $absent = @(@($environments) + 'shared' | Where-Object { $named -notcontains $_ })
        Assert-That ($absent.Count -eq 0) "cost.json does not list $($absent -join ', ')"
        Assert-That ($cost['system'] -is [hashtable] -and $null -ne $cost.system['monthToDate']) 'cost.json has no cost of the system for the month: a resource group could not be read (the node group needs a seed run after the cluster exists)'
        $estimated = @($entries | Where-Object { $environments -contains [string] $_['name'] -and $_['estimate'] -is [hashtable] } | ForEach-Object { [string] $_['name'] })
        if (-not $dormant -and $dashboards.Count -gt 0) {
            $without = @($environments | Where-Object { $estimated -notcontains $_ })
            # A file written while the cluster slept has no estimate, and the cluster may have woken since (this check
            # ends the build that wakes it): the next hourly run adds it. A file that stays without one is a failure.
            $written = if ([string] $cost['generated'] -match '^\d{4}-') { [datetimeoffset]::Parse([string] $cost['generated'], [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal) } elseif ($cost['generated'] -is [datetime]) { [datetimeoffset] $cost['generated'].ToUniversalTime() } else { $null }
            if ($without.Count -gt 0 -and $written -and ([datetimeoffset]::UtcNow - $written).TotalMinutes -lt 90) {
                Skip-Check "cost.json of $($written.ToString('HH:mm')) UTC has no estimate of the cluster's cost yet (the cluster's status file did not answer that run): the next hourly run of workflow delivery adds it"
            }
            Assert-That ($without.Count -eq 0) "cost.json has no estimate of the cluster's cost for $($without -join ', '): the cluster's status file did not answer the hourly runs of workflow delivery"
        }
        "cost as of $($cost['asOf']): $($cost['currency']) $($cost.system['monthToDate']) this month for $($named -join ', ')$(if ($estimated.Count -gt 0) { "; an estimated part of the cluster for $($estimated -join ', ')" })"
    }
}


if ($ListChecks) {
    $checks.Keys
    return
}
# Checks compare Git, Octopus and Azure; in the middle of a deployment or runbook run they differ by design, so the
# run waits until the space is quiet.
function Test-WaitsForPerson($Task) {
    # A task Octopus paused with an interruption. On this runtime that has two meanings: the sign-off, which a person
    # answers (type ManualIntervention), and the wait for Argo CD to sync, which Octopus answers itself (type
    # ArgoCDApplicationSync). Only the first is a task at rest, so the task's own flag does not decide: the type of
    # its pending interruption does.
    if (-not $Task.HasPendingInterruptions) { return $false }
    @((Invoke-Octopus "/api/$space/interruptions?regarding=$($Task.Id)&take=100").Items | Where-Object { $_.IsPending -and $_.Type -eq 'ManualIntervention' }).Count -gt 0
}
function Wait-QuietSpace([int] $Minutes) {
    # $true once no task of the space runs or waits for Octopus; $false when that takes longer than $Minutes. One read
    # a minute. A task that waits for a person (a deployment at its sign-off) is at rest: nothing changes until
    # somebody answers, which can take a night, and what the environment runs meanwhile is what the checks read.
    $deadline = [datetimeoffset]::UtcNow.AddMinutes($Minutes)
    $said = $false
    while ($true) {
        $tasks = @((Invoke-Octopus "/api/$space/tasks?states=Executing,Queued,Cancelling&take=10").Items)
        $atSignOff = @($tasks | Where-Object { Test-WaitsForPerson $_ })
        if ($atSignOff.Count -gt 0 -and -not $said) {
            $said = $true
            Write-Host "At rest, waiting for a person: $(@($atSignOff | ForEach-Object { "$($_.Description) ($($_.Id))" }) -join '; ')."
        }
        if ($tasks.Count -eq $atSignOff.Count) { return $true }
        if ([datetimeoffset]::UtcNow -gt $deadline) { return $false }
        Write-Host 'Waiting for running Octopus tasks to finish.'
        Start-Sleep -Seconds 60
    }
}
function Get-TaskSince([datetimeoffset] $Since) {
    # The deployments and runbook runs of the space that run now or ended after $Since, newest first: one read of the
    # space's latest tasks. One that waits for a person changes nothing meanwhile (Wait-QuietSpace) and does not count.
    @((Invoke-Octopus "/api/$space/tasks?take=50").Items | Where-Object {
            $_.Name -in 'Deploy', 'RunbookRun' -and ((-not $_.IsCompleted -and -not (Test-WaitsForPerson $_)) -or ($_.CompletedTime -and [datetimeoffset] $_.CompletedTime -ge $Since))
        })
}
function Invoke-Check([string] $Id) {
    # One check: Result PASS, SKIP or FAIL, and what it found.
    try { @{ Id = $Id; Result = 'PASS'; Message = "$(& $checks[$Id])" } }
    catch [CheckSkipped] { @{ Id = $Id; Result = 'SKIP'; Message = $_.Exception.Message } }
    catch { @{ Id = $Id; Result = 'FAIL'; Message = $_.Exception.Message } }
}
function Write-Check([hashtable] $Check, [string] $Note = '') {
    if ($Check.Result -eq 'FAIL') { Write-Fail "$($Check.Id): $($Check.Message)$Note" }
    elseif ($Check.Result -eq 'SKIP') { Write-Host "SKIP $($Check.Id): $($Check.Message)$Note" }
    else { Write-Pass "$($Check.Id): $($Check.Message)$Note" }
}

if (-not (Wait-QuietSpace $WaitMinutes)) {
    if ($WaitOnly) { Write-Host "Octopus is still busy after $WaitMinutes minutes; the checks wait on."; exit 0 }
    Write-Fail "the space did not become quiet in $WaitMinutes minutes"
    exit 1
}
if ($WaitOnly) {
    Write-Host 'Octopus is quiet.'
    exit 0
}
# The checks begin here, with the space quiet. Ten seconds back: the clocks of this machine and of Octopus may differ.
$began = [datetimeoffset]::UtcNow.AddSeconds(-10)
# @(...) around the whole if: a single -Only ID would otherwise become a string, which has no Count in strict mode.
$ids = @(if ($Only) { $Only } else { $checks.Keys })
$failed = 0
$skipped = 0
# A failed check is not a FAIL line yet: a deployment or runbook run that started after the wait above makes Git,
# Octopus and Azure differ while it runs (cmdemo2, 2026-10-07: a rollout applied prod during the nightly run, three
# checks failed on its half-applied stack and an issue was opened for nothing). So the failures are judged after the
# last check, with one read of the space's tasks.
$unproven = @()
foreach ($id in $ids) {
    if (-not $checks.Contains($id)) { Write-Fail "${id}: no check"; $failed++; continue }
    $outcome = Invoke-Check $id
    if ($outcome.Result -eq 'FAIL') { $unproven += $outcome; continue }
    if ($outcome.Result -eq 'SKIP') { $skipped++ }
    Write-Check $outcome
}
if ($unproven.Count -gt 0) {
    $rerun = $false
    try {
        $ranSince = @(Get-TaskSince $began)
        if ($ranSince.Count -gt 0) {
            $ranNames = @($ranSince | Select-Object -First 3 | ForEach-Object { "$($_.Description) ($($_.Id), $($_.State))" }) -join '; '
            $ranMore = if ($ranSince.Count -gt 3) { " and $($ranSince.Count - 3) more" } else { '' }
            Write-Host "Octopus was not quiet while the checks ran: $ranNames$ranMore. In the middle of a deployment or runbook run Git, Octopus and Azure differ by design, so what failed runs once more when the space is quiet: $(@($unproven | ForEach-Object { $_.Id }) -join ', ')."
            $rerun = Wait-QuietSpace $AgainMinutes
            if (-not $rerun) { Write-Host "The space did not become quiet in $AgainMinutes minutes: the failed checks are not run again, and their first result stands." }
        }
    }
    catch {
        Write-Host "Octopus could not be asked whether a task ran while the checks ran, or whether it is quiet again ($($_.Exception.Message)): the failed checks are not run again, and their first result stands."
        $rerun = $false
    }
    foreach ($firstResult in $unproven) {
        $outcome = if ($rerun) { Invoke-Check $firstResult.Id } else { $firstResult }
        if ($outcome.Result -eq 'FAIL') { $failed++ } elseif ($outcome.Result -eq 'SKIP') { $skipped++ }
        $rerunNote = if (-not $rerun) { '' } elseif ($outcome.Result -eq 'FAIL') { ' (run again after Octopus became quiet: it still fails)' } else { " (run again after Octopus became quiet; during the task it failed with: $($firstResult.Message))" }
        Write-Check $outcome $rerunNote
    }
}
$skippedNote = if ($skipped -gt 0) { " ($skipped skipped: their preconditions do not exist yet)" } else { '' }
if ($failed -gt 0) {
    Write-Host "$failed of $($ids.Count) capabilities failed$skippedNote."
    exit 1
}
Write-Host "All $($ids.Count - $skipped) checked capabilities are proven$skippedNote."
