variable "resource_group_name" {
  description = "Existing resource group created by bootstrap/. Everything here deploys into it."
  type        = string
  default     = "rg-agentops-lab"
}

variable "location" {
  description = "Region override. Defaults to the resource group's region."
  type        = string
  default     = null
}

variable "tool_server_image" {
  description = "Container image for the MCP tool server."
  type        = string
  default     = "ghcr.io/zuqdah/agentops-mcp:latest"
}

variable "restart_role_definition_id" {
  description = "Role definition ID of the restart-only custom role created by bootstrap."
  type        = string
}

variable "model_name" {
  description = "Model to deploy."
  type        = string
  default     = "gpt-5.4-mini"
}

variable "model_version" {
  description = "Model version to deploy."
  type        = string
  default     = "2026-03-17"
}

variable "model_deployment_sku" {
  description = "Deployment type. Check `az cognitiveservices usage list` for quota before changing it."
  type        = string
  default     = "DataZoneStandard"
}

variable "model_capacity_ktpm" {
  description = "Deployment capacity in thousands of tokens per minute."
  type        = number
  default     = 5
}

variable "log_daily_quota_gb" {
  description = "Daily Log Analytics ingestion cap in GB."
  type        = number
  default     = 0.1
}

variable "tags" {
  description = "Additional tags applied to every resource."
  type        = map(string)
  default     = {}
}

variable "mcp_connection_name" {
  description = "Name of the project connection that holds the tool server's key."
  type        = string
  default     = "tool-server"
}
