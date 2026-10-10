# Cell VNet vnet-<env>-sl-az<N> (aks-design pictures 2 and 8): the control plane zone and every isolation zone
# get their own /20 address space; Azure Virtual Network encryption is the only encryption between nodes
# (section 13). Every subnet has its own NSG, every zone its own route table that sends 0.0.0.0/0 and the other
# zones' address spaces to the Firewall.
locals {
  cp = local.plan.control_plane

  zone_subnets = merge([for z, s in local.plan.zones : {
    "${z}-nodes" = { zone = z, name = "snet-${z}-nodes", prefix = s.snet_nodes, kind = "nodes" }
    "${z}-ilb"   = { zone = z, name = "snet-${z}-ilb", prefix = s.snet_ilb, kind = "ilb" }
    "${z}-pe"    = { zone = z, name = "snet-${z}-pe", prefix = s.snet_pe, kind = "pe" }
  }]...)

  control_plane_subnets = {
    system        = { zone = null, name = "snet-system", prefix = local.cp.snet_system, kind = "system" }
    apiserver     = { zone = null, name = "snet-apiserver", prefix = local.cp.snet_apiserver, kind = "apiserver" }
    apiserver-pls = { zone = null, name = "snet-apiserver-pls", prefix = local.cp.snet_apiserver_pls, kind = "pls" }
    platform-pe   = { zone = null, name = "snet-platform-pe", prefix = local.cp.snet_platform_pe, kind = "pe" }
  }

  subnets = merge(local.control_plane_subnets, local.zone_subnets)

  node_subnet_prefixes = concat([local.cp.snet_system], [for z, s in local.plan.zones : s.snet_nodes])
}

resource "azurerm_virtual_network" "cell" {
  name                = "vnet-${local.env}-${local.cell}"
  location            = var.location
  resource_group_name = azurerm_resource_group.cell.name
  address_space       = local.plan.address_spaces
  dns_servers         = [local.dns_server]
  tags                = local.tags

  encryption {
    enforcement = "AllowUnencrypted" # the only mode; the VM size allow-list (Azure Policy) keeps it encrypted
  }
}

resource "azurerm_route_table" "control_plane" {
  count                         = local.firewall ? 1 : 0
  name                          = "rt-${local.env}-${local.cell}-control-plane"
  location                      = var.location
  resource_group_name           = azurerm_resource_group.cell.name
  bgp_route_propagation_enabled = false
  tags                          = local.tags

  route {
    name                   = "default-via-firewall"
    address_prefix         = "0.0.0.0/0"
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = local.firewall_ip
  }
}

resource "azurerm_route_table" "zone" {
  for_each                      = local.firewall ? local.plan.zones : {}
  name                          = "rt-${local.env}-${local.cell}-${each.key}"
  location                      = var.location
  resource_group_name           = azurerm_resource_group.cell.name
  bgp_route_propagation_enabled = false
  tags                          = merge(local.tags, { zone = each.key })

  route {
    name                   = "default-via-firewall"
    address_prefix         = "0.0.0.0/0"
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = local.firewall_ip
  }

  # A UDR wins over the /20 system routes only with a prefix at least as specific: one route per other zone
  dynamic "route" {
    for_each = { for z, s in local.plan.zones : z => s.prefix if z != each.key }
    content {
      name                   = "${route.key}-via-firewall"
      address_prefix         = route.value
      next_hop_type          = "VirtualAppliance"
      next_hop_in_ip_address = local.firewall_ip
    }
  }
}

resource "azurerm_network_security_group" "subnet" {
  for_each            = local.subnets
  name                = "nsg-${local.env}-${local.cell}-${each.key}"
  location            = var.location
  resource_group_name = azurerm_resource_group.cell.name
  tags                = merge(local.tags, each.value.zone == null ? {} : { zone = each.value.zone })
}

