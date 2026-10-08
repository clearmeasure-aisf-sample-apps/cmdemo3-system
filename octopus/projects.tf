# The projects (runtime aks-argocd). <slug>-system applies an environment's definition: its releases are commits of
# this repository, and a deployment writes gitops/templates/environment of that commit to
# gitops/environments/<env>/system, which Argo CD applies. <slug>-<deployable> deploys one app release (created by the
# app repository's release workflow): it writes the image tag to gitops/environments/<env>/<deployable>. Both use the
# Argo CD steps of Octopus; the script steps live in ../scripts and are read here, so a script change reaches Octopus
# on the next push.

resource "octopusdeploy_project" "system" {
  name                              = "${local.slug}-system"
  slug                              = "${local.slug}-system"
  description                       = "Environments of ${local.system.system.name}: each release is a commit of ${local.repository}; a deployment writes one environment's manifests to Git, and Argo CD applies them."
  project_group_id                  = octopusdeploy_project_group.system.id
  lifecycle_id                      = octopusdeploy_lifecycle.system.id
  tenanted_deployment_participation = "Untenanted"
  default_guided_failure_mode       = "Off"
}

resource "octopusdeploy_project" "deployable" {
  for_each = local.deployables

  name                              = "${local.slug}-${each.key}"
  slug                              = "${local.slug}-${each.key}"
  description                       = contains(keys(local.site_deployables), each.key) ? "Static site ${each.key} from ${local.system.system.githubOrg}/${each.value.repository}, outside the cluster on Azure Static Web Apps: write its content, upload it and record its address in Git, verify." : contains(keys(local.static_deployables), each.key) ? "Static site ${each.key} from ${local.system.system.githubOrg}/${each.value.repository}: write its content and the image tag to Git, verify." : "Deployable ${each.key} from ${local.system.system.githubOrg}/${each.value.repository}: migrate, write the image tag to Git, verify."
  project_group_id                  = octopusdeploy_project_group.system.id
  lifecycle_id                      = octopusdeploy_lifecycle.system.id
  tenanted_deployment_participation = "Untenanted"
  default_guided_failure_mode       = "Off"
}

# ---------------------------------------------------------------- <slug>-system

resource "octopusdeploy_process" "system" {
  project_id = octopusdeploy_project.system.id
}

# Every environment but the first: the step excludes the first instead of naming the others, because a release keeps
# the process as it was when the release was created. A release made before an environment existed then still stops
# at the sign-off when it is promoted there (first live run of cmdemo3: release 2.4.1 reached uat without one).
resource "octopusdeploy_process_step" "system_sign_off" {
  process_id            = octopusdeploy_process.system.id
  name                  = "Sign-off"
  type                  = "Octopus.Manual"
  excluded_environments = [octopusdeploy_environment.this[local.first_environment].id]

  execution_properties = {
    "Octopus.Action.RunOnServer"                       = "false"
    "Octopus.Action.Manual.Instructions"               = "Sign off #{Octopus.Project.Name} #{Octopus.Release.Number} for #{Octopus.Environment.Name}: check the earlier environments, then Proceed with a note, or Abort."
    "Octopus.Action.Manual.ResponsibleTeamIds"         = local.sign_off_team_id
    "Octopus.Action.Manual.BlockConcurrentDeployments" = "False"
  }
}

resource "octopusdeploy_process_step" "system_prepare" {
  process_id     = octopusdeploy_process.system.id
  name           = "Prepare environment"
  type           = "Octopus.Script"
  worker_pool_id = local.cluster_worker_pool_id
  container      = local.container

  execution_properties = merge(local.script_properties, {
    "Octopus.Action.Script.ScriptBody" = file("${path.module}/../scripts/prepare-environment.ps1")
  })
}

# The environment's manifests are templates in this repository, at the commit of the release. The step fills in the
# project's variables and commits the result to the path of the Argo CD Application annotated with this project and
# the deployment's environment (gitops/argocd/apps/environment-<env>.yaml): a promotion applies the tested commit.
resource "octopusdeploy_process_step" "system_apply" {
  process_id     = octopusdeploy_process.system.id
  name           = "Apply environment"
  type           = "Octopus.ArgoCDUpdateManifests"
  worker_pool_id = local.hosted_worker_pool_id

  git_dependencies = {
    "" = {
      repository_uri      = local.repository_url
      default_branch      = "main"
      git_credential_type = "Library"
      git_credential_id   = octopusdeploy_git_credential.system.id
      # Provider 1.20.0 reads an unset connection back as "" and then reports an inconsistent result.
      github_connection_id = ""
    }
  }

  execution_properties = merge(local.argo_properties, {
    "Octopus.Action.Script.ScriptSource"         = "GitRepository"
    "Octopus.Action.GitRepository.Source"        = "External"
    "Octopus.Action.ArgoCD.InputPath"            = "gitops/templates/environment"
    "Octopus.Action.ArgoCD.PurgeOutputFolder"    = "True"
    "Octopus.Action.ArgoCD.CommitMessageSummary" = "Apply #{Octopus.Project.Name} #{Octopus.Release.Number} to #{Octopus.Environment.Name}"
  })
}

