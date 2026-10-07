#Requires -Version 7.4

<#
.SYNOPSIS
    The collector of the cluster's status page: every few seconds it reads the nodes, the pods and their use of CPU and
    memory from the Kubernetes API and writes them as one file, cluster.json, which a web server next to it serves.

.DESCRIPTION
    Runs in the cluster as Deployment cluster-status (cluster-status.yaml next to this file; the folder's
    kustomization puts this file into a ConfigMap, so a change here restarts the collector), as a service account that
    may only read nodes, pods, volume claims and their metrics. The health dashboard reads the file from the visitor's browser (topology.json cluster.statusUrl):
    names, states and usage, nothing of what a pod is configured with.

    cluster.json (the contract is in the dashboard repository's README, "The cluster view"): generated, intervalSeconds,
    kubernetesVersion, nodes[] (ready, pressures, pool, size, CPU and memory: usage, allocatable, requests, limits; pods:
    count, capacity) and namespaces[] with pods[] (workload, kind, phase, ready, restarts, reason, CPU and memory: usage,
    requests, limits) and volumes[]. CPU is in millicores, memory in bytes; a value Kubernetes does not have is null.

    A round that fails writes nothing and logs one line: the file keeps its last time, and the page says how old it is.
    -Fixture reads the API's answers from a folder instead (nodes.json, pods.json, claims.json, node-metrics.json,
    pod-metrics.json, version.json) and writes one round: the test of this script.
#>
[CmdletBinding()]
param(
    [string] $OutputPath = '/out/cluster.json',
    [ValidateRange(5, 300)] [int] $IntervalSeconds = 15,
    [string] $Fixture = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$api = 'https://kubernetes.default.svc'
$account = '/var/run/secrets/kubernetes.io/serviceaccount'

function Get-Api {
    # One list of the Kubernetes API. The token is read every time: the kubelet renews it. The API server's
    # certificate is checked against the cluster's own authority (SSL_CERT_FILE of the container).
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [string] $File)
    if ($Fixture) { return Get-Content -LiteralPath (Join-Path $Fixture $File) -Raw | ConvertFrom-Json -AsHashtable }
    $token = (Get-Content -LiteralPath (Join-Path $account 'token') -Raw).Trim()
    $answer = Invoke-WebRequest -Uri "$api$Path" -Headers @{ Authorization = "Bearer $token" } -TimeoutSec 20
    return $answer.Content | ConvertFrom-Json -AsHashtable
}

function ConvertTo-Number {
    # A Kubernetes quantity as a number of its base unit: "250m" 0.25, "2" 2, "123456789n" 0.123456789, "512Mi"
    # 536870912, "1G" 1000000000, "1e3" 1000.
    param([string] $Quantity)
    if (-not $Quantity) { return $null }
    if ($Quantity -notmatch '^([+-]?[0-9.]+(?:[eE][+-]?[0-9]+)?)(n|u|m|k|K|M|G|T|P|E|Ki|Mi|Gi|Ti|Pi|Ei)?$') { return $null }
    $number = [double]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture)
    $factor = switch -CaseSensitive ($Matches[2]) {
        'n' { 1e-9 } 'u' { 1e-6 } 'm' { 1e-3 } 'k' { 1e3 } 'K' { 1e3 } 'M' { 1e6 } 'G' { 1e9 } 'T' { 1e12 } 'P' { 1e15 } 'E' { 1e18 }
        'Ki' { 1024 } 'Mi' { [math]::Pow(1024, 2) } 'Gi' { [math]::Pow(1024, 3) } 'Ti' { [math]::Pow(1024, 4) }
        'Pi' { [math]::Pow(1024, 5) } 'Ei' { [math]::Pow(1024, 6) }
        default { 1 }
    }
    return $number * $factor
}

