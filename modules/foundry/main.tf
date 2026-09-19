resource "azurerm_cognitive_account" "this" {
  #checkov:skip=CKV_AZURE_134:Public endpoint kept for the lab; key auth is disabled, so only Entra ID identities with a role can call it.
  #checkov:skip=CKV2_AZURE_22:Microsoft-managed encryption keys; customer-managed keys need a purge-protected Key Vault, which conflicts with complete nightly teardown.
  #checkov:skip=CKV_AZURE_247:Outbound access is blocked entirely with no FQDN allowlist. The check only passes with a non-empty allowlist.
  name                = "aif-${var.name}"
  location            = var.location
  resource_group_name = var.resource_group_name

  # AIServices is the account kind that hosts Foundry projects and agents.
  kind     = "AIServices"
  sku_name = "S0"

  # Required for Entra ID authentication and for the project endpoint.
  custom_subdomain_name = "aif-${var.name}"

  # Without this, creating a project fails: "Project can only created under
  # AIServices Kind account with allowProjectManagement set to true".
  project_management_enabled = true

  # No API keys: agents and callers authenticate as Entra ID identities.
  local_auth_enabled                 = false
  public_network_access_enabled      = var.public_network_access_enabled
  outbound_network_access_restricted = true

  identity {
    type = "SystemAssigned"
  }

  tags = var.tags
}

# The project is the scope agents, toolboxes, and conversations live in.
resource "azurerm_cognitive_account_project" "this" {
  name                 = "proj-${var.name}"
  cognitive_account_id = azurerm_cognitive_account.this.id
  location             = var.location
  display_name         = var.project_display_name
  description          = var.project_description

  identity {
    type = "SystemAssigned"
  }

  tags = var.tags
}

resource "azurerm_cognitive_deployment" "chat" {
  name                 = var.deployment_name
  cognitive_account_id = azurerm_cognitive_account.this.id

  model {
    format  = "OpenAI"
    name    = var.model_name
    version = var.model_version
  }

  # Capacity is thousands of tokens per minute: a hard throughput ceiling
  # enforced by Azure, independent of anything the agent does.
  sku {
    name     = var.deployment_sku
    capacity = var.capacity_ktpm
  }
}
