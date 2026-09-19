variable "name" {
  description = "Name suffix; resources are named cae-<name> and ca-<name>."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group to deploy into."
  type        = string
}

variable "log_analytics_workspace_id" {
  description = "Workspace that receives container console and system logs."
  type        = string
}

variable "identity_id" {
  description = "Resource ID of the user-assigned identity the server runs as."
  type        = string
}

variable "image" {
  description = "Container image to run."
  type        = string
}

variable "lab_key_secret_id" {
  description = "Versionless Key Vault secret ID holding the shared key callers must present."
  type        = string
}

variable "env" {
  description = "Plain environment variables for the container."
  type        = map(string)
  default     = {}
}

variable "max_replicas" {
  description = "Upper bound on replicas."
  type        = number
  default     = 1
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