function ConvertTo-Millicore { param([string] $Quantity) $value = ConvertTo-Number $Quantity; if ($null -eq $value) { $null } else { [long] [math]::Round($value * 1000) } }
function ConvertTo-Byte { param([string] $Quantity) $value = ConvertTo-Number $Quantity; if ($null -eq $value) { $null } else { [long] [math]::Round($value) } }

function Get-Sum {
    # The sum of the values that exist, or null when none does (no container sets a limit, say).
    param([object[]] $Values)
    $present = @($Values | Where-Object { $null -ne $_ })
    if ($present.Count -eq 0) { return $null }
    return [long] ($present | Measure-Object -Sum).Sum
}

function Get-Time {
    # A time of the API as UTC text, or null. ConvertFrom-Json hands a text that looks like a time on as a date
    # (UTC, as the API writes it); a text is read as UTC too.
    param($Value)
    if (-not $Value) { return $null }
    $time = if ($Value -is [datetime]) { $Value.ToUniversalTime() }
    else { [datetime]::Parse([string] $Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles] 'AssumeUniversal, AdjustToUniversal') }
    return $time.ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
}

function Get-Workload {
    # The workload a pod belongs to and its kind, from the pod's owner: a ReplicaSet's name without its hash is the
    # Deployment's, a Job's without its run number the CronJob's.
    param([hashtable] $Pod)
    $owner = @($Pod.metadata['ownerReferences'] | Where-Object { $_ }) | Select-Object -First 1
    if (-not $owner) { return @{ kind = 'Pod'; workload = [string] $Pod.metadata.name } }
    $name = [string] $owner.name
    switch ([string] $owner.kind) {
        'ReplicaSet' { return @{ kind = 'Deployment'; workload = $name -replace '-[a-z0-9]{5,10}$', '' } }
        # db-backup-29853070 (a CronJob's run), restore-test-20261005-040540 (a job named by its time).
        'Job' { return @{ kind = 'Job'; workload = $name -replace '(-\d{6,})+$', '' } }
        default { return @{ kind = [string] $owner.kind; workload = $name } }
    }
}

