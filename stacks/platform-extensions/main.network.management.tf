# Management VNet in sub-mgmt (OneK8s design pictures 1 and 3): jump hosts and self-hosted CI runners, the only
# network that reaches the Kubernetes API servers – through a private endpoint per cluster in snet-aks-api-pe.
resource "azurerm_resource_group" "management_network" {
  name     = "rg-mgmt-network-${var.location}"
  location = var.location
  tags     = var.tags
}

resource "azurerm_virtual_network" "management" {
  name                = "vnet-mgmt-${var.location}"
  location            = var.location
  resource_group_name = azurerm_resource_group.management_network.name
  address_space       = [var.management_address_space]
  dns_servers         = module.platform.dns_servers # Firewall DNS proxy, or Azure DNS + zone links (sandbox)
  tags                = var.tags
}

resource "azurerm_route_table" "management" {
  count                         = local.firewall ? 1 : 0
  name                          = "rt-mgmt-${var.location}"
  location                      = var.location
  resource_group_name           = azurerm_resource_group.management_network.name
  bgp_route_propagation_enabled = false
  tags                          = var.tags

  route {
    name                   = "default-via-firewall"
    address_prefix         = "0.0.0.0/0"
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = local.firewall_ip
  }
}

resource "azurerm_network_security_group" "management" {
  for_each            = toset(["runners", "jump", "pe", "aks-api-pe"])
  name                = "nsg-mgmt-${each.key}-${var.location}"
  location            = var.location
  resource_group_name = azurerm_resource_group.management_network.name
  tags                = var.tags
}

resource "azurerm_network_security_rule" "management_jump_bastion" {
  name                        = "allow-bastion-ssh"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "22"
  source_address_prefix       = var.hub_bastion_subnet_prefix
  destination_address_prefix  = local.management.snet_jump
  resource_group_name         = azurerm_resource_group.management_network.name
  network_security_group_name = azurerm_network_security_group.management["jump"].name
}

resource "azurerm_network_security_rule" "management_api_pe" {
  name                        = "allow-runners-and-jump-to-api-servers"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefixes     = [local.management.snet_runners, local.management.snet_jump]
  destination_address_prefix  = local.management.snet_aks_api_pe
  resource_group_name         = azurerm_resource_group.management_network.name
  network_security_group_name = azurerm_network_security_group.management["aks-api-pe"].name
}

resource "azurerm_network_security_rule" "management_api_pe_deny" {
  name                        = "deny-other-to-api-servers"
  priority                    = 4000
  direction                   = "Inbound"
  access                      = "Deny"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "*"
  destination_address_prefix  = local.management.snet_aks_api_pe
  resource_group_name         = azurerm_resource_group.management_network.name
  network_security_group_name = azurerm_network_security_group.management["aks-api-pe"].name
}

resource "azurerm_subnet" "management_runners" {
  name                            = "snet-runners"
  resource_group_name             = azurerm_resource_group.management_network.name
  virtual_network_name            = azurerm_virtual_network.management.name
  address_prefixes                = [local.management.snet_runners]
  default_outbound_access_enabled = false
  delegation {
    name = "aci"
    service_delegation {
      name    = "Microsoft.ContainerInstance/containerGroups"
      actions = ["Microsoft.Network/virtualNetworks/subnets/action"]
    }
  }
}

resource "azurerm_subnet" "management_jump" {
  name                            = "snet-jump"
  resource_group_name             = azurerm_resource_group.management_network.name
  virtual_network_name            = azurerm_virtual_network.management.name
  address_prefixes                = [local.management.snet_jump]
  default_outbound_access_enabled = false
}

resource "azurerm_subnet" "management_pe" {
  name                              = "snet-pe"
  resource_group_name               = azurerm_resource_group.management_network.name
  virtual_network_name              = azurerm_virtual_network.management.name
  address_prefixes                  = [local.management.snet_pe]
  default_outbound_access_enabled   = false
  private_endpoint_network_policies = "Enabled"
}

