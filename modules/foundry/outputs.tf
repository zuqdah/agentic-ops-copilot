output "account_id" {
  description = "Resource ID of the Foundry (AIServices) account."
  value       = azurerm_cognitive_account.this.id
}

output "account_name" {
  description = "Name of the Foundry account."
  value       = azurerm_cognitive_account.this.name
}

output "project_name" {
  description = "Name of the Foundry project."
  value       = azurerm_cognitive_account_project.this.name
}

output "project_endpoint" {
  description = "Project endpoint used by the Foundry SDK and agent clients."
  value       = "https://${azurerm_cognitive_account.this.name}.services.ai.azure.com/api/projects/${azurerm_cognitive_account_project.this.name}"
}

output "project_principal_id" {
  description = "Principal ID of the project's system-assigned identity."
  value       = azurerm_cognitive_account_project.this.identity[0].principal_id
}

output "deployment_name" {
  description = "Model deployment name."
  value       = azurerm_cognitive_deployment.chat.name
}
