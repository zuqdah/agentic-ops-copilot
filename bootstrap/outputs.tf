output "azure_client_id" {
  description = "Client ID of the GitHub Actions identity (AZURE_CLIENT_ID)."
  value       = azuread_application.deployer.client_id
}

output "azure_tenant_id" {
  description = "Entra ID tenant (AZURE_TENANT_ID)."
  value       = data.azurerm_client_config.current.tenant_id
}

output "azure_subscription_id" {
  description = "Subscription (AZURE_SUBSCRIPTION_ID)."
  value       = data.azurerm_client_config.current.subscription_id
}

output "tfstate_resource_group" {
  description = "Resource group holding remote state (TFSTATE_RESOURCE_GROUP)."
  value       = azurerm_resource_group.tfstate.name
}

output "tfstate_storage_account" {
  description = "Storage account holding remote state (TFSTATE_STORAGE_ACCOUNT)."
  value       = azurerm_storage_account.tfstate.name
}

output "tfstate_container" {
  description = "Blob container holding remote state (TFSTATE_CONTAINER)."
  value       = azurerm_storage_container.tfstate.name
}

output "lab_resource_group" {
  description = "Resource group the pipeline deploys into (LAB_RESOURCE_GROUP)."
  value       = azurerm_resource_group.lab.name
}

output "restart_role_definition_id" {
  description = "Restart-only role the tool server is granted (RESTART_ROLE_DEFINITION_ID)."
  value       = azurerm_role_definition.restart_operator.role_definition_resource_id
}