function Get-ClusterStatus {
    $version = Get-Api '/version' 'version.json'
    $nodeList = @((Get-Api '/api/v1/nodes' 'nodes.json').items | Where-Object { $_ })
    $podList = @((Get-Api '/api/v1/pods' 'pods.json').items | Where-Object { $_ })
    $claimList = @((Get-Api '/api/v1/persistentvolumeclaims' 'claims.json').items | Where-Object { $_ })
    # The metrics API answers a moment after a pod starts and not at all while the metrics server restarts: usage is
    # then null, and everything else still stands.
    $nodeUse = @{}
    $podUse = @{}
    try {
        foreach ($item in @((Get-Api '/apis/metrics.k8s.io/v1beta1/nodes' 'node-metrics.json').items | Where-Object { $_ })) { $nodeUse[[string] $item.metadata.name] = $item.usage }
        foreach ($item in @((Get-Api '/apis/metrics.k8s.io/v1beta1/pods' 'pod-metrics.json').items | Where-Object { $_ })) {
            $podUse["$($item.metadata.namespace)/$($item.metadata.name)"] = @{
                cpu    = Get-Sum @($item.containers | ForEach-Object { ConvertTo-Millicore ([string] $_.usage['cpu']) })
                memory = Get-Sum @($item.containers | ForEach-Object { ConvertTo-Byte ([string] $_.usage['memory']) })
            }
        }
    }
    catch { Write-Host "$(Get-Date -Format o) metrics not read: $($_.Exception.Message)" }

    $pods = foreach ($pod in $podList) {
        $containers = @($pod.spec.containers | Where-Object { $_ })
        $statuses = @($pod.status['containerStatuses'] | Where-Object { $_ })
        $phase = [string] $pod.status['phase']
        $ready = @($pod.status['conditions'] | Where-Object { $_ -and $_.type -eq 'Ready' -and $_.status -eq 'True' }).Count -gt 0
        $waiting = @($statuses | Where-Object { -not $_.ready } | ForEach-Object {
                if ($_.state['waiting']) { [string] $_.state.waiting['reason'] } elseif ($_.state['terminated']) { [string] $_.state.terminated['reason'] }
            } | Where-Object { $_ }) | Select-Object -First 1
        $reason = if ($waiting) { $waiting } elseif ($pod.status['reason']) { [string] $pod.status.reason } elseif ($phase -eq 'Succeeded') { 'Completed' } else { $null }
        $use = $podUse["$($pod.metadata.namespace)/$($pod.metadata.name)"]
        $owner = Get-Workload $pod
        [ordered] @{
            namespace       = [string] $pod.metadata.namespace
            name            = [string] $pod.metadata.name
            workload        = $owner.workload
            kind            = $owner.kind
            node            = if ($pod.spec['nodeName']) { [string] $pod.spec.nodeName } else { $null }
            phase           = $phase
            ready           = $ready
            containers      = $containers.Count
            containersReady = @($statuses | Where-Object { $_.ready }).Count
            restarts        = [int] (@($statuses | ForEach-Object { [int] $_.restartCount }) | Measure-Object -Sum).Sum
            reason          = $reason
            # A pod no node has taken yet has no start time: it waits since it was created.
            startedAt       = Get-Time $(if ($pod.status['startTime']) { $pod.status.startTime } else { $pod.metadata['creationTimestamp'] })
            cpu             = [ordered] @{
                usage    = if ($use) { $use.cpu } else { $null }
                requests = Get-Sum @($containers | ForEach-Object { if ($_['resources'] -and $_.resources['requests']) { ConvertTo-Millicore ([string] $_.resources.requests['cpu']) } })
                limits   = Get-Sum @($containers | ForEach-Object { if ($_['resources'] -and $_.resources['limits']) { ConvertTo-Millicore ([string] $_.resources.limits['cpu']) } })
            }
            memory          = [ordered] @{
                usage    = if ($use) { $use.memory } else { $null }
                requests = Get-Sum @($containers | ForEach-Object { if ($_['resources'] -and $_.resources['requests']) { ConvertTo-Byte ([string] $_.resources.requests['memory']) } })
                limits   = Get-Sum @($containers | ForEach-Object { if ($_['resources'] -and $_.resources['limits']) { ConvertTo-Byte ([string] $_.resources.limits['memory']) } })
            }
        }
    }
    $pods = @($pods)

    $nodes = foreach ($node in $nodeList | Sort-Object { [string] $_.metadata.name }) {
        $name = [string] $node.metadata.name
        $labels = if ($node.metadata['labels']) { $node.metadata.labels } else { @{} }
        $conditions = @($node.status['conditions'] | Where-Object { $_ })
        # What the node's running pods ask for: finished pods hold nothing.
        $held = @($pods | Where-Object { $_.node -eq $name -and $_.phase -notin 'Succeeded', 'Failed' })
        $use = $nodeUse[$name]
        $zone = [string] $labels['topology.kubernetes.io/zone']
        [ordered] @{
            name           = $name
            ready          = @($conditions | Where-Object { $_.type -eq 'Ready' -and $_.status -eq 'True' }).Count -gt 0
            pressures      = @($conditions | Where-Object { $_.type -in 'MemoryPressure', 'DiskPressure', 'PIDPressure', 'NetworkUnavailable' -and $_.status -eq 'True' } | ForEach-Object { [string] $_.type })
            unschedulable  = [bool] $node.spec['unschedulable']
            pool           = if ($labels['kubernetes.azure.com/agentpool']) { [string] $labels['kubernetes.azure.com/agentpool'] } elseif ($labels['agentpool']) { [string] $labels['agentpool'] } else { $null }
            size           = if ($labels['node.kubernetes.io/instance-type']) { [string] $labels['node.kubernetes.io/instance-type'] } else { $null }
            # A region without availability zones labels its nodes with zone "0".
            zone           = if ($zone -and $zone -ne '0') { $zone } else { $null }
            kubeletVersion = [string] $node.status.nodeInfo['kubeletVersion']
            createdAt      = Get-Time $node.metadata['creationTimestamp']
            cpu            = [ordered] @{
                usage       = if ($use) { ConvertTo-Millicore ([string] $use['cpu']) } else { $null }
                allocatable = ConvertTo-Millicore ([string] $node.status.allocatable['cpu'])
                requests    = Get-Sum @($held | ForEach-Object { $_.cpu.requests })
                limits      = Get-Sum @($held | ForEach-Object { $_.cpu.limits })
            }
            memory         = [ordered] @{
                usage       = if ($use) { ConvertTo-Byte ([string] $use['memory']) } else { $null }
                allocatable = ConvertTo-Byte ([string] $node.status.allocatable['memory'])
                requests    = Get-Sum @($held | ForEach-Object { $_.memory.requests })
                limits      = Get-Sum @($held | ForEach-Object { $_.memory.limits })
            }
            pods           = [ordered] @{
                count    = $held.Count
                capacity = [int] (ConvertTo-Number ([string] $node.status.allocatable['pods']))
            }
        }
    }

    $spaces = foreach ($space in @($pods | ForEach-Object { $_.namespace }) + @($claimList | ForEach-Object { [string] $_.metadata.namespace }) | Sort-Object -Unique) {
        [ordered] @{
            name    = $space
            pods    = @($pods | Where-Object { $_.namespace -eq $space } | Sort-Object { $_.name } | ForEach-Object { $entry = [ordered] @{}; foreach ($key in $_.Keys | Where-Object { $_ -ne 'namespace' }) { $entry[$key] = $_[$key] }; $entry })
            volumes = @($claimList | Where-Object { [string] $_.metadata.namespace -eq $space } | Sort-Object { [string] $_.metadata.name } | ForEach-Object {
                    [ordered] @{
                        name     = [string] $_.metadata.name
                        capacity = if ($_.status['capacity']) { ConvertTo-Byte ([string] $_.status.capacity['storage']) } else { $null }
                        phase    = [string] $_.status['phase']
                    }
                })
        }
    }

    return [ordered] @{
        generated         = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
        intervalSeconds   = $IntervalSeconds
        kubernetesVersion = [string] $version['gitVersion']
        nodes             = @($nodes)
        namespaces        = @($spaces)
    }
}

