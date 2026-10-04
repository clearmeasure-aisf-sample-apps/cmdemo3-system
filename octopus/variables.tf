# Project variables. The scripts and the manifest templates read only these names; every value comes from system.json.

locals {
  # One entry per project and variable name; environment = null means unscoped.
  project_ids = merge(
    { system = octopusdeploy_project.system.id },
    { for name, project in octopusdeploy_project.deployable : name => project.id }
  )

  shared_variables = flatten([
    for project, id in local.project_ids : [
      { key = "${project}-slug", project = id, name = "System.Slug", value = local.slug, environment = null },
      { key = "${project}-repository", project = id, name = "System.Repository", value = local.repository, environment = null },
      { key = "${project}-deployables", project = id, name = "System.Deployables", value = jsonencode([for d in local.system.deployables : { name = d.name, healthPath = d.healthPath }]), environment = null },
      { key = "${project}-registry", project = id, name = "Azure.RegistryServer", value = local.system.azure.registry.loginServer, environment = null },
      { key = "${project}-domain", project = id, name = "Cluster.Domain", value = local.system.cluster.domain, environment = null },
      { key = "${project}-database", project = id, name = "Database.Name", value = local.slug, environment = null },
      { key = "${project}-login", project = id, name = "Database.AppLogin", value = "app", environment = null },
      { key = "${project}-deployable", project = id, name = "Deployable.Name", value = project == "system" ? "" : project, environment = null },
    ]
  ])

  # The values the manifest templates of gitops/templates/environment take (step "Apply environment").
  template_variables = flatten([
    { key = "system-sql-edition", project = octopusdeploy_project.system.id, name = "Sql.Edition", value = local.system.sql.edition, environment = null },
    [for name, e in local.environments : [
      { key = "system-tier-${name}", project = octopusdeploy_project.system.id, name = "Environment.Tier", value = e.tier, environment = name },
      { key = "system-cpu-${name}", project = octopusdeploy_project.system.id, name = "App.CpuLimit", value = "${floor(tonumber(try(e.appCpu, "0.5")) * 1000)}m", environment = name },
      { key = "system-memory-${name}", project = octopusdeploy_project.system.id, name = "App.MemoryLimit", value = local.app_memory[try(e.appCpu, "0.5")], environment = name },
    ]],
  ])

  deployable_variables = flatten([
    for name, d in local.deployables : [
      { key = "${name}-assembly", project = octopusdeploy_project.deployable[name].id, name = "Database.Assembly", value = try(d.databaseAssembly, ""), environment = null },
    ]
  ])

  test_variables = flatten([
    for name, d in local.tested_deployables : [
      { key = "${name}-tests-assembly", project = octopusdeploy_project.deployable[name].id, name = "AcceptanceTests.Assembly", value = d.acceptanceTestsAssembly, environment = null },
      # 0: sized from the worker (1.5 per core, 0.5 GB of memory per browser, at most 16).
      { key = "${name}-tests-workers", project = octopusdeploy_project.deployable[name].id, name = "AcceptanceTests.Workers", value = tostring(try(d.acceptanceTestsWorkers, 0)), environment = null },
      { key = "${name}-tests-delay", project = octopusdeploy_project.deployable[name].id, name = "AcceptanceTests.InputDelayMs", value = "200", environment = null },
    ]
  ])

  # DataLoader.Assembly: the assembly of ZDataLoader (step "Acceptance tests") and of the demo-employee seeder (step
  # "Seed demo employees") in the acceptance-test package.
  loader_variables = [
    for name, d in merge(local.tested_deployables, local.seeded_deployables) : {
      key         = "${name}-loader-assembly"
      project     = octopusdeploy_project.deployable[name].id
      name        = "DataLoader.Assembly"
      value       = d.dataLoaderAssembly
      environment = null
    }
  ]

  string_variables = { for v in concat(local.shared_variables, local.template_variables, local.deployable_variables, local.test_variables, local.loader_variables) : v.key => v }
}

resource "octopusdeploy_variable" "string" {
  for_each = local.string_variables

  owner_id = each.value.project
  name     = each.value.name
  type     = "String"
  value    = each.value.value

  dynamic "scope" {
    for_each = each.value.environment == null ? [] : [each.value.environment]
    content {
      environments = [octopusdeploy_environment.this[scope.value].id]
    }
  }
}

# One task per environment at a time, across both projects: a system deployment and an app deployment touch the same
# namespace and database. Octopus queues tasks that share a concurrency tag.
resource "octopusdeploy_variable" "concurrency_tag" {
  for_each = local.project_ids

  owner_id    = each.value
  name        = "Octopus.Task.ConcurrencyTag"
  type        = "String"
  value       = "#{Octopus.Environment.Id}"
  description = "Serializes deployments per environment across projects."
}
