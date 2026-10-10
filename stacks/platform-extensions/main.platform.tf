module "platform" {
  source   = "../../modules/platform-lookup"
  location = var.location
  providers = {
    azurerm.connectivity = azurerm.connectivity
    azurerm.management   = azurerm.management
  }
}

module "address_plan" {
  source      = "../../modules/address-plan"
  for_each    = var.environments
  environment = each.key
  countries   = each.value.countries
}

locals {
  firewall_ip = module.platform.firewall_private_ip
  hub_vnet    = module.platform.hub_virtual_network

  management = {
    snet_runners    = cidrsubnet(var.management_address_space, 4, 0) # /26 ACI runners (delegated)
    snet_jump       = cidrsubnet(var.management_address_space, 5, 2) # /27 jump hosts
    snet_pe         = cidrsubnet(var.management_address_space, 4, 2) # /26 private endpoints of the management services (runner ACR)
    snet_aks_api_pe = cidrsubnet(var.management_address_space, 2, 1) # /24 private endpoints to every cluster's API server
  }
  client = {
    snet_clients = cidrsubnet(var.client_address_space, 2, 0) # /24 internal test clients
    snet_loadgen = cidrsubnet(var.client_address_space, 2, 1) # /24 load generators
  }
}