locals {
  # Allowed flows of aks-design section 5 (numbers as in picture 5). Everything else inbound is denied; NSG
  # allow rules use zone prefixes, never the VirtualNetwork service tag.
  nsg_rules = merge(
    # Node subnets (system + zones)
    merge([for k, s in local.subnets : {
      "${k}-from-apiserver" = { nsg = k, priority = 100, protocol = "Tcp", ports = ["10250"], sources = [local.cp.snet_apiserver] } # ②
      "${k}-from-system"    = { nsg = k, priority = 110, protocol = "Tcp", ports = ["10250"], sources = [local.cp.snet_system] }    # ④
      "${k}-cilium-health"  = { nsg = k, priority = 120, protocol = "Tcp", ports = ["4240"], sources = local.node_subnet_prefixes } # ⑦
      "${k}-icmp"           = { nsg = k, priority = 130, protocol = "Icmp", ports = ["*"], sources = local.node_subnet_prefixes }   # ⑦
      # Overlay pod-to-pod traffic keeps the pod IPs; zone separation of pods is enforced by Cilium (third layer)
      "${k}-pods"        = { nsg = k, priority = 140, protocol = "*", ports = ["*"], sources = [var.pod_cidr] }
      "${k}-lb-probes"   = { nsg = k, priority = 150, protocol = "Tcp", ports = ["*"], sources = ["AzureLoadBalancer"] }
      "${k}-same-subnet" = { nsg = k, priority = 160, protocol = "*", ports = ["*"], sources = [s.prefix] }
    } if s.kind == "nodes" || s.kind == "system"]...),
    # Zone node subnets: HTTPS from the zone's entry point to Traefik
    merge([for z, s in local.plan.zones : {
      "${z}-nodes-from-entry-point" = {
        nsg      = "${z}-nodes"
        priority = 200
        protocol = "Tcp"
        ports    = ["443", "8443"]
        # int zones: NGINXaaS in the edge VNet; ext zones: the Private Link Service NAT IPs in snet-<zone>-ilb
        sources = local.zones[z].exposure == "int" ? [local.zones[z].slots["edge"]] : [s.snet_ilb]
      }
    }]...),
    {
      # ① nodes -> API server, Private Link from the management VNet, API server health probe
      "apiserver-from-nodes" = { nsg = "apiserver", priority = 100, protocol = "Tcp", ports = ["443", "4443"], sources = local.node_subnet_prefixes }
      "apiserver-from-pls"   = { nsg = "apiserver", priority = 110, protocol = "Tcp", ports = ["443"], sources = [local.cp.snet_apiserver_pls] }
      "apiserver-probe"      = { nsg = "apiserver", priority = 120, protocol = "Tcp", ports = ["9988"], sources = ["AzureLoadBalancer"] }
      # KMS private endpoint to the platform vault, created by AKS
      "platform-pe-from-apiserver" = { nsg = "platform-pe", priority = 100, protocol = "Tcp", ports = ["443"], sources = [local.cp.snet_apiserver] }
    },
    # Traefik internal load balancers: HTTPS only (section 13)
    merge([for z, s in local.plan.zones : {
      "${z}-ilb-https" = {
        nsg      = "${z}-ilb"
        priority = 100
        protocol = "Tcp"
        ports    = ["443"]
        sources  = local.zones[z].exposure == "int" ? [local.zones[z].slots["edge"]] : [s.snet_ilb]
      }
    }]...),
  )
}

resource "azurerm_network_security_rule" "allow" {
  for_each                    = local.nsg_rules
  name                        = "allow-${each.key}"
  priority                    = each.value.priority
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = each.value.protocol
  source_port_range           = "*"
  destination_port_range      = each.value.ports == ["*"] ? "*" : null
  destination_port_ranges     = each.value.ports == ["*"] ? null : each.value.ports
  source_address_prefixes     = can(regex("^[0-9]", each.value.sources[0])) ? each.value.sources : null    # prefixes
  source_address_prefix       = can(regex("^[0-9]", each.value.sources[0])) ? null : each.value.sources[0] # service tag
  destination_address_prefix  = local.subnets[each.value.nsg].prefix
  resource_group_name         = azurerm_resource_group.cell.name
  network_security_group_name = azurerm_network_security_group.subnet[each.value.nsg].name
}

resource "azurerm_network_security_rule" "deny_inbound" {
  for_each                    = local.subnets
  name                        = "deny-all-inbound"
  priority                    = 4000
  direction                   = "Inbound"
  access                      = "Deny"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.cell.name
  network_security_group_name = azurerm_network_security_group.subnet[each.key].name
}

resource "azurerm_subnet" "this" {
  for_each                                      = local.subnets
  name                                          = each.value.name
  resource_group_name                           = azurerm_resource_group.cell.name
  virtual_network_name                          = azurerm_virtual_network.cell.name
  address_prefixes                              = [each.value.prefix]
  default_outbound_access_enabled               = false
  private_endpoint_network_policies             = each.value.kind == "pe" ? "Enabled" : "Disabled"
  private_link_service_network_policies_enabled = each.value.kind != "pls" && each.value.kind != "ilb"

  dynamic "delegation" {
    for_each = each.value.kind == "apiserver" ? [1] : []
    content {
      name = "aks"
      service_delegation {
        name    = "Microsoft.ContainerService/managedClusters"
        actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
      }
    }
  }
}

