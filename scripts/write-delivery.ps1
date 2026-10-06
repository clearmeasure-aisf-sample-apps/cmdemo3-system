#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Writes delivery.json: the delivery facts of this system, per environment and deployable, read from Octopus and
    GitHub. It changes nothing in either.

.DESCRIPTION
    The workflow "delivery" runs it and publishes the file as the only file of branch "status", where the health
    dashboard reads it from the browser (https://raw.githubusercontent.com/<org>/<repository>/status/delivery.json).

    Per environment of system.json and per deployable (the Octopus project <slug>-<deployable>, and <slug>-system as
    deployable "system"):
      version, deployedAt, releaseUrl   the release of the last successful deployment and when it finished
      signedOffBy, reason               who answered that deployment's "Sign-off" with Proceed, and the note they gave
                                        (null in the first environment, which has no sign-off)
      commit, commitAt, leadTimeHours   the commit the release was built from (the 40-character SHA in its release
                                        notes, as the release workflows write them; else its build information), when
                                        it was committed (GitHub), and deployedAt minus commitAt
      behindFirst                       versions: how many releases newer than this one the first environment runs;
                                        days: how long ago both ran the same release (0 and 0 when they do now)
      deploymentsLast7Days, failedLast7Days
                                        deployments that finished in the last seven days (Success, Failed, TimedOut;
                                        a cancelled one counts as neither), and those of them that failed
    failover: the last successful run of runbook "Failover test" whose log reports a measurement: the environment,
    when it finished, and the seconds until the public address answered from the standby.

    Times are UTC. A fact that cannot be determined is null, with a SKIP line that says why; only Octopus not
    answering (or refusing the credential) fails the run, so a published file is never replaced by an empty one.

    Octopus: OCTOPUS_API_KEY when set (the operator), otherwise OCTOPUS_ACCESS_TOKEN (OctopusDeploy/login), as
    test-capabilities.ps1. GitHub: gh with GH_TOKEN or its own login; the repositories are public.

.EXAMPLE
    ./scripts/write-delivery.ps1 -Path "$env:RUNNER_TEMP/delivery.json" -WaitMinutes 30
#>
[CmdletBinding()]
param(
    # The file to write.
    [Parameter(Mandatory)] [string] $Path,
    [string] $Root = (Split-Path -Parent $PSScriptRoot),
    # Wait this long for running deployments to finish first: the pin commit that starts the workflow is made in the
    # middle of a deployment. A deployment that waits for a person (a sign-off) is not waited for.
    [int] $WaitMinutes = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$ProgressPreference = 'SilentlyContinue'

$system = Get-Content -LiteralPath (Join-Path $Root 'system.json') -Raw | ConvertFrom-Json -AsHashtable
$slug = [string] $system.system.slug
$org = [string] $system.system.githubOrg
$space = [string] $system.octopus.spaceId
$octopusUrl = ([string] $system.octopus.url).TrimEnd('/')
$environments = @($system.environments | ForEach-Object { [string] $_.name })
$first = $environments[0]

function Write-Pass { param([string] $Message) Write-Host "PASS $Message" }
function Write-Fail { param([string] $Message) Write-Host "FAIL $Message" }
function Write-Skip { param([string] $Message) Write-Host "SKIP $Message" }
function Invoke-Octopus([string] $Path) {
    $headers = if ($env:OCTOPUS_API_KEY) { @{ 'X-Octopus-ApiKey' = $env:OCTOPUS_API_KEY } } else { @{ Authorization = "Bearer $env:OCTOPUS_ACCESS_TOKEN" } }
    Invoke-RestMethod -Uri "$octopusUrl$Path" -Headers $headers
}
function Get-OctopusItem([string] $Path, [int] $Most = 2000) {
    # Every item of a paged collection, in Octopus's order (newest first), up to $Most.
    $separator = if ($Path.Contains('?')) { '&' } else { '?' }
    $count = 0
    do {
        $items = @((Invoke-Octopus "$Path${separator}skip=$count&take=100").Items)
        $items
        $count += $items.Count
    } while ($items.Count -eq 100 -and $count -lt $Most)
}
function Get-Field($Object, [string] $Name) {
    # A property that may be absent (strict mode throws on those), or $null.
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { $property.Value }
}
function ConvertTo-Moment($Value) {
    # Octopus's times arrive as DateTime (ConvertFrom-Json) with the offset of the signed-in user, GitHub's as text.
    if ($null -eq $Value -or "$Value" -eq '') { return $null }
    if ($Value -is [datetimeoffset]) { return $Value.ToUniversalTime() }
    if ($Value -is [datetime]) { return ([datetimeoffset] $Value).ToUniversalTime() }
    [datetimeoffset]::Parse([string] $Value, [cultureinfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal).ToUniversalTime()
}
function Format-Moment($Moment) { if ($null -ne $Moment) { $Moment.ToString('yyyy-MM-ddTHH:mm:ssZ', [cultureinfo]::InvariantCulture) } }
function Test-NotFound($ErrorRecord) {
    $ErrorRecord.Exception -is [Microsoft.PowerShell.Commands.HttpResponseException] -and [int] $ErrorRecord.Exception.Response.StatusCode -eq 404
}

function Get-DeploymentHistory([string] $Project) {
    # The releases of a project and every deployment of it with its task's result, newest first; $null when Octopus
    # has no such project (yet). Three paged calls per project; any other failure is Octopus not answering.
    try { $found = Invoke-Octopus "/api/$space/projects/$Project" }
    catch { if (Test-NotFound $_) { return $null }; throw }
    $releases = @(Get-OctopusItem "/api/$space/projects/$($found.Id)/releases")
    $releaseOf = @{}
    foreach ($release in $releases) { $releaseOf[[string] $release.Id] = $release }
    $taskOf = @{}
    foreach ($task in @(Get-OctopusItem "/api/$space/tasks?name=Deploy&project=$($found.Id)")) {
        $deploymentId = Get-Field $task.Arguments 'DeploymentId'
        if ($deploymentId) { $taskOf[[string] $deploymentId] = $task }
    }
    $runs = foreach ($deployment in @(Get-OctopusItem "/api/$space/deployments?projects=$($found.Id)")) {
        $task = $taskOf[[string] $deployment.Id]
        $release = $releaseOf[[string] $deployment.ReleaseId]
        if (-not $task -or -not $release) { continue }
        [pscustomobject] @{
            Environment  = [string] $environmentName[[string] $deployment.EnvironmentId]
            Version      = [string] $release.Version
            Release      = $release
            State        = [string] $task.State
            Finished     = ConvertTo-Moment (Get-Field $task 'CompletedTime')
            TaskId       = [string] $task.Id
            DeploymentId = [string] $deployment.Id
        }
    }
    @{ Releases = $releases; Runs = @($runs) }
}
function Get-Success($History, [string] $Environment) {
    # The successful deployments to an environment, newest first.
    @($History.Runs | Where-Object { $_.Environment -eq $Environment -and $_.State -eq 'Success' -and $null -ne $_.Finished } | Sort-Object Finished -Descending)
}

$userName = @{}
function Get-UserName([string] $UserId, [string] $DeploymentId) {
    # The user's name; when this identity may not read users, the name the audit trail gives for the answer.
    if (-not $UserId) { return $null }
    if (-not $userName.ContainsKey($UserId)) {
        $name = $null
        try { $name = [string] (Invoke-Octopus "/api/users/$UserId").Username }
        catch {
            try {
                $answer = @((Invoke-Octopus "/api/$space/events?regarding=$DeploymentId&take=100").Items | Where-Object { $_.Message -like 'Submitted interruption*' }) | Select-Object -First 1
                if ($answer) { $name = [string] $answer.Username }
            }
            catch { $name = $null }
        }
        if (-not $name) { return $null }
        $userName[$UserId] = $name
    }
    $userName[$UserId]
}
function Get-SignOff($Run) {
    # The answered manual intervention "Sign-off" of the deployment (octopus/projects.tf): who proceeded, and their note.
    $answered = @((Invoke-Octopus "/api/$space/interruptions?regarding=$($Run.TaskId)&take=100").Items |
            Where-Object { $_.Type -eq 'ManualIntervention' -and $_.Title -eq 'Sign-off' -and -not $_.IsPending -and (Get-Field $_.Form.Values 'Result') -eq 'Proceed' } |
            Sort-Object { ConvertTo-Moment $_.Created } -Descending)
    if ($answered.Count -eq 0) { return $null }
    $notes = [string] (Get-Field $answered[0].Form.Values 'Notes')
    @{
        By     = Get-UserName ([string] (Get-Field $answered[0] 'ResponsibleUserId')) $Run.DeploymentId
        Reason = if ($notes) { $notes } else { $null }
    }
}

function Get-Commit($Release, [bool] $IsSystem) {
    # The release workflows write "Build <run> of <sha>" (an app) or "Commit <sha>: <message>" (the system) into the
    # release notes. Build information, when a release has it, names the commit too. A version-controlled project's
    # reference is the commit of its process in this repository, so it counts for the system project only.
    $sha = [regex]::Match([string] (Get-Field $Release 'ReleaseNotes'), '\b[0-9a-f]{40}\b').Value
    if (-not $sha) {
        $sha = [string] (@(Get-Field $Release 'BuildInformation') | ForEach-Object { Get-Field $_ 'VcsCommitNumber' } | Where-Object { $_ } | Select-Object -First 1)
    }
    if (-not $sha -and $IsSystem) { $sha = [string] (Get-Field (Get-Field $Release 'VersionControlReference') 'GitCommit') }
    if ($sha) { $sha } else { $null }
}
$commitTime = @{}
function Get-CommitTime([string] $Repository, [string] $Sha) {
    $key = "$Repository@$Sha"
    if (-not $commitTime.ContainsKey($key)) {
        $PSNativeCommandUseErrorActionPreference = $false
        $text = "$(gh api "repos/$Repository/commits/$Sha" --jq .commit.committer.date 2>$null)".Trim()
        $answered = $LASTEXITCODE -eq 0
        $PSNativeCommandUseErrorActionPreference = $true
        if (-not $answered -or -not $text) { throw "GitHub does not show commit $Sha of $Repository" }
        $commitTime[$key] = ConvertTo-Moment $text
    }
    $commitTime[$key]
}

function Get-LastMatch($FirstRuns, $Runs) {
    # The last moment at which both environments ran the same release, from both histories of successful
    # deployments; $null when they never did.
    $changes = @(@($FirstRuns | ForEach-Object { @{ At = $_.Finished; Side = 'first'; Version = $_.Version } }) +
        @($Runs | ForEach-Object { @{ At = $_.Finished; Side = 'this'; Version = $_.Version } }) | Sort-Object { $_.At })
    $running = @{ first = ''; this = '' }
    $last = $null
    foreach ($change in $changes) {
        $matched = $running.first -and $running.first -eq $running.this
        $running[$change.Side] = $change.Version
        if ($matched -and $running.first -ne $running.this) { $last = $change.At }
    }
    $last
}

function Get-Behind($History, $FirstRuns, $Runs) {
    # How far an environment (its successful deployments, newest first) is behind the first environment: the releases
    # between the two, counted in the project's list of releases (newest first), and the days since both ran the same.
    $behind = [ordered] @{ versions = $null; days = $null }
    if ($FirstRuns.Count -eq 0) { return $behind }
    if ($FirstRuns[0].Version -eq $Runs[0].Version) { $behind.versions = 0; $behind.days = 0; return $behind }
    $order = @($History.Releases | ForEach-Object { [string] $_.Version })
    $mine = $order.IndexOf($Runs[0].Version)
    $ahead = $order.IndexOf($FirstRuns[0].Version)
    if ($mine -ge 0 -and $ahead -ge 0) { $behind.versions = [Math]::Max(0, $mine - $ahead) }
    $matched = Get-LastMatch $FirstRuns $Runs
    if ($null -ne $matched) { $behind.days = [Math]::Round(($now - $matched).TotalDays, 1) }
    $behind
}

function Get-Failover {
    # As CAP-047 reads it: test-failover.ps1 logs "Failover of <deployable> in <environment>: <address> answered from
    # the standby (<region>) <n> s after <app> stopped". The runbook's own successful runs, newest first.
    $project = Invoke-Octopus "/api/$space/projects/$slug-system"
    $runbook = @(Get-OctopusItem "/api/$space/projects/$($project.Id)/runbooks" | Where-Object { $_.Name -eq 'Failover test' }) | Select-Object -First 1
    if (-not $runbook) { return $null }
    $runs = @((Invoke-Octopus "/api/$space/tasks?name=RunbookRun&runbook=$($runbook.Id)&states=Success&take=10").Items)
    foreach ($run in $runs) {
        $line = [regex]::Match([string] (Invoke-Octopus "/api/tasks/$($run.Id)/raw"), 'Failover of \S+ in (?<environment>[^\s:]+):[^\r\n]*answered from the standby[^\r\n]*?\s(?<seconds>\d+) s after')
        if ($line.Success) {
            return [ordered] @{ environment = $line.Groups['environment'].Value; at = Format-Moment (ConvertTo-Moment (Get-Field $run 'CompletedTime')); seconds = [int] $line.Groups['seconds'].Value }
        }
    }
    if ($runs.Count -eq 0) { return $null }
    # Successful runs, none with a measurement in its log: the last run, in the environment its runbook run names.
    $ran = Invoke-Octopus "/api/$space/runbookRuns/$(Get-Field $runs[0].Arguments 'RunbookRunId')"
    $where = [string] $environmentName[[string] $ran.EnvironmentId]
    [ordered] @{ environment = $(if ($where) { $where } else { $null }); at = Format-Moment (ConvertTo-Moment (Get-Field $runs[0] 'CompletedTime')); seconds = $null }
}

if (-not $env:OCTOPUS_API_KEY -and -not $env:OCTOPUS_ACCESS_TOKEN) {
    Write-Fail 'no Octopus credential: OCTOPUS_ACCESS_TOKEN (OctopusDeploy/login) or OCTOPUS_API_KEY'
    exit 1
}

# Everything every fact needs comes first: when Octopus does not answer here, the run fails and nothing is written.
$projects = [ordered] @{}
foreach ($deployable in $system.deployables) {
    $projects[[string] $deployable.name] = @{ Project = "$slug-$($deployable.name)"; Repository = "$org/$($deployable.repository)"; IsSystem = $false }
}
$projects['system'] = @{ Project = "$slug-system"; Repository = "$org/$($system.system.repository)"; IsSystem = $true }
try {
    $environmentName = @{}
    foreach ($entry in @(Get-OctopusItem "/api/$space/environments")) { $environmentName[[string] $entry.Id] = [string] $entry.Name }
    $deadline = [datetimeoffset]::UtcNow.AddMinutes($WaitMinutes)
    while ($WaitMinutes -gt 0 -and [datetimeoffset]::UtcNow -lt $deadline -and
        @((Invoke-Octopus "/api/$space/tasks?name=Deploy&states=Executing,Queued,Cancelling&take=100").Items | Where-Object { -not $_.HasPendingInterruptions }).Count -gt 0) {
        Write-Host 'Waiting for running deployments to finish.'
        Start-Sleep -Seconds 30
    }
    $now = [datetimeoffset]::UtcNow
    foreach ($name in $projects.Keys) { $projects[$name].History = Get-DeploymentHistory $projects[$name].Project }
}
catch {
    Write-Fail "Octopus cannot be read at $octopusUrl ($space): $($_.Exception.Message)"
    exit 1
}
foreach ($name in $projects.Keys) {
    if (-not $projects[$name].History) { Write-Skip "$($projects[$name].Project): no such project in Octopus (yet)" }
}

$unknown = 0
$deployed = 0
$document = [ordered] @{
    generated    = Format-Moment $now
    environments = @(foreach ($environment in $environments) {
            [ordered] @{
                name        = $environment
                deployables = @(foreach ($name in $projects.Keys) {
                        $project = $projects[$name]
                        $history = $project.History
                        $fact = [ordered] @{
                            name = $name; version = $null; deployedAt = $null; signedOffBy = $null; reason = $null
                            commit = $null; commitAt = $null; leadTimeHours = $null
                            behindFirst = [ordered] @{ versions = $null; days = $null }
                            deploymentsLast7Days = $null; failedLast7Days = $null; releaseUrl = $null
                        }
                        if (-not $history) { $unknown++; $fact; continue }

                        $recent = @($history.Runs | Where-Object { $_.Environment -eq $environment -and $_.State -in 'Success', 'Failed', 'TimedOut' -and $null -ne $_.Finished -and $_.Finished -gt $now.AddDays(-7) })
                        $fact.deploymentsLast7Days = $recent.Count
                        $fact.failedLast7Days = @($recent | Where-Object { $_.State -ne 'Success' }).Count

                        $successes = @(Get-Success $history $environment)
                        if ($successes.Count -eq 0) { Write-Skip "$($project.Project) in ${environment}: no successful deployment yet"; $fact; continue }
                        $current = $successes[0]
                        $deployed++
                        $fact.version = $current.Version
                        $fact.deployedAt = Format-Moment $current.Finished
                        $fact.releaseUrl = "$octopusUrl/app#/$space/projects/$($project.Project)/deployments/releases/$($current.Version)"

                        try {
                            $signOff = Get-SignOff $current
                            if ($signOff) { $fact.signedOffBy = $signOff.By; $fact.reason = $signOff.Reason }
                        }
                        catch { $unknown++; Write-Skip "$($project.Project) $($current.Version) in ${environment}: sign-off not read: $($_.Exception.Message)" }

                        $fact.commit = Get-Commit $current.Release $project.IsSystem
                        if (-not $fact.commit) { $unknown++; Write-Skip "$($project.Project) $($current.Version): its release names no commit" }
                        else {
                            try {
                                $committed = Get-CommitTime $project.Repository $fact.commit
                                $fact.commitAt = Format-Moment $committed
                                $fact.leadTimeHours = [Math]::Round(($current.Finished - $committed).TotalHours, 1)
                            }
                            catch { $unknown++; Write-Skip "$($project.Project) $($current.Version) in ${environment}: commit time not read: $($_.Exception.Message)" }
                        }

                        $fact.behindFirst = Get-Behind $history @(Get-Success $history $first) $successes
                        $fact
                    })
            }
        })
    failover     = $null
}
try { $document.failover = Get-Failover }
catch { $unknown++; Write-Skip "failover: not read: $($_.Exception.Message)" }

$target = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
[IO.File]::WriteAllText($target, "$($document | ConvertTo-Json -Depth 10)`n")
$failover = if ($document.failover) { "failover in $($document.failover.environment) at $($document.failover.at)" } else { 'no failover measured' }
Write-Pass "$target`: $deployed of $($environments.Count * $projects.Count) deployments ($($environments.Count) environments, $($projects.Count) deployables), $failover, $unknown facts not determined"
