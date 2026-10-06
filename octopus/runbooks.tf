# Operations runbooks of <slug>-system (runtime aks-argocd):
#   Restore test           weekly, first environment: the latest backup restored into a temporary database (CAP-060)
#   Rotate SQL passwords   monthly, every environment: new passwords for the app's login and sa (CAP-056)
#   Health report          hourly, every environment: one line per deployable, red when one does not answer (CAP-076)
# A schedule runs the runbook's published snapshot; the system workflow publishes one after every apply.
# The instance's task cap is shared by every system on it, so each system's schedule starts at its own time: an offset
# of 0 to 239 minutes derived from the slug (the same on every apply), after 09:00 UTC, when the nightly backups exist.

locals {
  schedule_offset = parseint(substr(md5(local.slug), 0, 6), 16) % 240
  runbooks = {
    restore_test = {
      name         = "Restore test"
      description  = "Restores the latest backup of the database into a temporary database, counts its tables and drops it (scripts/test-restore.ps1)."
      script       = "test-restore.ps1"
      environments = [local.first_environment]
      cron         = "0 ${local.schedule_offset % 60} ${9 + floor(local.schedule_offset / 60)} * * Sun"
      schedule     = "Weekly restore test"
    }
    rotate_sql_passwords = {
      name         = "Rotate SQL passwords"
      description  = "Gives the environment's SQL Server new passwords for the app's login and sa, restarts the apps with theirs and checks they answer (scripts/rotate-sql-passwords.ps1)."
      script       = "rotate-sql-passwords.ps1"
      environments = keys(local.environments)
      # The first of the month, an hour after the restore test's time of day.
      cron     = "0 ${local.schedule_offset % 60} ${10 + floor(local.schedule_offset / 60)} 1 * *"
      schedule = "Monthly SQL password rotation"
    }
    health_report = {
      name         = "Health report"
      description  = "Asks every deployable of the environment at its public address whether it answers, one line each with time and version; fails when one is not healthy (scripts/report-health.ps1)."
      script       = "report-health.ps1"
      environments = keys(local.environments)
      cron         = "0 ${local.schedule_offset % 60} * * * *"
      schedule     = "Hourly health report"
    }
  }
}

resource "octopusdeploy_runbook" "this" {
  for_each = local.runbooks

  project_id                  = octopusdeploy_project.system.id
  name                        = each.value.name
  description                 = each.value.description
  environment_scope           = "Specified"
  environments                = [for name in each.value.environments : octopusdeploy_environment.this[name].id]
  default_guided_failure_mode = "Off"
  force_package_download      = false
}

resource "octopusdeploy_process" "runbook" {
  for_each = local.runbooks

  project_id = octopusdeploy_project.system.id
  runbook_id = octopusdeploy_runbook.this[each.key].id
}

resource "octopusdeploy_process_step" "runbook" {
  for_each = local.runbooks

  process_id     = octopusdeploy_process.runbook[each.key].id
  name           = each.value.name
  type           = "Octopus.Script"
  worker_pool_id = local.cluster_worker_pool_id
  container      = local.container

  execution_properties = merge(local.script_properties, {
    "Octopus.Action.Script.ScriptBody" = file("${path.module}/../scripts/${each.value.script}")
  })
}

resource "octopusdeploy_process_steps_order" "runbook" {
  for_each = local.runbooks

  process_id = octopusdeploy_process.runbook[each.key].id
  steps      = [octopusdeploy_process_step.runbook[each.key].id]
}

resource "octopusdeploy_project_scheduled_trigger" "runbook" {
  for_each = local.runbooks

  project_id  = octopusdeploy_project.system.id
  space_id    = local.system.octopus.spaceId
  name        = each.value.schedule
  description = "${each.value.name}: ${each.value.description}"
  timezone    = "UTC"
  # A dormant cluster (cluster.dormant in system.json) runs nothing: the schedule pauses with it.
  is_disabled = try(local.system.cluster.dormant, false)

  cron_expression_schedule {
    cron_expression = each.value.cron
  }

  run_runbook_action {
    runbook_id             = octopusdeploy_runbook.this[each.key].id
    target_environment_ids = [for name in each.value.environments : octopusdeploy_environment.this[name].id]
  }
}
