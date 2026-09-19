variable "location" {
  description = "Region for the state account and the lab resource group."
  type        = string
  default     = "eastus2"
}

variable "github_repository" {
  description = "owner/name of the repository whose workflows may deploy."
  type        = string
  default     = "zuqdah/agentic-ops-copilot"
}

variable "github_repository_owner_id" {
  description = "Numeric ID of the repository owner: gh api repos/<owner>/<repo> --jq .owner.id"
  type        = number
}

variable "github_repository_id" {
  description = "Numeric ID of the repository: gh api repos/<owner>/<repo> --jq .id"
  type        = number
}

variable "github_environment" {
  description = "GitHub environment that deploy and destroy jobs run in."
  type        = string
  default     = "lab"
}

variable "purge_actions" {
  description = "Subscription-scoped actions needed to purge soft-deleted lab resources on teardown."
  type        = list(string)
  default = [
    "Microsoft.KeyVault/deletedVaults/read",
    "Microsoft.KeyVault/locations/deletedVaults/read",
    "Microsoft.KeyVault/locations/deletedVaults/purge/action",
    "Microsoft.KeyVault/locations/operationResults/read",
    "Microsoft.CognitiveServices/deletedAccounts/read",
    "Microsoft.CognitiveServices/locations/resourceGroups/deletedAccounts/read",
    "Microsoft.CognitiveServices/locations/resourceGroups/deletedAccounts/delete",
  ]
}
