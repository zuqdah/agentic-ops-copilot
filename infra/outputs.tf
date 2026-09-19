output "project_endpoint" {
  description = "Foundry project endpoint used by the agents-as-code step and by clients."
  value       = module.foundry.project_endpoint
}

output "deployment_name" {
  description = "Model deployment the agent uses."
  value       = module.foundry.deployment_name
}

output "tool_server_url" {
  description = "Public URL of the MCP tool server."
  value       = module.tool_server.url
}

output "mcp_endpoint" {
  description = "MCP endpoint registered with the Foundry toolbox."
  value       = "${module.tool_server.url}/mcp"
}

output "key_vault_name" {
  description = "Key Vault holding the tool server's shared key."
  value       = module.keyvault.name
}

output "lab_key_secret_name" {
  description = "Name of the shared-key secret in Key Vault."
  value       = azurerm_key_vault_secret.lab_key.name
}

output "mcp_connection_name" {
  description = "Project connection the agent references for tool server auth."
  value       = azurerm_cognitive_account_connection_custom_keys.tool_server.name
}
