# Provider, inputs and the objects every project shares (runtime aks-argocd). Known provider 1.20.0 limits: sort_order 0
# counts as unset, and applies run with -parallelism=1.

variable "octopus_access_token" {
  description = "OIDC access token of the system's service account (OctopusDeploy/login sets OCTOPUS_ACCESS_TOKEN)."
  type        = string
  sensitive   = true
}

variable "github_token" {
  description = "GitHub token of the Git credential the Argo CD steps commit to this repository with (repository secret OCTOPUS_GITHUB_TOKEN)."
  type        = string
  sensitive   = true
}

variable "test_runner_image" {
  description = "Execution container of the acceptance-test steps (on mcr.microsoft.com): Chromium, pwsh and .NET 8; the step adds .NET 10. Match the Playwright version of the app's AcceptanceTests project."
  type        = string
  default     = "playwright/dotnet:v1.54.0-noble"
}

variable "worker_tools_image" {
  description = "Execution container of every script step: kubectl, PowerShell 7 and .NET."
  type        = string
  default     = "octopusdeploy/worker-tools:6.6.5-ubuntu.24.04"
}

locals {
  system         = jsondecode(file("${path.module}/../system.json"))
  slug           = local.system.system.slug
  repository     = "${local.system.system.githubOrg}/${local.system.system.repository}"
  repository_url = "https://github.com/${local.repository}.git"
  environments   = { for i, e in local.system.environments : e.name => merge(e, { sort_order = i + 1 }) }
  deployables    = { for d in local.system.deployables : d.name => d }

  # A deployable with hosting "staticsite" is a static site (the health dashboard): a web server at its own host name,
  # whose per-environment content step "Write dashboard content" commits to Git. Every other one is an app.
  static_deployables = { for name, d in local.deployables : name => d if try(d.hosting, "") == "staticsite" }
  # A deployable with hosting "staticwebapp" is the same site outside the cluster: an Azure Static Web App per
  # environment (infra/cluster.bicep), which its project uploads the release's files to as the tier's deploy identity.
  # It has no Argo CD Application, no pin in a kustomization and nothing to measure or revert in the cluster.
  site_deployables    = { for name, d in local.deployables : name => d if try(d.hosting, "") == "staticwebapp" }
  cluster_deployables = { for name, d in local.deployables : name => d if try(d.hosting, "") != "staticwebapp" }
  tiers               = toset([for e in local.system.environments : e.tier])
  # The first deployable answers at <slug>-<env>.<domain>, every other one at <slug>-<env>-<name>.<domain>.
  host_suffix = { for i, d in local.system.deployables : d.name => i == 0 ? "" : "-${d.name}" }

  # Only deployables with a databasePackage own the database: they migrate it.
  migrated_deployables = { for name, d in local.deployables : name => d if try(d.databasePackage, "") != "" }
  # Environments whose app deployments run the acceptance tests (system.json environments[].acceptanceTests), and the
  # deployables that ship an acceptance-test package (deployables[].acceptanceTestsPackage).
  test_environments = [for name, e in local.environments : name if try(e.acceptanceTests, false)]
  tested_deployables = length(local.test_environments) == 0 ? {} : {
    for name, d in local.deployables : name => d if try(d.acceptanceTestsPackage, "") != ""
  }
  # Every other environment gets the demo employees from the app's own seeder (step "Seed demo employees", right after
  # "Migrate database"); in the environments above, ZDataLoader loads the same employees.
  seeded_deployables = {
    for name, d in local.migrated_deployables : name => d
    if try(d.acceptanceTestsPackage, "") != "" && try(d.dataLoaderAssembly, "") != ""
  }
  # Every environment after the first waits for a sign-off by the team "<slug> approvers" (approvers.tf, shared with
  # templates/system: the people in system.json octopus.approvers; automation answers only with a recorded reason).
  first_environment = local.system.environments[0].name
  # Deployment freezes from system.json: [{ "name", "start", "end", "environments" (default: the prod tier) }].
  freezes              = try(local.system.freezes, [])
  prod_environments    = [for name, e in local.environments : name if e.tier == "prod"]
  nonprod_environments = [for name, e in local.environments : name if e.tier != "prod"]
  # environments[].appCpu (0.5, 1, 1.5 or 2 vCPU) is the app container's CPU limit; its memory limit is twice that in GiB.
  app_memory = { "0.5" = "1Gi", "1" = "2Gi", "1.5" = "3Gi", "2" = "4Gi" }
}

