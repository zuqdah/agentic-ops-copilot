data "azurerm_client_config" "current" {}

# Created by bootstrap/ and never destroyed here, so the pipeline's
# permissions and the budget survive every teardown.
data "azurerm_resource_group" "lab" {
  name = var.resource_group_name
}

resource "random_string" "suffix" {
  length  = 5
  lower   = true
  upper   = false
  numeric = true
  special = false
}

# The shared key Foundry presents to the tool server. Generated here, stored
# in Key Vault, and never written to a workflow log.
resource "random_password" "lab_key" {
  length  = 48
  special = false
}

locals {
  name     = "agentops-${random_string.suffix.result}"
  location = coalesce(var.location, data.azurerm_resource_group.lab.location)

  tags = merge(var.tags, {
    workload   = "agentic-ops-copilot"
    managed-by = "terraform"
    repo       = "github.com/zuqdah/agentic-ops-copilot"
  })
}

# ---------------------------------------------------------------------------
# Shared building blocks, reused from the landing zone lab at a pinned tag
# ---------------------------------------------------------------------------

module "observability" {
  # Pinned to a commit, not a tag: a tag can be moved to different code.
  # cf3c8dc is tag v1.1.0 of the landing zone lab.
  source = "git::https://github.com/zuqdah/azure-agent-landing-zone.git//modules/observability?ref=cf3c8dc50ab7eebf4ace424e40f19077081fd618"

  name                = local.name
  location            = local.location
  resource_group_name = data.azurerm_resource_group.lab.name
  daily_quota_gb      = var.log_daily_quota_gb
  tags                = local.tags
}

module "keyvault" {
  # 335bc3b is tag v1.0.0 of the landing zone lab.
  source = "git::https://github.com/zuqdah/azure-agent-landing-zone.git//modules/keyvault?ref=335bc3bb3b64b633c028b6df8d21599a294e8f6c"

  name                = replace(local.name, "-", "")
  location            = local.location
  resource_group_name = data.azurerm_resource_group.lab.name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  tags                = local.tags
}

# ---------------------------------------------------------------------------
# Foundry project and model
# ---------------------------------------------------------------------------

module "foundry" {
  source = "../modules/foundry"

  name                = local.name
  location            = local.location
  resource_group_name = data.azurerm_resource_group.lab.name
  model_name          = var.model_name
  model_version       = var.model_version
  deployment_sku      = var.model_deployment_sku
  capacity_ktpm       = var.model_capacity_ktpm
  tags                = local.tags
}

# The pipeline creates agents and toolboxes in the project, which is a
# data-plane operation and needs its own role.
resource "azurerm_role_assignment" "deployer_foundry" {
  scope                = module.foundry.account_id
  role_definition_name = "Foundry Project Manager"
  principal_id         = data.azurerm_client_config.current.object_id
}

# ---------------------------------------------------------------------------
# Tool server identity: read the estate, restart one app, nothing else
# ---------------------------------------------------------------------------

resource "azurerm_user_assigned_identity" "tools" {
  name                = "id-${local.name}-tools"
  location            = local.location
  resource_group_name = data.azurerm_resource_group.lab.name
  tags                = local.tags
}

resource "azurerm_role_assignment" "tools_reader" {
  scope                = data.azurerm_resource_group.lab.id
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.tools.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "tools_logs" {
  scope                = module.observability.log_analytics_workspace_id
  role_definition_name = "Log Analytics Reader"
  principal_id         = azurerm_user_assigned_identity.tools.principal_id
  principal_type       = "ServicePrincipal"
}

# The only write the agent can perform. The role is defined in bootstrap and
# carries exactly one action: restarting a container app revision.
resource "azurerm_role_assignment" "tools_restart" {
  scope              = data.azurerm_resource_group.lab.id
  role_definition_id = var.restart_role_definition_id
  principal_id       = azurerm_user_assigned_identity.tools.principal_id
  principal_type     = "ServicePrincipal"
}

# ---------------------------------------------------------------------------
# Secret plumbing
# ---------------------------------------------------------------------------

resource "azurerm_role_assignment" "deployer_kv_secrets_officer" {
  scope                = module.keyvault.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_role_assignment" "tools_kv_secrets_user" {
  scope                = module.keyvault.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.tools.principal_id
  principal_type       = "ServicePrincipal"
}

# Role assignments are eventually consistent; without this pause the first
# secret write or the app's first Key Vault read can fail with a 403.
resource "time_sleep" "rbac_propagation" {
  create_duration = "60s"

  depends_on = [
    azurerm_role_assignment.deployer_kv_secrets_officer,
    azurerm_role_assignment.tools_kv_secrets_user,
  ]
}

resource "time_offset" "secret_expiry" {
  offset_days = 30
}

resource "azurerm_key_vault_secret" "lab_key" {
  name            = "tool-server-key"
  value           = random_password.lab_key.result
  key_vault_id    = module.keyvault.id
  content_type    = "Shared key presented by Foundry to the tool server"
  expiration_date = time_offset.secret_expiry.rfc3339

  depends_on = [time_sleep.rbac_propagation]
}

# How Foundry authenticates to the tool server: a project connection holding
# the shared key as a request header. Agents reference the connection by
# name and never see the value.
resource "azurerm_cognitive_account_connection_custom_keys" "tool_server" {
  name                 = var.mcp_connection_name
  cognitive_account_id = module.foundry.account_id
  category             = "CustomKeys"
  target               = "${module.tool_server.url}/mcp"

  custom_keys = {
    "x-lab-key" = random_password.lab_key.result
  }
}

# ---------------------------------------------------------------------------
# MCP tool server
# ---------------------------------------------------------------------------

module "tool_server" {
  source = "../modules/tool-server"

  name                       = local.name
  location                   = local.location
  resource_group_name        = data.azurerm_resource_group.lab.name
  log_analytics_workspace_id = module.observability.log_analytics_workspace_id
  identity_id                = azurerm_user_assigned_identity.tools.id
  image                      = var.tool_server_image
  lab_key_secret_id          = azurerm_key_vault_secret.lab_key.versionless_id
  tags                       = local.tags

  env = {
    AZURE_SUBSCRIPTION_ID      = data.azurerm_client_config.current.subscription_id
    LAB_RESOURCE_GROUP         = data.azurerm_resource_group.lab.name
    LOG_ANALYTICS_WORKSPACE_ID = module.observability.log_analytics_workspace_customer_id
    # Binds DefaultAzureCredential to the user-assigned identity.
    AZURE_CLIENT_ID = azurerm_user_assigned_identity.tools.client_id
  }
}
