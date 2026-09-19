variable "name" {
  description = "Globally unique name suffix; resources are named aif-<name> and proj-<name>."
  type        = string
}

variable "location" {
  description = "Azure region. Must support Foundry agents and the chosen model."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group to deploy into."
  type        = string
}

variable "project_display_name" {
  description = "Display name of the Foundry project."
  type        = string
  default     = "Agentic ops copilot"
}

variable "project_description" {
  description = "Description of the Foundry project."
  type        = string
  default     = "Agents that inspect and repair Azure infrastructure through an MCP tool server."
}

variable "deployment_name" {
  description = "Model deployment name that agents reference."
  type        = string
  default     = "chat"
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

variable "deployment_sku" {
  description = "Deployment type. Check `az cognitiveservices usage list` for quota before changing it."
  type        = string
  default     = "DataZoneStandard"
}

variable "capacity_ktpm" {
  description = "Deployment capacity in thousands of tokens per minute."
  type        = number
  default     = 5

  validation {
    condition     = var.capacity_ktpm >= 1 && var.capacity_ktpm <= 50
    error_message = "Keep lab capacity between 1K and 50K tokens per minute."
  }
}

variable "public_network_access_enabled" {
  description = "Allow access over the public endpoint. Disable when private endpoints are added."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