function Write-Status {
    # The whole file at once: written beside it, then moved over it, so the web server never serves half a file.
    $status = Get-ClusterStatus
    $temporary = "$OutputPath.tmp"
    $status | ConvertTo-Json -Depth 12 -Compress | Set-Content -LiteralPath $temporary -Encoding utf8NoBOM
    Move-Item -LiteralPath $temporary -Destination $OutputPath -Force
    return $status
}

if ($Fixture) {
    $status = Write-Status
    Write-Host "PASS ${OutputPath}: $(@($status.nodes).Count) node(s), $(@($status.namespaces | ForEach-Object { $_.pods }).Count) pod(s) in $(@($status.namespaces).Count) namespace(s)"
    return
}

Write-Host "==> Cluster status every $IntervalSeconds s to $OutputPath"
$failed = $false
while ($true) {
    $started = Get-Date
    try {
        $status = Write-Status
        if ($failed) { Write-Host "$(Get-Date -Format o) PASS reading again: $(@($status.nodes).Count) node(s), $(@($status.namespaces | ForEach-Object { $_.pods }).Count) pod(s)" }
        $failed = $false
    }
    catch {
        # One line per failed round; the file keeps its last time.
        Write-Host "$(Get-Date -Format o) FAIL $($_.Exception.Message)"
        $failed = $true
    }
    $rest = $IntervalSeconds - ((Get-Date) - $started).TotalSeconds
    if ($rest -gt 0) { Start-Sleep -Milliseconds ([int] ($rest * 1000)) }
}
