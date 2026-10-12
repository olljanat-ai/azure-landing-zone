terraform {
  required_version = "~> 1.12"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
  backend "azurerm" {}
}

# The environment subscription (sub-aks-<env>)
provider "azurerm" {
  resource_provider_registrations = "none"
  subscription_id                 = var.subscription_id
  storage_use_azuread             = true
  features {}
}
