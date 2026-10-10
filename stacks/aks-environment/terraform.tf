terraform {
  required_version = "~> 1.12"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
  backend "azurerm" {}
}

# Default provider: the environment subscription (sub-aks-<env>)
provider "azurerm" {
  resource_provider_registrations = "none"
  subscription_id                 = var.subscription_id
  storage_use_azuread             = true
  features {
    key_vault {
      purge_soft_delete_on_destroy               = false
      purge_soft_deleted_keys_on_destroy         = false
      purge_soft_deleted_certificates_on_destroy = false
      recover_soft_deleted_key_vaults            = true
    }
  }
}

provider "azurerm" {
  alias                           = "connectivity"
  resource_provider_registrations = "none"
  subscription_id                 = var.platform_subscription_ids["connectivity"]
  features {}
}

provider "azurerm" {
  alias                           = "management"
  resource_provider_registrations = "none"
  subscription_id                 = var.platform_subscription_ids["management"]
  features {}
}

provider "azapi" {
  subscription_id = var.subscription_id
}
