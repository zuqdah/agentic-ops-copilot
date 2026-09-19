terraform {
  required_version = ">= 1.9"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.6"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.9"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
  }

  # Bootstrap runs once, locally, as a subscription Owner. Its state stays
  # local (and out of git); it holds no secrets, only resource IDs.
}

provider "azurerm" {
  resource_providers_to_register = [
    "Microsoft.AlertsManagement",
    "Microsoft.App",
    "Microsoft.CognitiveServices",
    "Microsoft.KeyVault",
    "Microsoft.ManagedIdentity",
    "Microsoft.OperationalInsights",
    "Microsoft.Storage",
    # Azure returns this namespace in lowercase and the provider matches
    # case-sensitively; capitalized, it is silently skipped.
    "microsoft.insights",
  ]

  storage_use_azuread = true

  features {}
}

provider "azuread" {}
