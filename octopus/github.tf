# The GitHub identity of the script steps that read and commit to this repository (runtime aks-argocd): the system's own
# GitHub App, or the stored token of a system that has no App (variables.tf, GitHub.Token). Everything of the App is in
# this file. The Argo CD steps commit with the Git credential of main.tf either way: a Git credential is a stored
# password, which a GitHub App cannot give.
#
# system.json github.app (id, slug, clientId, installationId; no secret) says that the system has an App. With it, a
# script step signs a ten-minute JWT with the App's key and gets a one-hour token for this repository only, with the
# permissions it asks for only (scripts/github-token.ps1). Without it, the steps use GitHub.Token, as before the App.

variable "github_app_private_key" {
  description = "Private key (PEM) of the system's own GitHub App, the one system.json names in github.app (repository secret SYSTEM_APP_PRIVATE_KEY). Empty in a system without an App."
  type        = string
  sensitive   = true
  default     = ""
}

locals {
  github_app = try(local.system.github.app, null)

  # The functions that give a step its GitHub token: the text of scripts/github-token.ps1. projects.tf inlines one
  # script per step, and for each step that asks GitHub for a token it joins this text and the step's own script into
  # the step's one script body (join("\n", [local.github_token_functions, file(...)])). The code is in the process
  # Octopus stores, fixed when this configuration is applied: it is no variable, and nothing a step sets when it runs
  # can change what a later step runs. A step that is not joined has no such function.
  github_token_functions = file("${path.module}/../scripts/github-token.ps1")

  # GitHub.AppId, GitHub.AppSlug and GitHub.AppInstallationId exist only in a system with an App; without them the
  # function uses GitHub.Token. They are no secret (system.json shows them) and make no token.
  github_variables = flatten([
    for name, project in octopusdeploy_project.deployable : local.github_app == null ? [] : [
      { key = "${name}-app-id", project = project.id, name = "GitHub.AppId", value = tostring(local.github_app.id) },
      { key = "${name}-app-slug", project = project.id, name = "GitHub.AppSlug", value = tostring(local.github_app.slug) },
      { key = "${name}-app-installation", project = project.id, name = "GitHub.AppInstallationId", value = tostring(local.github_app.installationId) },
    ]
  ])

  # The steps that get the App's key or, in a system without an App, the stored token (variables.tf, GitHub.Token),
  # per deployable project: the ones whose script calls GitHub for this repository
  # ("Revert pin" commits the previous tag; a dashboard's "Write dashboard content" and "Update deployable" commit its
  # content or its site's address; "Verify deployable" of a site reads that record). Each runs a script of this
  # repository and nothing else. No other step has the key: a step that runs code from an application's repository
  # must never be on this list.
  token_steps = {
    for name, project in octopusdeploy_project.deployable : name => concat(
      [for key, step in octopusdeploy_process_step.revert_pin : step.action_id if key == name],
      [for key, step in octopusdeploy_process_step.content : step.action_id if key == name],
      [for key, step in octopusdeploy_process_step.upload_site : step.action_id if key == name],
      [for key, step in octopusdeploy_process_step.verify_site : step.action_id if key == name],
    )
  }
}

resource "octopusdeploy_variable" "github" {
  for_each = { for v in local.github_variables : v.key => v }

  owner_id = each.value.project
  name     = each.value.name
  type     = "String"
  value    = each.value.value
}

# The key of the system's own GitHub App, scoped to the steps of token_steps. A step outside that list has neither
# the key nor the functions of scripts/github-token.ps1 (projects.tf joins them into the script of the steps on the
# list only). The App's ids are not scoped: they are no secret and make no token.
resource "octopusdeploy_variable" "github_app_private_key" {
  for_each = local.github_app == null ? {} : octopusdeploy_project.deployable

  owner_id        = each.value.id
  name            = "GitHub.AppPrivateKey"
  type            = "Sensitive"
  is_sensitive    = true
  sensitive_value = var.github_app_private_key
  description     = "Private key of the system's GitHub App: the script steps that read and commit to the system repository make their token with it. From repository secret SYSTEM_APP_PRIVATE_KEY."

  scope {
    actions = local.token_steps[each.key]
  }

  lifecycle {
    precondition {
      condition     = nonsensitive(var.github_app_private_key != "")
      error_message = "system.json names a GitHub App (github.app) and the repository secret SYSTEM_APP_PRIVATE_KEY is empty: the operator stores the key with set-system-github-app.ps1 of the kit."
    }
    # An empty scope would hand the key to every step of the project.
    precondition {
      condition     = length(local.token_steps[each.key]) > 0
      error_message = "No step of this project is named to receive the GitHub App's key (token_steps)."
    }
  }
}
