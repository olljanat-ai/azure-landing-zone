terraform {
  required_version = "~> 1.12"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.0"
    }
  }
  backend "azurerm" {}
}

# Default provider: sub-mgmt (management VNet, runners, jump host, deployment identities)
provider "azurerm" {
  resource_provider_registrations = "none"
  subscription_id                 = var.subscription_ids["management"]
  storage_use_azuread             = true
  features {}
}

provider "azurerm" {
  alias                           = "management"
  resource_provider_registrations = "none"
  subscription_id                 = var.subscription_ids["management"]
  features {}
}

# sub-hub (hub peerings, client VNet, Firewall rules)
provider "azurerm" {
  alias                           = "connectivity"
  resource_provider_registrations = "none"
  subscription_id                 = var.subscription_ids["connectivity"]
  features {}
}

provider "azapi" {
  subscription_id = var.subscription_ids["management"]
}