resource "azurerm_subnet" "management_aks_api_pe" {
  name                              = "snet-aks-api-pe"
  resource_group_name               = azurerm_resource_group.management_network.name
  virtual_network_name              = azurerm_virtual_network.management.name
  address_prefixes                  = [local.management.snet_aks_api_pe]
  default_outbound_access_enabled   = false
  private_endpoint_network_policies = "Enabled" # NSG applies to the API server private endpoints
}

locals {
  management_subnets = {
    runners    = azurerm_subnet.management_runners.id
    jump       = azurerm_subnet.management_jump.id
    pe         = azurerm_subnet.management_pe.id
    aks-api-pe = azurerm_subnet.management_aks_api_pe.id
  }
}

resource "azurerm_subnet_network_security_group_association" "management" {
  for_each                  = local.management_subnets
  subnet_id                 = each.value
  network_security_group_id = azurerm_network_security_group.management[each.key].id
}

locals {
  management_egress_subnets = { for k, v in local.management_subnets : k => v if k == "runners" || k == "jump" }
}

resource "azurerm_subnet_route_table_association" "management" {
  for_each       = local.firewall ? local.management_egress_subnets : {}
  subnet_id      = each.value
  route_table_id = azurerm_route_table.management[0].id
}

# Sandbox mode: Internet egress of the runners and the jump host through a NAT gateway instead of the Firewall,
# only while one of them exists
locals {
  management_nat = !local.firewall && (local.runners_enabled || var.jump_host_enabled)
}

resource "azurerm_public_ip" "management_nat" {
  count               = local.management_nat ? 1 : 0
  name                = "pip-nat-mgmt-${var.location}"
  location            = var.location
  resource_group_name = azurerm_resource_group.management_network.name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = ["1", "2", "3"]
  tags                = var.tags
}

resource "azurerm_nat_gateway" "management" {
  count               = local.management_nat ? 1 : 0
  name                = "nat-mgmt-${var.location}"
  location            = var.location
  resource_group_name = azurerm_resource_group.management_network.name
  sku_name            = "Standard"
  tags                = var.tags
}

resource "azurerm_nat_gateway_public_ip_association" "management" {
  count                = local.management_nat ? 1 : 0
  nat_gateway_id       = azurerm_nat_gateway.management[0].id
  public_ip_address_id = azurerm_public_ip.management_nat[0].id
}

resource "azurerm_subnet_nat_gateway_association" "management" {
  for_each       = local.management_nat ? local.management_egress_subnets : {}
  subnet_id      = each.value
  nat_gateway_id = azurerm_nat_gateway.management[0].id
}

resource "azurerm_virtual_network_peering" "management_to_hub" {
  name                         = "peer-mgmt-to-hub"
  resource_group_name          = azurerm_resource_group.management_network.name
  virtual_network_name         = azurerm_virtual_network.management.name
  remote_virtual_network_id    = local.hub_vnet.id
  allow_forwarded_traffic      = true
  allow_virtual_network_access = true
}

resource "azurerm_virtual_network_peering" "hub_to_management" {
  provider                     = azurerm.connectivity
  name                         = "peer-hub-to-mgmt"
  resource_group_name          = local.hub_vnet.resource_group_name
  virtual_network_name         = local.hub_vnet.name
  remote_virtual_network_id    = azurerm_virtual_network.management.id
  allow_forwarded_traffic      = true
  allow_virtual_network_access = true
}

# Sandbox mode has no DNS server in the hub: the VNet uses Azure DNS and is linked to every hub private DNS zone
# (Key Vault / ACR private link zones and the split-horizon zones). Firewall mode resolves through the Firewall
# DNS proxy, i.e. through the hub's links.
resource "azurerm_private_dns_zone_virtual_network_link" "hub_zones" {
  provider = azurerm.connectivity
  for_each = local.firewall ? {} : merge([for vnet_key, vnet in { management = azurerm_virtual_network.management, client = azurerm_virtual_network.client } : {
    for zone, _ in module.platform.private_dns_zones : "${vnet_key}/${zone}" => { zone = zone, vnet = vnet }
  }]...)
  name                  = "link-${each.value.vnet.name}"
  resource_group_name   = module.platform.dns_resource_group_name
  private_dns_zone_name = each.value.zone
  virtual_network_id    = each.value.vnet.id
  registration_enabled  = false
}
