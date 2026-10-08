#Requires -Version 7.4

<#
.SYNOPSIS
    Writes deployments.json: the deployments of the system's Octopus space that are in flight, and those that ended in
    the last half hour.

.DESCRIPTION
    The system reads Octopus, once, for everything that is deployed from its space; no application reads it for
    itself. The file is what every dashboard shows a marker from: the system's own health dashboard on the node that
    is being deployed, and the fleet health dashboard on the system's box.

    One entry per deployment task of the space that is not finished, or finished less than -FinishedMinutes ago:

      project      the Octopus project (<slug>-<deployable>, and <slug>-system for the system's own release)
      environment  the environment it deploys to
      release      the release
      state        queued     waiting behind another task of the environment or the instance's task limit
                   executing  running now
                   waiting    stopped for a person: the sign-off, or a question of a guided failure
                   succeeded, failed, canceled   ended, at "finished"
      since        when it started, or when it was queued while it has not started (UTC)
      finished     when it ended (UTC); absent while it has not
      url          the task in Octopus

    In flight first, the one that started first at the top; then what ended, the last one first. An empty list says
    that nothing is being deployed.

    One request to Octopus: the newest deployment tasks of the space, which carry project, release and environment in
    their description.

    Run by workflow deployments of the system repository when Octopus pins a version (the start of every
    deployment), every five minutes, and on demand; published on branch "deployments" and read from the browser at
    https://raw.githubusercontent.com/<org>/<repository>/deployments/deployments.json, which GitHub may serve a few
    minutes old. A started deployment shows within about one to six minutes; one that is only queued, within ten to
    fifteen.

    Octopus: OCTOPUS_API_KEY when set (the operator), otherwise OCTOPUS_ACCESS_TOKEN (OctopusDeploy/login).

.PARAMETER Path
    The file to write.

.PARAMETER Root
    The folder that holds system.json, which names the system, the Octopus server and the space.

.PARAMETER System
    For a system without a system.json: its name in the fleet. With -OctopusUrl and -Space.

.PARAMETER OctopusUrl
    For a system without a system.json: the Octopus server.

.PARAMETER Space
    For a system without a system.json: the id of its Octopus space (Spaces-123), or its name.

.PARAMETER FinishedMinutes
    How long a deployment that ended stays in the file.

.EXAMPLE
    pwsh -NoProfile -File scripts/write-deployments.ps1 -Path deployments.json

.EXAMPLE
    pwsh -NoProfile -File write-deployments.ps1 -Path deployments.json -System cmfleet -OctopusUrl https://example.octopus.app -Space cmfleet
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Path,
    [string] $Root = (Split-Path -Parent $PSScriptRoot),
    [string] $System = '',
    [string] $OctopusUrl = '',
    [string] $Space = '',
    [ValidateRange(0, 1440)] [int] $FinishedMinutes = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$ProgressPreference = 'SilentlyContinue'

function Write-Pass { param([string] $Message) Write-Host "PASS $Message" }
function Write-Fail { param([string] $Message) Write-Host "FAIL $Message" }

if (-not $System) {
    $file = Join-Path $Root 'system.json'
    if (-not (Test-Path -LiteralPath $file)) {
        Write-Fail "$file not found: a system without a system.json names itself with -System, -OctopusUrl and -Space"
        exit 1
    }
    $described = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json -AsHashtable
    $System = [string] $described.system.slug
    $OctopusUrl = [string] $described.octopus.url
    $Space = [string] $described.octopus.spaceId
}
if (-not $OctopusUrl -or -not $Space) {
    Write-Fail '-System needs -OctopusUrl and -Space with it'
    exit 1
}
if (-not $env:OCTOPUS_API_KEY -and -not $env:OCTOPUS_ACCESS_TOKEN) {
    Write-Fail 'no Octopus credential: OCTOPUS_ACCESS_TOKEN (OctopusDeploy/login) or OCTOPUS_API_KEY'
    exit 1
}
$OctopusUrl = $OctopusUrl.TrimEnd('/')

function Invoke-Octopus([string] $Request) {
    $headers = if ($env:OCTOPUS_API_KEY) { @{ 'X-Octopus-ApiKey' = $env:OCTOPUS_API_KEY } } else { @{ Authorization = "Bearer $env:OCTOPUS_ACCESS_TOKEN" } }
    Invoke-RestMethod -Uri "$OctopusUrl$Request" -Headers $headers
}

function Get-Utc {
    # Octopus answers in the server's offset, and PowerShell reads such a time as a date of this machine.
    param([object] $Value)
    if ($null -eq $Value -or "$Value" -eq '') { return $null }
    if ($Value -is [datetimeoffset]) { return $Value.UtcDateTime }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
    return [datetimeoffset]::Parse([string] $Value, [cultureinfo]::InvariantCulture).UtcDateTime
}

function Format-Utc {
    param([object] $Value)
    $time = Get-Utc -Value $Value
    if ($null -eq $time) { return $null }
    return $time.ToString('yyyy-MM-ddTHH:mm:ssZ', [cultureinfo]::InvariantCulture)
}

function Get-DeploymentState {
    # What a task's state means for someone who looks at the wall.
    param([Parameter(Mandatory)] [object] $Task)
    switch ([string] $Task.State) {
        'Queued' { return 'queued' }
        'Success' { return 'succeeded' }
        'Failed' { return 'failed' }
        'TimedOut' { return 'failed' }
        'Canceled' { return 'canceled' }
        default {
            # Executing or Cancelling. Stopped for a person is its own state: somebody has to act.
            if ($Task.HasPendingInterruptions) { return 'waiting' }
            return 'executing'
        }
    }
}

# A space named by its name: its id is asked once.
if ($Space -notmatch '^Spaces-\d+$') {
    $named = @((Invoke-Octopus "/api/spaces?partialName=$([uri]::EscapeDataString($Space))&take=100").Items | Where-Object { $_.Name -eq $Space }) | Select-Object -First 1
    if (-not $named) {
        Write-Fail "Octopus $OctopusUrl has no space named '$Space' that this account may read"
        exit 1
    }
    $Space = [string] $named.Id
}

$now = (Get-Date).ToUniversalTime()
# The newest deployment tasks, whatever their state: everything in flight is among them, and what ended lately.
$tasks = @((Invoke-Octopus "/api/$Space/tasks?name=Deploy&take=100").Items)
$deployments = [Collections.Generic.List[object]]::new()
foreach ($task in $tasks) {
    $finished = if ($task.IsCompleted) { Get-Utc -Value $task.CompletedTime } else { $null }
    if ($task.IsCompleted -and (-not $finished -or ($now - $finished).TotalMinutes -gt $FinishedMinutes)) { continue }
    # "Deploy <project> release <release> to <environment>": Octopus's own words for the task.
    $said = [regex]::Match([string] $task.Description, '^Deploy (?<project>.+) release (?<release>\S+) to (?<environment>.+)$')
    if (-not $said.Success) { continue }
    $started = if ($task.StartTime) { $task.StartTime } else { $task.QueueTime }
    $entry = [ordered] @{
        project     = $said.Groups['project'].Value
        environment = $said.Groups['environment'].Value
        release     = $said.Groups['release'].Value
        state       = Get-DeploymentState -Task $task
        since       = Format-Utc -Value $started
    }
    if ($finished) { $entry.finished = Format-Utc -Value $finished }
    $entry.url = "$OctopusUrl/app#/$Space/tasks/$($task.Id)"
    $deployments.Add($entry)
}
$inFlight = @($deployments | Where-Object { -not $_.Contains('finished') } | Sort-Object { $_.since })
$ended = @($deployments | Where-Object { $_.Contains('finished') } | Sort-Object { $_.finished } -Descending)

[ordered] @{
    generated   = $now.ToString('yyyy-MM-ddTHH:mm:ssZ', [cultureinfo]::InvariantCulture)
    system      = $System
    octopus     = "$OctopusUrl/app#/$Space"
    deployments = @($inFlight + $ended)
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Path -Encoding utf8NoBOM
Write-Pass "${Path}: $($inFlight.Count) deployment(s) in flight$(if ($inFlight.Count -gt 0) { " ($(@($inFlight | ForEach-Object { "$($_.project) $($_.release) to $($_.environment): $($_.state)" }) -join '; '))" }), $($ended.Count) ended in the last $FinishedMinutes minutes"
