#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Writes the files of gitops/ that follow from system.json: the Argo CD Applications, the ingress listeners and each
    deployable's manifest templates.

.DESCRIPTION
    system.json is the one description of the system; these files repeat its names (the repository, the registry, the
    environments, the host names), so they are generated, committed, and checked by env-checks (a second run changes
    nothing). Run it after changing system.json:

      gitops/argocd/root.yaml                          the root Application (cluster/apply-cluster.ps1 applies it)
      gitops/argocd/apps/platform.yaml                 Envoy Gateway, cert-manager and gitops/platform
      gitops/argocd/apps/environment-<env>.yaml        <slug>-system-<env> and <slug>-<deployable>-<env>, with the
                                                       annotations that map them to their Octopus project and environment
      gitops/platform/gateway.yaml                     the Gateway: one HTTPS listener per host name (each environment's
                                                       app and in-cluster site, Argo CD, the cluster's status file)
      gitops/platform/kustomization.yaml               what Argo CD applies of gitops/platform
      gitops/templates/environment/apps/<deployable>/  the deployable's Deployment, Service and route (Octostache)

    And, only when missing, the folders Octopus writes to afterwards:

      gitops/environments/<env>/system/                the environment's manifests: step "Apply environment" of
                                                       <slug>-system fills it from gitops/templates/environment
      gitops/environments/<env>/<deployable>/          the pin: step "Update deployable" writes the image tag

    A deployable is an app (the first one: the work-order app with its database) or, with "hosting": "staticsite", a
    static site (the health dashboard): a small web server at its own host name <slug>-<env>-<name>.<domain>, with no
    database connection and with its per-environment content (topology.json, runtime/) in ConfigMap <name>-content,
    which step "Write dashboard content" of its Octopus project commits to
    gitops/environments/<env>/<name>/content.yaml. While the system has a static site, every app's route lets any
    origin read it (cors.yaml): each environment's dashboard asks every environment's public health and version
    endpoints from the visitor's browser.

    With "hosting": "staticwebapp" the dashboard is an Azure Static Web App outside the cluster (infra/cluster.bicep):
    nothing of gitops/ describes it. Either kind of dashboard makes the apps answer other origins and makes the
    cluster report its own status: gitops/platform/cluster-status.yaml (a collector that reads nodes, pods and their
    usage, and a web server for its one file at https://<slug>-cluster.<domain>/cluster.json) is applied only then.

.EXAMPLE
    pwsh -NoProfile -File scripts/write-gitops.ps1
#>
[CmdletBinding()]
param(
    [string] $Root = (Split-Path -Parent $PSScriptRoot)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$system = Get-Content -LiteralPath (Join-Path $Root 'system.json') -Raw | ConvertFrom-Json -AsHashtable
$slug = [string] $system.system.slug
$repositoryUrl = "https://github.com/$($system.system.githubOrg)/$($system.system.repository).git"
$registry = [string] $system.azure.registry.loginServer
$domain = [string] $system.cluster.domain
$environments = @($system.environments | ForEach-Object { [string] $_.name })
# What runs in the cluster. A deployable with hosting "staticwebapp" does not (the dashboard on Azure Static Web
# Apps): nothing of gitops/ describes it, except that it too is a dashboard that reads the apps and the cluster.
$deployables = @($system.deployables | Where-Object { [string] $_['hosting'] -ne 'staticwebapp' })
$sites = @($system.deployables | Where-Object { [string] $_['hosting'] -eq 'staticwebapp' })
function Test-StaticSite { param($Deployable) [string] $Deployable['hosting'] -eq 'staticsite' }
# The first deployable has the environment's own host name, <slug>-<env>.<domain>; every other one <slug>-<env>-<name>.
function Get-HostSuffix { param($Deployable) if ([string] $Deployable.name -eq [string] $deployables[0].name) { '' } else { "-$($Deployable.name)" } }
# A dashboard, in the cluster or outside it: the apps then answer other origins, and the cluster reports its status.
$hasDashboard = $sites.Count -gt 0 -or @($deployables | Where-Object { Test-StaticSite $_ }).Count -gt 0

function Set-File {
    param([string] $Path, [string] $Content, [switch] $KeepExisting)
    $file = Join-Path $Root $Path
    if ($KeepExisting -and (Test-Path -LiteralPath $file)) { return }
    New-Item -ItemType Directory -Path (Split-Path -Parent $file) -Force | Out-Null
    Set-Content -LiteralPath $file -Value ($Content.TrimEnd() + "`n") -Encoding utf8NoBOM -NoNewline
}

$generated = '# Generated by scripts/write-gitops.ps1 from system.json: change system.json and run the script.'
$syncPolicy = @'
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    retry:
      limit: 10
      backoff:
        duration: 30s
        factor: 2
        maxDuration: 5m
'@

Set-File 'gitops/argocd/root.yaml' @"
$generated
# The root Application: Argo CD applies every Application under gitops/argocd/apps.
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root
  namespace: argocd
spec:
  project: default
  source:
    repoURL: $repositoryUrl
    targetRevision: main
    path: gitops/argocd/apps
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
$syncPolicy
"@

Set-File 'gitops/argocd/apps/platform.yaml' @"
$generated
# The platform of the cluster: the ingress (Envoy Gateway), certificates (cert-manager) and gitops/platform (the
# Gateway with its listeners, the certificate issuer, the route of the Argo CD web UI, the rights of the Octopus worker).
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: envoy-gateway
  namespace: argocd
spec:
  project: default
  source:
    repoURL: docker.io/envoyproxy
    chart: gateway-helm
    targetRevision: v1.9.1
    helm:
      releaseName: envoy-gateway
      valuesObject:
        topologyInjector:
          enabled: false
  destination:
    server: https://kubernetes.default.svc
    namespace: platform-ingress
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
    retry:
      limit: 10
      backoff:
        duration: 30s
        factor: 2
        maxDuration: 5m
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cert-manager
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://charts.jetstack.io
    chart: cert-manager
    targetRevision: v1.21.2
    helm:
      releaseName: cert-manager
      valuesObject:
        crds:
          enabled: true
          keep: true
        global:
          leaderElection:
            namespace: cert-manager
        config:
          enableGatewayAPI: true
  destination:
    server: https://kubernetes.default.svc
    namespace: cert-manager
  ignoreDifferences:
    - group: admissionregistration.k8s.io
      kind: ValidatingWebhookConfiguration
      jqPathExpressions:
        - .webhooks[]?.clientConfig.caBundle
        - .webhooks[]?.namespaceSelector
    - group: admissionregistration.k8s.io
      kind: MutatingWebhookConfiguration
      jqPathExpressions:
        - .webhooks[]?.clientConfig.caBundle
        - .webhooks[]?.namespaceSelector
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
      - RespectIgnoreDifferences=true
    retry:
      limit: 10
      backoff:
        duration: 30s
        factor: 2
        maxDuration: 5m
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: platform
  namespace: argocd
spec:
  project: default
  source:
    repoURL: $repositoryUrl
    targetRevision: main
    path: gitops/platform
  destination:
    server: https://kubernetes.default.svc
    namespace: platform-ingress
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - SkipDryRunOnMissingResource=true
    retry:
      limit: 20
      backoff:
        duration: 30s
        factor: 2
        maxDuration: 5m
"@

# One HTTPS listener per host name; cert-manager issues the certificate each listener names (the Gateway's
# cert-manager.io/cluster-issuer annotation). Only the namespace of an environment may attach a route to its listener.
$listeners = [Collections.Generic.List[string]]::new()
$hosts = @(@{ name = 'argocd'; host = "argocd-$slug.$domain"; namespace = 'argocd' })
if ($hasDashboard) { $hosts += @{ name = 'cluster'; host = "$slug-cluster.$domain"; namespace = 'cluster-status' } }
foreach ($environment in $environments) {
    foreach ($deployable in $deployables) {
        $suffix = Get-HostSuffix $deployable
        $hosts += @{ name = "$environment$suffix"; host = "$slug-$environment$suffix.$domain"; namespace = "$slug-$environment" }
    }
}
foreach ($entry in $hosts) {
    $listeners.Add(@"
    - name: https-$($entry.name)
      protocol: HTTPS
      port: 443
      hostname: $($entry.host)
      tls:
        mode: Terminate
        certificateRefs:
          - kind: Secret
            name: tls-$($entry.name)
      allowedRoutes:
        namespaces:
          from: Selector
          selector:
            matchLabels:
              kubernetes.io/metadata.name: $($entry.namespace)
"@)
}

Set-File 'gitops/platform/gateway.yaml' @"
$generated
# The ingress of the cluster: one Envoy proxy behind the public IP the seed created (so the host names are known before
# the cluster exists), HTTP redirected to HTTPS, and one HTTPS listener per host name: each environment's app, each
# further deployable of it, and the Argo CD web UI.
---
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: envoy-gateway
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
  parametersRef:
    group: gateway.envoyproxy.io
    kind: EnvoyProxy
    name: platform-gateway
    namespace: platform-ingress
---
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyProxy
metadata:
  name: platform-gateway
  namespace: platform-ingress
spec:
  provider:
    type: Kubernetes
    kubernetes:
      envoyService:
        type: LoadBalancer
        externalTrafficPolicy: Local
        annotations:
          service.beta.kubernetes.io/azure-load-balancer-resource-group: $($system.azure.resourceGroups.cluster)
          service.beta.kubernetes.io/azure-pip-name: $($system.cluster.ingressPublicIpName)
      envoyDeployment:
        replicas: 1
        container:
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              memory: 512Mi
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: platform-gateway
  namespace: platform-ingress
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-http01
spec:
  gatewayClassName: envoy-gateway
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: Same
$($listeners -join "`n")
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: http-to-https
  namespace: platform-ingress
spec:
  parentRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: platform-gateway
      sectionName: http
  rules:
    - filters:
        - type: RequestRedirect
          requestRedirect:
            scheme: https
            statusCode: 301
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: argocd-ui
  namespace: argocd
spec:
  parentRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: platform-gateway
      namespace: platform-ingress
      sectionName: https-argocd
  hostnames:
    - argocd-$slug.$domain
  rules:
    - backendRefs:
        - name: argocd-server
          port: 80
$(if ($hasDashboard) { @"
---
# The cluster's status file for the health dashboard (cluster-status.yaml): one file, readable by any origin.
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: cluster-status
  namespace: cluster-status
spec:
  parentRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: platform-gateway
      namespace: platform-ingress
      sectionName: https-cluster
  hostnames:
    - $slug-cluster.$domain
  rules:
    - backendRefs:
        - name: cluster-status
          port: 80
"@ })
"@

# What Argo CD applies of gitops/platform. The status collector only while the system has a dashboard to read it; its
# script and its web server's configuration go into a ConfigMap whose name carries their hash, so a change restarts it.
Set-File 'gitops/platform/kustomization.yaml' @"
$generated
# The platform of the cluster, applied by the Argo CD Application "platform" (gitops/argocd/apps/platform.yaml).
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - gateway.yaml
  - issuers.yaml
  - worker-rbac.yaml
$(if ($hasDashboard) { @'
  - cluster-status.yaml
configMapGenerator:
  - name: cluster-status-files
    namespace: cluster-status
    files:
      - collect-status.ps1
      - nginx.conf=cluster-status-nginx.conf
'@ })
"@

foreach ($environment in $environments) {
    $namespace = "$slug-$environment"
    $applications = [Collections.Generic.List[string]]::new()
    $applications.Add(@"
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: $slug-system-$environment
  namespace: argocd
  annotations:
    argo.octopus.com/project: $slug-system
    argo.octopus.com/environment: $environment
    # Only a commit under this path starts a comparison: a pin of another environment does not.
    argocd.argoproj.io/manifest-generate-paths: .
spec:
  project: default
  source:
    repoURL: $repositoryUrl
    targetRevision: main
    path: gitops/environments/$environment/system
  destination:
    server: https://kubernetes.default.svc
    namespace: $namespace
  ignoreDifferences:
    - group: apps
      kind: StatefulSet
      jqPathExpressions:
        - .spec.volumeClaimTemplates[]?.status
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - RespectIgnoreDifferences=true
    retry:
      limit: 5
      backoff:
        duration: 30s
        factor: 2
        maxDuration: 5m
"@)
    foreach ($deployable in $deployables) {
        $applications.Add(@"
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: $slug-$($deployable.name)-$environment
  namespace: argocd
  annotations:
    argo.octopus.com/project: $slug-$($deployable.name)
    argo.octopus.com/environment: $environment
    argo.octopus.com/default-container-registry: $registry
    argocd.argoproj.io/manifest-generate-paths: .;../system/apps/$($deployable.name)
spec:
  project: default
  source:
    repoURL: $repositoryUrl
    targetRevision: main
    path: gitops/environments/$environment/$($deployable.name)
  destination:
    server: https://kubernetes.default.svc
    namespace: $namespace
  # Runbook "Rotate SQL passwords" restarts the Deployment (kubectl rollout restart) so the app reads its new
  # password; the restart's annotation is not a difference to repair.
  ignoreDifferences:
    - group: apps
      kind: Deployment
      jqPathExpressions:
        - .spec.template.metadata.annotations."kubectl.kubernetes.io/restartedAt"
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - RespectIgnoreDifferences=true
    retry:
      limit: 5
      backoff:
        duration: 30s
        factor: 2
        maxDuration: 5m
"@)
    }
    Set-File "gitops/argocd/apps/environment-$environment.yaml" @"
$generated
# Environment ${environment}: its definition (<slug>-system-<env>, written by the Octopus project $slug-system) and one
# Application per deployable (the image tag, written by the deployable's Octopus project). The argo.octopus.com
# annotations hold the slugs of the Octopus project and environment each Application belongs to.
---
$($applications -join "`n---`n")
"@

    # Before the first deployment of <slug>-system to the environment: nothing to apply yet.
    Set-File "gitops/environments/$environment/system/kustomization.yaml" -KeepExisting @"
# Environment ${environment}: step "Apply environment" of the Octopus project $slug-system replaces this folder with
# gitops/templates/environment of the release it deploys. Do not edit it by hand.
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources: []
"@
    foreach ($deployable in $deployables) {
        Set-File "gitops/environments/$environment/system/apps/$($deployable.name)/kustomization.yaml" -KeepExisting @"
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources: []
"@
        $content = if (Test-StaticSite $deployable) { "`n  - content.yaml" } else { '' }
        Set-File "gitops/environments/$environment/$($deployable.name)/kustomization.yaml" -KeepExisting @"
# The version of $($deployable.name) in ${environment}: step "Update deployable" of the Octopus project
# $slug-$($deployable.name) writes newTag. Do not edit it by hand; promote a release in Octopus.
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: $namespace
resources:
  - ../system/apps/$($deployable.name)$content
images:
  - name: $registry/$slug/$($deployable.name)
    newTag: 0.0.0-placeholder
"@
        if (Test-StaticSite $deployable) {
            # Before the first deployment of the site: a topology without environments, so the pod has its ConfigMap.
            Set-File "gitops/environments/$environment/$($deployable.name)/content.yaml" -KeepExisting @"
# What the site of $($deployable.name) shows in ${environment}: step "Write dashboard content" of the Octopus project
# $slug-$($deployable.name) replaces this file with every deployment. Do not edit it by hand.
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: $($deployable.name)-content
data:
  topology.json: |
    { "environments": [] }
"@
        }
    }
}

# The deployable's manifests, as templates of step "Apply environment": Octopus fills in #{...} per environment.
foreach ($deployable in $deployables) {
    $name = [string] $deployable.name
    $folder = "gitops/templates/environment/apps/$name"
    $suffix = Get-HostSuffix $deployable
    $port = [int] $deployable.port
    $static = Test-StaticSite $deployable
    # Every deployable in the cluster, the dashboard too: another dashboard of the system checks it from the browser.
    $cors = $hasDashboard
    Set-File "$folder/kustomization.yaml" @"
$generated
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
  - route.yaml$(if ($cors) { "`n  - cors.yaml" })
"@
    if ($static) {
        Set-File "$folder/deployment.yaml" @"
$generated
# Deployable ${name}, a static site. The image has no tag here: gitops/environments/<env>/$name/kustomization.yaml pins
# it. The web server of the image serves the site, and /topology.json and /runtime/ from ConfigMap $name-content
# (mounted at /content; the kubelet refreshes the files when the ConfigMap changes, without a restart).
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $name
  labels:
    app.kubernetes.io/name: $name
spec:
  replicas: 1
  revisionHistoryLimit: 3
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0
      maxSurge: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: $name
  template:
    metadata:
      labels:
        app.kubernetes.io/name: $name
    spec:
      automountServiceAccountToken: false
      securityContext:
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: $name
          image: $registry/$slug/$name
          ports:
            - name: http
              containerPort: $port
              protocol: TCP
          volumeMounts:
            - name: content
              mountPath: /content
              readOnly: true
          startupProbe:
            tcpSocket:
              port: http
            periodSeconds: 2
            failureThreshold: 60
          readinessProbe:
            tcpSocket:
              port: http
            periodSeconds: 10
          resources:
            requests:
              cpu: 10m
              memory: 32Mi
            limits:
              cpu: 200m
              memory: 128Mi
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop:
                - ALL
      volumes:
        - name: content
          configMap:
            name: $name-content
---
apiVersion: v1
kind: Service
metadata:
  name: $name
  labels:
    app.kubernetes.io/name: $name
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: $name
  ports:
    - name: http
      port: $port
      targetPort: http
      protocol: TCP
"@
    }
    else {
        Set-File "$folder/deployment.yaml" @"
$generated
# Deployable ${name}. The image has no tag here: gitops/environments/<env>/$name/kustomization.yaml pins it.
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $name
  labels:
    app.kubernetes.io/name: $name
spec:
  replicas: 1
  revisionHistoryLimit: 3
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0
      maxSurge: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: $name
  template:
    metadata:
      labels:
        app.kubernetes.io/name: $name
    spec:
      automountServiceAccountToken: false
      securityContext:
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: $name
          image: $registry/$slug/$name
          ports:
            - name: http
              containerPort: $port
              protocol: TCP
          env:
            - name: ASPNETCORE_HTTP_PORTS
              value: "$port"
            - name: ConnectionStrings__SqlConnectionString
              valueFrom:
                secretKeyRef:
                  name: db-credentials
                  key: app-connection-string
            # No OpenTelemetry collector in the cluster: the app's OTLP exporter stays off.
            - name: OTEL_EXPORTER_OTLP_ENDPOINT
              value: ""
            # Telemetry goes to the environment's Application Insights under the app's own name, when the
            # environment has capability "telemetry": the cluster job then keeps the connection string in Secret
            # "telemetry" (it never reaches Git), and the variable names that Secret. Without the capability the
            # variable names a Secret that does not exist, the app gets no connection string and exports nothing.
            - name: OTEL_SERVICE_NAME
              value: "$slug-$name"
            - name: APPLICATIONINSIGHTS_CONNECTION_STRING
              valueFrom:
                secretKeyRef:
                  name: "#{Telemetry.Secret}"
                  key: connection-string
                  optional: true
          startupProbe:
            tcpSocket:
              port: http
            periodSeconds: 5
            failureThreshold: 60
          readinessProbe:
            tcpSocket:
              port: http
            periodSeconds: 10
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              cpu: "#{App.CpuLimit}"
              memory: "#{App.MemoryLimit}"
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop:
                - ALL
---
apiVersion: v1
kind: Service
metadata:
  name: $name
  labels:
    app.kubernetes.io/name: $name
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: $name
  ports:
    - name: http
      port: $port
      targetPort: http
      protocol: TCP
"@
    }
    Set-File "$folder/route.yaml" @"
$generated
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: $name
spec:
  parentRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: platform-gateway
      namespace: platform-ingress
      sectionName: "https-#{Octopus.Environment.Name}$suffix"
  hostnames:
    - "#{System.Slug}-#{Octopus.Environment.Name}$suffix.#{Cluster.Domain}"
  rules:
    - backendRefs:
        - name: $name
          port: $port
"@
    $corsFile = Join-Path $Root $folder 'cors.yaml'
    if ($cors) {
        Set-File "$folder/cors.yaml" @"
$generated
# Any origin may read this deployable's answers (GET only, no credentials): the health dashboard is a page in the
# visitor's browser, and each dashboard asks the public health and version endpoints of every environment's apps and of
# the system's other dashboards.
---
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: SecurityPolicy
metadata:
  name: $name-cors
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: $name
  cors:
    allowOrigins:
      - "*"
    allowMethods:
      - GET
    maxAge: 10m
"@
    }
    elseif (Test-Path -LiteralPath $corsFile) {
        Remove-Item -LiteralPath $corsFile
    }
}

# A site outside the cluster records its address where its deployment put it (gitops/environments/<env>/<name>/
# site.json). In an environment the deployable no longer names (deployables[].environments) the record is stale: the
# site is removed there, and nothing may read its address any more.
foreach ($site in $sites) {
    $named = if ($site['environments']) { @($site.environments | ForEach-Object { [string] $_ }) } else { $environments }
    foreach ($environment in @($environments | Where-Object { $named -notcontains $_ })) {
        $record = Join-Path $Root 'gitops' 'environments' $environment ([string] $site.name) 'site.json'
        if (Test-Path -LiteralPath $record) {
            Remove-Item -LiteralPath $record
            $folder = Split-Path -Parent $record
            if (-not @(Get-ChildItem -LiteralPath $folder -Force)) { Remove-Item -LiteralPath $folder }
        }
    }
}

Write-Host "PASS gitops/ written for $($environments -join ', ') and $(@($deployables | ForEach-Object { $_.name }) -join ', ')"
