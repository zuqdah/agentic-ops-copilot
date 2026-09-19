data "azurerm_client_config" "current" {}

data "azurerm_subscription" "current" {}

locals {
  tags = {
    workload   = "agentic-ops-copilot"
    managed-by = "terraform"
    layer      = "bootstrap"
  }

  # GitHub issues OIDC subjects keyed on immutable owner and repository IDs.
  github_owner   = split("/", var.github_repository)[0]
  github_repo    = split("/", var.github_repository)[1]
  subject_prefix = "repo:${local.github_owner}@${var.github_repository_owner_id}/${local.github_repo}@${var.github_repository_id}"

  # Built-in roles the pipeline may grant inside the lab resource group.
  delegable_roles = [
    "Foundry Project Manager",
    "Key Vault Secrets Officer",
    "Key Vault Secrets User",
    "Log Analytics Reader",
    "Reader",
  ]
}

# ---------------------------------------------------------------------------
# Resource groups
# ---------------------------------------------------------------------------

resource "azurerm_resource_group" "tfstate" {
  name     = "rg-agentops-tfstate"
  location = var.location
  tags     = local.tags
}

resource "azurerm_resource_group" "lab" {
  name     = "rg-agentops-lab"
  location = var.location
  tags     = local.tags
}

# ---------------------------------------------------------------------------
# Remote state
# ---------------------------------------------------------------------------

resource "random_string" "state" {
  length  = 6
  lower   = true
  upper   = false
  numeric = true
  special = false
}

resource "azurerm_storage_account" "tfstate" {
  #checkov:skip=CKV_AZURE_59:GitHub-hosted runners reach state over the public endpoint from unpredictable IPs. Access requires an Entra ID identity with a data role; keys and SAS are disabled.
  #checkov:skip=CKV2_AZURE_33:Private endpoint omitted; see CKV_AZURE_59.
  #checkov:skip=CKV_AZURE_206:LRS is deliberate for lab state; versioning protects against bad writes.
  #checkov:skip=CKV_AZURE_33:No queues are used in this account.
  #checkov:skip=CKV2_AZURE_1:Microsoft-managed encryption keys are appropriate for lab state.
  name                     = "stagentops${random_string.state.result}"
  resource_group_name      = azurerm_resource_group.tfstate.name
  location                 = azurerm_resource_group.tfstate.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  min_tls_version          = "TLS1_2"

  shared_access_key_enabled       = false
  default_to_oauth_authentication = true
  allow_nested_items_to_be_public = false

  blob_properties {
    versioning_enabled = true

    delete_retention_policy {
      days = 7
    }

    container_delete_retention_policy {
      days = 7
    }
  }

  tags = local.tags
}

resource "azurerm_storage_container" "tfstate" {
  #checkov:skip=CKV2_AZURE_21:Blob read logging would need a persistent workspace outside the nightly teardown.
  name                  = "tfstate"
  storage_account_id    = azurerm_storage_account.tfstate.id
  container_access_type = "private"
}

resource "azurerm_role_assignment" "operator_state" {
  scope                = azurerm_storage_container.tfstate.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
}

# ---------------------------------------------------------------------------
# GitHub Actions identity (OIDC, no secrets)
# ---------------------------------------------------------------------------

resource "azuread_application" "deployer" {
  display_name = "gh-agentops-deployer"
  owners       = [data.azurerm_client_config.current.object_id]
}

resource "azuread_service_principal" "deployer" {
  client_id = azuread_application.deployer.client_id
  owners    = [data.azurerm_client_config.current.object_id]
}

resource "azuread_application_federated_identity_credential" "environment" {
  #checkov:skip=CKV_AZURE_249:False positive. The check's repo pattern predates GitHub's immutable subject format (owner@id/repo@id) and rejects the "@". The subject names one exact repository.
  application_id = azuread_application.deployer.id
  display_name   = "github-${var.github_environment}-environment"
  description    = "Deploy and destroy jobs running in the ${var.github_environment} environment."
  audiences      = ["api://AzureADTokenExchange"]
  issuer         = "https://token.actions.githubusercontent.com"
  subject        = "${local.subject_prefix}:environment:${var.github_environment}"
}

resource "azuread_application_federated_identity_credential" "pull_request" {
  #checkov:skip=CKV_AZURE_249:False positive; see the environment credential above.
  application_id = azuread_application.deployer.id
  display_name   = "github-pull-request"
  description    = "Plan jobs on pull requests."
  audiences      = ["api://AzureADTokenExchange"]
  issuer         = "https://token.actions.githubusercontent.com"
  subject        = "${local.subject_prefix}:pull_request"
}

# ---------------------------------------------------------------------------
# The one write the agent can ever perform
# ---------------------------------------------------------------------------

# Restarting a revision is the agent's only mutating action. This role carries
# that action and the reads it needs, and nothing else: it cannot change the
# app, its image, its scale, or its secrets.
resource "azurerm_role_definition" "restart_operator" {
  name        = "Agent ops container app restart"
  scope       = data.azurerm_subscription.current.id
  description = "Read container apps and restart a revision. No other write actions."

  permissions {
    actions = [
      "Microsoft.App/containerApps/read",
      "Microsoft.App/containerApps/revisions/read",
      "Microsoft.App/containerApps/revisions/restart/action",
    ]
  }

  assignable_scopes = [data.azurerm_subscription.current.id]
}

# ---------------------------------------------------------------------------
# Pipeline permissions
# ---------------------------------------------------------------------------

resource "azurerm_role_assignment" "deployer_contributor" {
  scope                = azurerm_resource_group.lab.id
  role_definition_name = "Contributor"
  principal_id         = azuread_service_principal.deployer.object_id
  principal_type       = "ServicePrincipal"
}

data "azurerm_role_definition" "delegable" {
  for_each = toset(local.delegable_roles)
  name     = each.value
  scope    = data.azurerm_subscription.current.id
}

# The pipeline grants the tool server its roles, so it needs to create role
# assignments. This condition limits it to the roles listed above plus the
# restart role, and only inside the lab resource group.
resource "azurerm_role_assignment" "deployer_rbac_admin" {
  scope                = azurerm_resource_group.lab.id
  role_definition_name = "Role Based Access Control Administrator"
  principal_id         = azuread_service_principal.deployer.object_id
  principal_type       = "ServicePrincipal"
  condition_version    = "2.0"
  condition = templatefile("${path.module}/rbac-condition.tftpl", {
    role_ids = join(", ", concat(
      [for r in data.azurerm_role_definition.delegable : basename(r.id)],
      [basename(azurerm_role_definition.restart_operator.role_definition_resource_id)],
    ))
  })
}

resource "azurerm_role_assignment" "deployer_state" {
  scope                = azurerm_storage_container.tfstate.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azuread_service_principal.deployer.object_id
  principal_type       = "ServicePrincipal"
}

# Purging soft-deleted resources is subscription-scoped, so teardown can be
# complete without granting the pipeline anything broader.
resource "azurerm_role_definition" "purger" {
  name        = "Agent ops soft-delete purger"
  scope       = data.azurerm_subscription.current.id
  description = "Read and purge soft-deleted Key Vaults and Foundry accounts."

  permissions {
    actions = var.purge_actions
  }

  assignable_scopes = [data.azurerm_subscription.current.id]
}

resource "azurerm_role_assignment" "deployer_purger" {
  scope              = data.azurerm_subscription.current.id
  role_definition_id = azurerm_role_definition.purger.role_definition_resource_id
  principal_id       = azuread_service_principal.deployer.object_id
  principal_type     = "ServicePrincipal"
}
