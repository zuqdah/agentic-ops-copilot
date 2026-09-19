output "url" {
  description = "Public HTTPS URL of the tool server."
  value       = "https://${azurerm_container_app.this.ingress[0].fqdn}"
}

output "fqdn" {
  description = "Hostname of the tool server, used for the MCP transport allowlist."
  value       = azurerm_container_app.this.ingress[0].fqdn
}

output "name" {
  description = "Name of the container app."
  value       = azurerm_container_app.this.name
}