resource "azurerm_subnet_network_security_group_association" "this" {
  for_each                  = local.subnets
  subnet_id                 = azurerm_subnet.this[each.key].id
  network_security_group_id = azurerm_network_security_group.subnet[each.key].id
}

resource "azurerm_subnet_route_table_association" "this" {
  for_each       = local.firewall ? { for k, s in local.subnets : k => s if s.kind != "apiserver" && s.kind != "pls" } : {}
  subnet_id      = azurerm_subnet.this[each.key].id
  route_table_id = each.value.zone == null ? azurerm_route_table.control_plane[0].id : azurerm_route_table.zone[each.value.zone].id
}

resource "azurerm_virtual_network_peering" "cell_to_hub" {
  name                         = "peer-${local.env}-${local.cell}-to-hub"
  resource_group_name          = azurerm_resource_group.cell.name
  virtual_network_name         = azurerm_virtual_network.cell.name
  remote_virtual_network_id    = local.hub_vnet.id
  allow_forwarded_traffic      = true
  allow_virtual_network_access = true
}

resource "azurerm_virtual_network_peering" "hub_to_cell" {
  provider                     = azurerm.connectivity
  name                         = "peer-hub-to-${local.env}-${local.cell}"
  resource_group_name          = local.hub_vnet.resource_group_name
  virtual_network_name         = local.hub_vnet.name
  remote_virtual_network_id    = azurerm_virtual_network.cell.id
  allow_forwarded_traffic      = true
  allow_virtual_network_access = true
}

# ---------------------------------------------------------------------------------------------------------------
# Network mode sandbox (network-mode.tfvars): no hub Firewall. Node egress through a zonal NAT gateway in the
# cell's AZ (outbound type userAssignedNATGateway), and direct peerings to the networks the cell must reach:
# the backend spoke (Key Vault / ACR / PaaS private endpoints) and the edge VNet (internal entry points). The
# NSGs above are then the only network boundary between zones; pods are still limited by Cilium policies.
# ---------------------------------------------------------------------------------------------------------------
locals {
  node_subnet_keys = concat(["system"], [for z, _ in local.plan.zones : "${z}-nodes"])
}

resource "azurerm_public_ip" "nat" {
  count               = local.firewall ? 0 : 1
  name                = "pip-nat-${local.env}-${local.cell}"
  location            = var.location
  resource_group_name = azurerm_resource_group.cell.name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = [local.az]
  tags                = local.tags
}

resource "azurerm_nat_gateway" "cell" {
  count               = local.firewall ? 0 : 1
  name                = "nat-${local.env}-${local.cell}"
  location            = var.location
  resource_group_name = azurerm_resource_group.cell.name
  sku_name            = "Standard"
  zones               = [local.az]
  tags                = local.tags
}

resource "azurerm_nat_gateway_public_ip_association" "cell" {
  count                = local.firewall ? 0 : 1
  nat_gateway_id       = azurerm_nat_gateway.cell[0].id
  public_ip_address_id = azurerm_public_ip.nat[0].id
}

resource "azurerm_subnet_nat_gateway_association" "nodes" {
  for_each       = local.firewall ? toset([]) : toset(local.node_subnet_keys)
  subnet_id      = azurerm_subnet.this[each.key].id
  nat_gateway_id = azurerm_nat_gateway.cell[0].id
}

data "azurerm_virtual_network" "environment" {
  for_each            = local.firewall ? toset([]) : toset(["sf", "edge"])
  name                = "vnet-${local.env}-${each.key}"
  resource_group_name = "rg-aks-${local.env}-network-${var.location}"
}

resource "azurerm_virtual_network_peering" "cell_to_environment" {
  for_each                     = data.azurerm_virtual_network.environment
  name                         = "peer-${local.env}-${local.cell}-to-${each.key}"
  resource_group_name          = azurerm_resource_group.cell.name
  virtual_network_name         = azurerm_virtual_network.cell.name
  remote_virtual_network_id    = each.value.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = false
}

resource "azurerm_virtual_network_peering" "environment_to_cell" {
  for_each                     = data.azurerm_virtual_network.environment
  name                         = "peer-${local.env}-${each.key}-to-${local.cell}"
  resource_group_name          = each.value.resource_group_name
  virtual_network_name         = each.value.name
  remote_virtual_network_id    = azurerm_virtual_network.cell.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = false
}
