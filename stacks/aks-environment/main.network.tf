# Backend spoke vnet-<env>-sf (aks-design section 8): exists from day one because it holds the PaaS private
# endpoints, the environment's ACR and the Key Vault private endpoints. The stateful cluster's subnets are
# reserved in the address plan and only created with that cluster. No Internet: the Firewall gives the backend
# prefixes only the Entra ID and Azure Policy exceptions.
#
# Edge VNet vnet-<env>-edge: one delegated NGINXaaS subnet per internal zone, inside the zone's address space.
locals {
  backend = module.address_plan.backend
  edge    = module.address_plan.edge

  backend_subnets = merge(
    {
      shared = {
        name   = "snet-shared-pe"
        prefix = local.backend.control_plane.snet_shared_pe
        zone   = null
      }
    },
    { for z, s in local.backend.zones : z => {
      name   = "snet-${z}-pe"
      prefix = s.snet_pe
      zone   = z
    } },
  )
}

resource "azurerm_virtual_network" "backend" {
  name                = "vnet-${local.env}-sf"
  location            = var.location
  resource_group_name = azurerm_resource_group.network.name
  address_space       = local.backend.address_spaces
  dns_servers         = [local.firewall_ip]
  tags                = local.tags
}

# One route table per zone (and one for the shared subnet): 0.0.0.0/0 and every other zone's address space of
# the VNet go to the Firewall, so a cross-zone packet that an NSG would allow is still inspected (section 2).
resource "azurerm_route_table" "backend" {
  for_each                      = local.backend_subnets
  name                          = "rt-${local.env}-sf-${each.key}"
  location                      = var.location
  resource_group_name           = azurerm_resource_group.network.name
  bgp_route_propagation_enabled = false
  tags                          = local.tags

  route {
    name                   = "default-via-firewall"
    address_prefix         = "0.0.0.0/0"
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = local.firewall_ip
  }

  dynamic "route" {
    for_each = { for z, s in local.backend.zones : z => s.prefix if z != each.value.zone }
    content {
      name                   = "${route.key}-via-firewall"
      address_prefix         = route.value
      next_hop_type          = "VirtualAppliance"
      next_hop_in_ip_address = local.firewall_ip
    }
  }
}

resource "azurerm_network_security_group" "backend" {
  for_each            = local.backend_subnets
  name                = "nsg-${local.env}-sf-${each.key}"
  location            = var.location
  resource_group_name = azurerm_resource_group.network.name
  tags                = local.tags
}

# Zone PE subnets: only the same zone's frontend (cells + entry point) and the management runners
resource "azurerm_network_security_rule" "backend_zone_in" {
  for_each                    = local.backend.zones
  name                        = "allow-${each.key}-frontend"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_ranges     = ["443", "1433", "5432", "5671", "6380"]
  source_address_prefixes     = concat([local.zones[each.key].frontend], local.management_prefixes)
  destination_address_prefix  = each.value.snet_pe
  resource_group_name         = azurerm_resource_group.network.name
  network_security_group_name = azurerm_network_security_group.backend[each.key].name
}

resource "azurerm_network_security_rule" "backend_shared_in" {
  name                        = "allow-environment-and-management"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefixes     = concat([module.address_plan.environment_prefix], local.management_prefixes)
  destination_address_prefix  = local.backend.control_plane.snet_shared_pe
  resource_group_name         = azurerm_resource_group.network.name
  network_security_group_name = azurerm_network_security_group.backend["shared"].name
}

resource "azurerm_network_security_rule" "backend_deny_in" {
  for_each                    = local.backend_subnets
  name                        = "deny-all-inbound"
  priority                    = 4000
  direction                   = "Inbound"
  access                      = "Deny"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.network.name
  network_security_group_name = azurerm_network_security_group.backend[each.key].name
}

resource "azurerm_subnet" "backend" {
  for_each                          = local.backend_subnets
  name                              = each.value.name
  resource_group_name               = azurerm_resource_group.network.name
  virtual_network_name              = azurerm_virtual_network.backend.name
  address_prefixes                  = [each.value.prefix]
  default_outbound_access_enabled   = false
  private_endpoint_network_policies = "Enabled" # NSG and UDR apply to private endpoints: symmetric path through the Firewall
}