resource "octopusdeploy_process_step" "system_database" {
  process_id     = octopusdeploy_process.system.id
  name           = "Initialize database"
  type           = "Octopus.Script"
  worker_pool_id = local.cluster_worker_pool_id
  container      = local.container

  execution_properties = merge(local.script_properties, {
    "Octopus.Action.Script.ScriptBody" = file("${path.module}/../scripts/initialize-database.ps1")
  })
}

resource "octopusdeploy_process_step" "system_verify" {
  process_id     = octopusdeploy_process.system.id
  name           = "Verify environment"
  type           = "Octopus.Script"
  worker_pool_id = local.cluster_worker_pool_id
  container      = local.container

  execution_properties = merge(local.script_properties, {
    "Octopus.Action.Script.ScriptBody" = file("${path.module}/../scripts/verify-environment.ps1")
  })
}

# Started together with "Apply environment": the apps' availability while Argo CD applies the environment's manifests
# (scripts/measure-availability.ps1, CAP-044).
resource "octopusdeploy_process_step" "system_measure" {
  process_id     = octopusdeploy_process.system.id
  name           = "Measure availability"
  type           = "Octopus.Script"
  start_trigger  = "StartWithPrevious"
  worker_pool_id = local.cluster_worker_pool_id
  container      = local.container

  execution_properties = merge(local.script_properties, {
    "Octopus.Action.Script.ScriptBody" = file("${path.module}/../scripts/measure-availability.ps1")
  })
}

resource "octopusdeploy_process_steps_order" "system" {
  process_id = octopusdeploy_process.system.id
  steps = concat(
    [
      octopusdeploy_process_step.system_sign_off.id,
      octopusdeploy_process_step.system_prepare.id,
      octopusdeploy_process_step.system_apply.id,
      octopusdeploy_process_step.system_measure.id,
      octopusdeploy_process_step.system_database.id,
      octopusdeploy_process_step.system_verify.id,
    ],
  )
}

# ---------------------------------------------------------------- <slug>-<deployable>

resource "octopusdeploy_process" "deployable" {
  for_each = local.deployables

  project_id = octopusdeploy_project.deployable[each.key].id
}

resource "octopusdeploy_process_step" "sign_off" {
  for_each = local.deployables

  process_id            = octopusdeploy_process.deployable[each.key].id
  name                  = "Sign-off"
  type                  = "Octopus.Manual"
  excluded_environments = [octopusdeploy_environment.this[local.first_environment].id]

  execution_properties = {
    "Octopus.Action.RunOnServer"                       = "false"
    "Octopus.Action.Manual.Instructions"               = "Sign off #{Octopus.Project.Name} #{Octopus.Release.Number} for #{Octopus.Environment.Name}: check the earlier environments, then Proceed with a note, or Abort."
    "Octopus.Action.Manual.ResponsibleTeamIds"         = local.sign_off_team_id
    "Octopus.Action.Manual.BlockConcurrentDeployments" = "False"
  }
}

# Prod tier: a verified backup of the database before the release changes anything (scripts/record-restore-point.ps1).
# The step excludes the nonprod environments instead of naming the prod ones, so a release made before prod existed
# still records its restore point there.
resource "octopusdeploy_process_step" "restore_point" {
  for_each = local.migrated_deployables

  process_id            = octopusdeploy_process.deployable[each.key].id
  name                  = "Record restore point"
  type                  = "Octopus.Script"
  excluded_environments = [for name in local.nonprod_environments : octopusdeploy_environment.this[name].id]
  worker_pool_id        = local.cluster_worker_pool_id
  container             = local.container

  execution_properties = merge(local.script_properties, {
    "Octopus.Action.Script.ScriptBody" = file("${path.module}/../scripts/record-restore-point.ps1")
  })
}