provider "octopusdeploy" {
  address      = local.system.octopus.url
  space_id     = local.system.octopus.spaceId
  access_token = var.octopus_access_token
}

resource "octopusdeploy_environment" "this" {
  for_each = local.environments

  name                         = each.key
  slug                         = each.key
  description                  = "${each.key} (${each.value.tier}) of ${local.system.system.name}: namespace ${local.slug}-${each.key} of ${local.system.cluster.name}. Defined in system.json."
  sort_order                   = each.value.sort_order
  allow_dynamic_infrastructure = false
  use_guided_failure           = false
}

# The first environment deploys automatically; every later one is a manual promotion (an approval in the demo).
resource "octopusdeploy_lifecycle" "system" {
  name        = "${local.slug}-lifecycle"
  description = "Order of the environments in system.json: the first is automatic, the others are promoted by a person."

  dynamic "phase" {
    for_each = local.system.environments
    content {
      name                         = phase.value.name
      automatic_deployment_targets = phase.key == 0 ? [octopusdeploy_environment.this[phase.value.name].id] : []
      optional_deployment_targets  = phase.key == 0 ? [] : [octopusdeploy_environment.this[phase.value.name].id]
    }
  }
}

resource "octopusdeploy_project_group" "system" {
  name        = local.slug
  description = "${local.system.system.name}: the environments (${local.slug}-system) and one project per deployable."
}

# Only with a deployable outside the cluster (hosting "staticwebapp"): one Azure account per tier, restricted to that
# tier's environments; subjects space/project/environment match the federated credentials of id-<slug>-deploy-<tier>
# that the seed created. Nothing in the cluster is deployed with it.
resource "octopusdeploy_azure_openid_connect" "deploy" {
  for_each = length(local.site_deployables) == 0 ? toset([]) : local.tiers

  name                              = "azure-${local.slug}-${each.key}"
  description                       = "id-${local.slug}-deploy-${each.key}: uploads the static sites of ${each.key} (hosting staticwebapp)."
  application_id                    = local.system.azure.identities.deploy[each.key].clientId
  tenant_id                         = local.system.azure.tenantId
  subscription_id                   = local.system.azure.subscriptionId
  audience                          = "api://AzureADTokenExchange"
  execution_subject_keys            = ["space", "project", "environment"]
  environments                      = [for name, e in local.environments : octopusdeploy_environment.this[name].id if e.tier == each.key]
  tenanted_deployment_participation = "Untenanted"
}

data "octopusdeploy_feeds" "built_in" {
  feed_type = "BuiltIn"
  take      = 1
}

resource "octopusdeploy_docker_container_registry" "docker_hub" {
  name                           = "docker-hub"
  feed_uri                       = "https://index.docker.io"
  api_version                    = "v2"
  download_attempts              = 3
  download_retry_backoff_seconds = 10
}

resource "octopusdeploy_docker_container_registry" "mcr" {
  name                           = "mcr"
  feed_uri                       = "https://mcr.microsoft.com"
  api_version                    = "v2"
  download_attempts              = 3
  download_retry_backoff_seconds = 10
}