resource "azurerm_subnet_network_security_group_association" "backend" {
  for_each                  = local.backend_subnets
  subnet_id                 = azurerm_subnet.backend[each.key].id
  network_security_group_id = azurerm_network_security_group.backend[each.key].id
}

resource "azurerm_subnet_route_table_association" "backend" {
  for_each       = local.backend_subnets
  subnet_id      = azurerm_subnet.backend[each.key].id
  route_table_id = azurerm_route_table.backend[each.key].id
}

resource "azurerm_virtual_network" "edge" {
  name                = "vnet-${local.env}-edge"
  location            = var.location
  resource_group_name = azurerm_resource_group.network.name
  address_space       = local.edge.address_spaces
  dns_servers         = [local.firewall_ip]
  tags                = local.tags
}

resource "azurerm_route_table" "edge" {
  for_each                      = local.edge.zones
  name                          = "rt-${local.env}-edge-${each.key}"
  location                      = var.location
  resource_group_name           = azurerm_resource_group.network.name
  bgp_route_propagation_enabled = false
  tags                          = local.tags

  route {
    name                   = "default-via-firewall"
    address_prefix         = "0.0.0.0/0"
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = local.firewall_ip
  }

  dynamic "route" {
    for_each = { for z, s in local.edge.zones : z => s.prefix if z != each.key }
    content {
      name                   = "${route.key}-via-firewall"
      address_prefix         = route.value
      next_hop_type          = "VirtualAppliance"
      next_hop_in_ip_address = local.firewall_ip
    }
  }
}

resource "azurerm_network_security_group" "edge" {
  for_each            = local.edge.zones
  name                = "nsg-${local.env}-edge-${each.key}"
  location            = var.location
  resource_group_name = azurerm_resource_group.network.name
  tags                = local.tags

  security_rule {
    name                       = "allow-https-from-corporate"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "*" # the Firewall decides which corporate sources reach the entry point
    destination_address_prefix = each.value.snet_nginx
  }
}

resource "azurerm_subnet" "edge" {
  for_each                        = local.edge.zones
  name                            = "snet-${each.key}-nginx"
  resource_group_name             = azurerm_resource_group.network.name
  virtual_network_name            = azurerm_virtual_network.edge.name
  address_prefixes                = [each.value.snet_nginx]
  default_outbound_access_enabled = false
  delegation {
    name = "nginx"
    service_delegation {
      name    = "NGINX.NGINXPLUS/nginxDeployments"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_subnet_network_security_group_association" "edge" {
  for_each                  = local.edge.zones
  subnet_id                 = azurerm_subnet.edge[each.key].id
  network_security_group_id = azurerm_network_security_group.edge[each.key].id
}

resource "azurerm_subnet_route_table_association" "edge" {
  for_each       = local.edge.zones
  subnet_id      = azurerm_subnet.edge[each.key].id
  route_table_id = azurerm_route_table.edge[each.key].id
}

# Hub peerings (both directions; the hub side with the custom "AKS spoke peering" role)
locals {
  spokes = {
    sf   = azurerm_virtual_network.backend
    edge = azurerm_virtual_network.edge
  }
}

resource "azurerm_virtual_network_peering" "spoke_to_hub" {
  for_each                     = local.spokes
  name                         = "peer-${local.env}-${each.key}-to-hub"
  resource_group_name          = azurerm_resource_group.network.name
  virtual_network_name         = each.value.name
  remote_virtual_network_id    = local.hub_vnet.id
  allow_forwarded_traffic      = true
  allow_virtual_network_access = true
}

resource "azurerm_virtual_network_peering" "hub_to_spoke" {
  provider                     = azurerm.connectivity
  for_each                     = local.spokes
  name                         = "peer-hub-to-${local.env}-${each.key}"
  resource_group_name          = local.hub_vnet.resource_group_name
  virtual_network_name         = local.hub_vnet.name
  remote_virtual_network_id    = each.value.id
  allow_forwarded_traffic      = true
  allow_virtual_network_access = true
}