resource "octopusdeploy_process_step" "migrate" {
  for_each = local.migrated_deployables

  process_id     = octopusdeploy_process.deployable[each.key].id
  name           = "Migrate database"
  type           = "Octopus.Script"
  worker_pool_id = local.cluster_worker_pool_id
  container      = local.container

  packages = {
    database = {
      package_id           = each.value.databasePackage
      feed_id              = local.built_in_feed_id
      acquisition_location = "Server"
      properties = {
        Extract       = "True"
        Purpose       = ""
        SelectionMode = "immediate"
      }
    }
  }

  execution_properties = merge(local.script_properties, {
    "Octopus.Action.Script.ScriptBody" = file("${path.module}/../scripts/migrate-database.ps1")
  })
}

# Only in the environments without acceptance tests (ZDataLoader loads the same employees where the tests run): the
# app's demo employees, from the seeder in the release's acceptance-test package. The step excludes the test
# environments instead of naming the others, so a release made before an environment existed seeds it too.
resource "octopusdeploy_process_step" "seed_demo_employees" {
  for_each = local.seeded_deployables

  process_id            = octopusdeploy_process.deployable[each.key].id
  name                  = "Seed demo employees"
  type                  = "Octopus.Script"
  excluded_environments = [for name in local.test_environments : octopusdeploy_environment.this[name].id]
  worker_pool_id        = local.cluster_worker_pool_id
  container             = local.container

  packages = {
    tests = {
      package_id           = each.value.acceptanceTestsPackage
      feed_id              = local.built_in_feed_id
      acquisition_location = "Server"
      properties = {
        Extract       = "True"
        Purpose       = ""
        SelectionMode = "immediate"
      }
    }
  }

  execution_properties = merge(local.script_properties, {
    "Octopus.Action.Script.ScriptBody" = file("${path.module}/../scripts/seed-demo-employees.ps1")
  })
}

# The release's image version of the deployable, written as newTag to gitops/environments/<env>/<deployable> (the
# path of the Argo CD Application annotated with this project and the deployment's environment). The package is a
# reference to the image in the system's registry, never downloaded.
resource "octopusdeploy_process_step" "update" {
  for_each = local.cluster_deployables

  process_id     = octopusdeploy_process.deployable[each.key].id
  name           = "Update deployable"
  type           = "Octopus.ArgoCDUpdateImageTags"
  worker_pool_id = local.hosted_worker_pool_id

  packages = {
    (each.key) = {
      package_id           = "${local.slug}/${each.key}"
      feed_id              = octopusdeploy_azure_container_registry.apps.id
      acquisition_location = "NotAcquired"
      properties = {
        Extract       = "False"
        Purpose       = "DockerImageReference"
        SelectionMode = "immediate"
      }
    }
  }

  # A new app version starts within two minutes (Argo CD finds the commit within one): five minutes without a healthy
  # rollout is a version that cannot start, and step "Revert pin" then names the reason and puts the old tag back.
  execution_properties = merge(local.argo_properties, {
    "Octopus.Action.ArgoCD.CommitMessageSummary"     = "Pin #{Octopus.Project.Name} #{Octopus.Release.Number} in #{Octopus.Environment.Name}"
    "Octopus.Action.ArgoCD.StepVerification.Timeout" = "300"
  })
}

# A static site (the health dashboard) shows what its deployment wrote for the environment: topology.json and the
# runtime diagrams, rendered from system.json on main and committed as ConfigMap <name>-content to
# gitops/environments/<env>/<name>/content.yaml (scripts/write-dashboard-content.ps1). After "Update deployable": the
# step waits until the site serves what it wrote, which the site's image must be running for.
resource "octopusdeploy_process_step" "content" {
  for_each = local.static_deployables

  process_id     = octopusdeploy_process.deployable[each.key].id
  name           = "Write dashboard content"
  type           = "Octopus.Script"
  worker_pool_id = local.cluster_worker_pool_id
  container      = local.container

  execution_properties = merge(local.script_properties, {
    "Octopus.Action.Script.ScriptBody" = join("\n", [local.github_token_functions, file("${path.module}/../scripts/write-dashboard-content.ps1")])
  })
}

