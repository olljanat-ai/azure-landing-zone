module "platform" {
  source       = "../../modules/platform-lookup"
  location     = var.location
  network_mode = var.network_mode
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
  # firewall: the hub Azure Firewall (design); labfw: labfw in the hub instead (main.labfw.tf); both route the
  # management and client VNets' 0.0.0.0/0 to it. sandbox: neither.
  azure_firewall = module.platform.firewall_enabled
  labfw          = var.network_mode == "labfw"
  routed         = local.azure_firewall || local.labfw
  firewall_ip    = local.labfw ? module.labfw[0].private_ip : module.platform.firewall_private_ip
  # The spokes' DNS server: the Firewall DNS proxy, labfw's with labfw.spoke_dns_proxy, otherwise Azure DNS with
  # the hub private link zones linked to the spoke VNets
  dns_server        = local.labfw ? (var.labfw.spoke_dns_proxy ? local.firewall_ip : null) : module.platform.dns_server_ip
  spoke_dns_servers = local.dns_server == null ? [] : [local.dns_server]
  hub_vnet          = module.platform.hub_virtual_network

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
