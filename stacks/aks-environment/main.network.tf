# Backend spoke vnet-<env>-sf (OneK8s design section 8): exists from day one because it holds the PaaS private
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
  dns_servers         = module.platform.dns_servers
  tags                = local.tags
}

# Network mode firewall: one route table per zone (and one for the shared subnet): 0.0.0.0/0 and every other zone's address space of
# the VNet go to the Firewall, so a cross-zone packet that an NSG would allow is still inspected (section 2).
resource "azurerm_route_table" "backend" {
  for_each                      = local.firewall ? local.backend_subnets : {}
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
  for_each       = local.firewall ? local.backend_subnets : {}
  subnet_id      = azurerm_subnet.backend[each.key].id
  route_table_id = azurerm_route_table.backend[each.key].id
}

resource "azurerm_virtual_network" "edge" {
  name                = "vnet-${local.env}-edge"
  location            = var.location
  resource_group_name = azurerm_resource_group.network.name
  address_space       = local.edge.address_spaces
  dns_servers         = module.platform.dns_servers
  tags                = local.tags
}

resource "azurerm_route_table" "edge" {
  for_each                      = local.firewall ? local.edge.zones : {}
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
    name                   = "allow-https-from-corporate"
    priority               = 100
    direction              = "Inbound"
    access                 = "Allow"
    protocol               = "Tcp"
    source_port_range      = "*"
    destination_port_range = "443"
    # firewall: the Firewall decides which corporate sources reach the entry point; sandbox: the client VNet only
    source_address_prefixes    = local.firewall ? ["0.0.0.0/0"] : data.azurerm_virtual_network.client[0].address_space
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
  for_each       = local.firewall ? local.edge.zones : {}
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

# Network mode sandbox: no Firewall to route between spokes, so the networks that must talk are peered directly
# and the NSGs above are the only boundary: management VNet <-> backend (runners -> Key Vault / ACR private
# endpoints) and client VNet <-> edge (corporate clients -> internal entry points). Cells peer themselves to the
# backend and edge VNets (stacks/aks-stateless-cell).
data "azurerm_virtual_network" "client" {
  provider            = azurerm.connectivity
  count               = local.firewall ? 0 : 1
  name                = "vnet-client-${var.location}"
  resource_group_name = "rg-client-${var.location}"
}

resource "azurerm_virtual_network_peering" "backend_to_management" {
  count                        = local.firewall ? 0 : 1
  name                         = "peer-${local.env}-sf-to-mgmt"
  resource_group_name          = azurerm_resource_group.network.name
  virtual_network_name         = azurerm_virtual_network.backend.name
  remote_virtual_network_id    = data.azurerm_virtual_network.management.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = false
}

resource "azurerm_virtual_network_peering" "management_to_backend" {
  provider                     = azurerm.management
  count                        = local.firewall ? 0 : 1
  name                         = "peer-mgmt-to-${local.env}-sf"
  resource_group_name          = data.azurerm_virtual_network.management.resource_group_name
  virtual_network_name         = data.azurerm_virtual_network.management.name
  remote_virtual_network_id    = azurerm_virtual_network.backend.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = false
}

resource "azurerm_virtual_network_peering" "edge_to_client" {
  count                        = local.firewall ? 0 : 1
  name                         = "peer-${local.env}-edge-to-client"
  resource_group_name          = azurerm_resource_group.network.name
  virtual_network_name         = azurerm_virtual_network.edge.name
  remote_virtual_network_id    = data.azurerm_virtual_network.client[0].id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = false
}

resource "azurerm_virtual_network_peering" "client_to_edge" {
  provider                     = azurerm.connectivity
  count                        = local.firewall ? 0 : 1
  name                         = "peer-client-to-${local.env}-edge"
  resource_group_name          = data.azurerm_virtual_network.client[0].resource_group_name
  virtual_network_name         = data.azurerm_virtual_network.client[0].name
  remote_virtual_network_id    = azurerm_virtual_network.edge.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = false
}

# Sandbox mode has no DNS server in the hub: the VNet uses Azure DNS and is linked to every hub private DNS zone
# (Key Vault / ACR private link zones and the split-horizon zones). Firewall mode resolves through the Firewall
# DNS proxy, i.e. through the hub's links.
resource "azurerm_private_dns_zone_virtual_network_link" "hub_zones" {
  provider = azurerm.connectivity
  for_each = local.firewall ? {} : merge([for vnet_key, vnet in { backend = azurerm_virtual_network.backend, edge = azurerm_virtual_network.edge } : {
    for zone, _ in module.platform.private_dns_zones : "${vnet_key}/${zone}" => { zone = zone, vnet = vnet }
  }]...)
  name                  = "link-${each.value.vnet.name}"
  resource_group_name   = module.platform.dns_resource_group_name
  private_dns_zone_name = each.value.zone
  virtual_network_id    = each.value.vnet.id
  registration_enabled  = false
}