# A site outside the cluster (hosting "staticwebapp", the dashboard on Azure Static Web Apps): the release's zip
# (package <slug>-<deployable> in the built-in feed, extracted) with the same content written into it, uploaded with
# the site's deployment token as the tier's deploy identity, and its address and version recorded in Git
# (gitops/environments/<env>/<name>/site.json). On the hosted pool, so the site can be deployed while the cluster
# is stopped (scripts/write-dashboard-content.ps1).
resource "octopusdeploy_process_step" "upload_site" {
  for_each = local.site_deployables

  process_id     = octopusdeploy_process.deployable[each.key].id
  name           = "Update deployable"
  type           = "Octopus.AzurePowerShell"
  worker_pool_id = local.hosted_worker_pool_id
  container      = local.container

  packages = {
    site = {
      package_id           = "${local.slug}-${each.key}"
      feed_id              = local.built_in_feed_id
      acquisition_location = "Server"
      properties = {
        Extract       = "True"
        Purpose       = ""
        SelectionMode = "immediate"
      }
    }
  }

  execution_properties = merge(local.script_properties, {
    "Octopus.Action.Azure.AccountId"   = "#{Azure.Account}"
    "Octopus.Action.Script.ScriptBody" = join("\n", [local.github_token_functions, file("${path.module}/../scripts/write-dashboard-content.ps1")])
  })
}

resource "octopusdeploy_process_step" "verify_site" {
  for_each = local.site_deployables

  process_id     = octopusdeploy_process.deployable[each.key].id
  name           = "Verify deployable"
  type           = "Octopus.Script"
  worker_pool_id = local.hosted_worker_pool_id
  container      = local.container

  execution_properties = merge(local.script_properties, {
    "Octopus.Action.Script.ScriptBody" = join("\n", [local.github_token_functions, file("${path.module}/../scripts/verify-site.ps1")])
  })
}

# Runs only when an earlier step failed: names why the new version cannot start and commits the previous tag back
# (scripts/revert-pin.ps1). It stands before the test steps, so failed acceptance tests fail the deployment, which
# blocks its promotion, but leave the version that runs pinned. "Verify revert" follows it.
resource "octopusdeploy_process_step" "revert_pin" {
  for_each = local.cluster_deployables

  process_id     = octopusdeploy_process.deployable[each.key].id
  name           = "Revert pin"
  type           = "Octopus.Script"
  condition      = "Failure"
  worker_pool_id = local.cluster_worker_pool_id
  container      = local.container

  execution_properties = merge(local.script_properties, {
    "Octopus.Action.Script.ScriptBody" = join("\n", [local.github_token_functions, file("${path.module}/../scripts/revert-pin.ps1")])
  })
}

# Right after "Revert pin", and like it only when an earlier step failed: asks whether the deployable is in service
# after the revert, at its public address (scripts/verify-revert.ps1). "Revert pin" waits for the previous tag's
# replicas; nothing else asks the application's health once a deployment has failed, and a rollback nobody verifies
# can leave an environment down while the deployment reads as rolled back (the kit's decision 0018, which asks for a
# step after the rollback whose slug starts with "verify-", that waits for it and runs when the deployment has
# failed). Octopus makes the slug from the name: "Verify revert" is verify-revert, as in the other runtime. The step
# reads the cluster and the public address only, so it receives no GitHub credential (github.tf, token_steps).
resource "octopusdeploy_process_step" "verify_revert" {
  for_each = local.cluster_deployables

  process_id     = octopusdeploy_process.deployable[each.key].id
  name           = "Verify revert"
  type           = "Octopus.Script"
  condition      = "Failure"
  worker_pool_id = local.cluster_worker_pool_id
  container      = local.container

  execution_properties = merge(local.script_properties, {
    "Octopus.Action.Script.ScriptBody" = file("${path.module}/../scripts/verify-revert.ps1")
  })
}

# Started together with "Update deployable": measures the app's availability while Argo CD rolls it out, and fails
# the deployment on downtime (scripts/measure-availability.ps1, CAP-044).
resource "octopusdeploy_process_step" "measure" {
  for_each = local.cluster_deployables

  process_id     = octopusdeploy_process.deployable[each.key].id
  name           = "Measure availability"
  type           = "Octopus.Script"
  start_trigger  = "StartWithPrevious"
  worker_pool_id = local.cluster_worker_pool_id
  container      = local.container

  execution_properties = merge(local.script_properties, {
    "Octopus.Action.Script.ScriptBody" = file("${path.module}/../scripts/measure-availability.ps1")
  })
}

resource "octopusdeploy_process_step" "verify" {
  for_each = local.cluster_deployables

  process_id     = octopusdeploy_process.deployable[each.key].id
  name           = "Verify deployable"
  type           = "Octopus.Script"
  worker_pool_id = local.cluster_worker_pool_id
  container      = local.container

  execution_properties = merge(local.script_properties, {
    "Octopus.Action.Script.ScriptBody" = file("${path.module}/../scripts/verify-environment.ps1")
  })
}

