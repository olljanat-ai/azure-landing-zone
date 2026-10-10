terraform {
  required_version = "~> 1.12"
  required_providers {
    azurerm = {
      source                = "hashicorp/azurerm"
      version               = "~> 4.0"
      configuration_aliases = [azurerm.connectivity, azurerm.management]
    }
  }
}