# The system's registry, read as id-<slug>-feed over OIDC (no stored credential): a release of a deployable names an
# image version, and step "Update deployable" writes it to Git. The seed's federated credential has the subject
# space:<space slug>:feed:acr-<slug>, so the name is fixed.
resource "octopusdeploy_azure_container_registry" "apps" {
  name                           = "acr-${local.slug}"
  feed_uri                       = "https://${local.system.azure.registry.loginServer}"
  api_version                    = "v2"
  download_attempts              = 3
  download_retry_backoff_seconds = 10

  oidc_authentication = {
    client_id    = local.system.azure.identities.feed.clientId
    tenant_id    = local.system.azure.tenantId
    audience     = "api://AzureADTokenExchange"
    subject_keys = ["space", "feed"]
  }
}

# The Argo CD steps choose their Git credential by repository: the one whose restriction holds the Application's
# repository URL (https://octopus.com/docs/argo-cd/steps). This one is restricted to this repository.
resource "octopusdeploy_git_credential" "system" {
  name        = "github-${local.slug}-system"
  description = "Commits of the Argo CD steps to ${local.repository}: the environments' manifests and the image tags."
  type        = "UsernamePassword"
  username    = "x-access-token"
  password    = var.github_token

  repository_restrictions = {
    enabled              = true
    allowed_repositories = [local.repository_url]
  }
}

data "octopusdeploy_worker_pools" "hosted_ubuntu" {
  partial_name = "Hosted Ubuntu"
  take         = 10

  lifecycle {
    postcondition {
      condition     = length([for p in self.worker_pools : p if p.name == "Hosted Ubuntu"]) == 1
      error_message = "The dynamic worker pool 'Hosted Ubuntu' is missing from the space (Octopus Cloud provides it)."
    }
  }
}

# The Kubernetes worker in the cluster (cluster/apply-cluster.ps1 installs and registers it) joins this pool. Steps that
# need the cluster's network or API run there: the database steps, the acceptance tests, the verification.
resource "octopusdeploy_static_worker_pool" "cluster" {
  name        = "${local.slug}-cluster"
  description = "Kubernetes worker in namespace octopus-worker of ${local.system.cluster.name}."
  is_default  = false
}

locals {
  built_in_feed_id       = data.octopusdeploy_feeds.built_in.feeds[0].id
  hosted_worker_pool_id  = one([for p in data.octopusdeploy_worker_pools.hosted_ubuntu.worker_pools : p.id if p.name == "Hosted Ubuntu"])
  cluster_worker_pool_id = octopusdeploy_static_worker_pool.cluster.id
  container = {
    feed_id = octopusdeploy_docker_container_registry.docker_hub.id
    image   = var.worker_tools_image
  }
  test_container = {
    feed_id = octopusdeploy_docker_container_registry.mcr.id
    image   = var.test_runner_image
  }
  # Every script step on the Kubernetes worker.
  script_properties = {
    "Octopus.Action.RunOnServer"         = "true"
    "Octopus.Action.Script.ScriptSource" = "Inline"
    "Octopus.Action.Script.Syntax"       = "PowerShell"
    "OctopusUseBundledTooling"           = "False"
  }
  # Both Argo CD steps: commit to main, and succeed only when Argo CD reports the Application in sync with that commit
  # and healthy. No "Trigger Sync": Octopus documents it for Applications whose auto-sync is off, and ours sync
  # themselves (within a minute: timeout.reconciliation in cluster/argocd-values.yaml). Triggered as well, the
  # step's sync can meet the one Argo CD started and fail with "another operation is already in progress".
  argo_properties = {
    "Octopus.Action.RunOnServer"                     = "true"
    "Octopus.Action.ArgoCD.CommitMethod"             = "DirectCommit"
    "Octopus.Action.ArgoCD.StepVerification.Method"  = "ArgoCDApplicationHealthy"
    "Octopus.Action.ArgoCD.StepVerification.Timeout" = "900"
    "Octopus.Action.ArgoCD.CommitMessageDescription" = "Project: #{Octopus.Project.Slug}\nEnvironment: #{Octopus.Environment.Slug}\nDeployment: #{Octopus.Deployment.Id}"
  }
}