# Acceptance tests, in the environments with "acceptanceTests": true. "Prepare test runner" starts with "Migrate
# database" and pulls the test image meanwhile; the tests follow the verification, so a failed test leaves the version
# running but fails the deployment, which blocks its promotion.
resource "octopusdeploy_process_step" "prepare_tests" {
  for_each = local.tested_deployables

  process_id     = octopusdeploy_process.deployable[each.key].id
  name           = "Prepare test runner"
  type           = "Octopus.Script"
  start_trigger  = "StartWithPrevious"
  environments   = [for name in local.test_environments : octopusdeploy_environment.this[name].id]
  worker_pool_id = local.cluster_worker_pool_id
  container      = local.test_container

  execution_properties = merge(local.script_properties, {
    "Octopus.Action.Script.ScriptBody" = file("${path.module}/../scripts/prepare-test-runner.ps1")
  })
}

resource "octopusdeploy_process_step" "open_test_database" {
  for_each = local.tested_deployables

  process_id     = octopusdeploy_process.deployable[each.key].id
  name           = "Open test database"
  type           = "Octopus.Script"
  environments   = [for name in local.test_environments : octopusdeploy_environment.this[name].id]
  worker_pool_id = local.cluster_worker_pool_id
  container      = local.container

  execution_properties = merge(local.script_properties, {
    "Octopus.Action.Script.ScriptBody" = file("${path.module}/../scripts/open-test-database.ps1")
  })
}

resource "octopusdeploy_process_step" "acceptance_tests" {
  for_each = local.tested_deployables

  process_id     = octopusdeploy_process.deployable[each.key].id
  name           = "Acceptance tests"
  type           = "Octopus.Script"
  environments   = [for name in local.test_environments : octopusdeploy_environment.this[name].id]
  worker_pool_id = local.cluster_worker_pool_id
  container      = local.test_container

  packages = {
    tests = {
      package_id           = each.value.acceptanceTestsPackage
      feed_id              = local.built_in_feed_id
      acquisition_location = "Server"
      properties = {
        Extract       = "True"
        Purpose       = ""
        SelectionMode = "immediate"
      }
    }
  }

  execution_properties = merge(local.script_properties, {
    "Octopus.Action.Script.ScriptBody" = file("${path.module}/../scripts/run-acceptance-tests.ps1")
  })
}

resource "octopusdeploy_process_steps_order" "deployable" {
  for_each = local.deployables

  process_id = octopusdeploy_process.deployable[each.key].id
  steps = contains(keys(local.site_deployables), each.key) ? [
    octopusdeploy_process_step.sign_off[each.key].id,
    octopusdeploy_process_step.upload_site[each.key].id,
    octopusdeploy_process_step.verify_site[each.key].id,
    ] : concat(
    [octopusdeploy_process_step.sign_off[each.key].id],
    contains(keys(local.migrated_deployables), each.key) ? [octopusdeploy_process_step.restore_point[each.key].id] : [],
    contains(keys(local.migrated_deployables), each.key) ? [octopusdeploy_process_step.migrate[each.key].id] : [],
    contains(keys(local.tested_deployables), each.key) ? [octopusdeploy_process_step.prepare_tests[each.key].id] : [],
    contains(keys(local.seeded_deployables), each.key) ? [octopusdeploy_process_step.seed_demo_employees[each.key].id] : [],
    [
      octopusdeploy_process_step.update[each.key].id,
      octopusdeploy_process_step.measure[each.key].id,
    ],
    contains(keys(local.static_deployables), each.key) ? [octopusdeploy_process_step.content[each.key].id] : [],
    [
      octopusdeploy_process_step.verify[each.key].id,
      octopusdeploy_process_step.revert_pin[each.key].id,
      octopusdeploy_process_step.verify_revert[each.key].id,
    ],
    contains(keys(local.tested_deployables), each.key) ? [
      octopusdeploy_process_step.open_test_database[each.key].id,
      octopusdeploy_process_step.acceptance_tests[each.key].id,
    ] : [],
  )
}

# ---------------------------------------------------------------- deployment freezes

# One freeze per project and entry of system.json "freezes"; while it runs, Octopus refuses deployments to its
# environments (prod tier unless the entry lists others).
resource "octopusdeploy_project_deployment_freeze" "this" {
  for_each = {
    for pair in setproduct(keys(local.project_ids), range(length(local.freezes))) :
    "${pair[0]}-${local.freezes[pair[1]].name}" => { project = pair[0], freeze = local.freezes[pair[1]] }
  }

  owner_id        = local.project_ids[each.value.project]
  name            = each.value.freeze.name
  start           = each.value.freeze.start
  end             = each.value.freeze.end
  environment_ids = [for name in try(each.value.freeze.environments, local.prod_environments) : octopusdeploy_environment.this[name].id]
}
