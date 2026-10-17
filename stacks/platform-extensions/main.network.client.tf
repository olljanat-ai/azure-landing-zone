# Client VNet (OneK8s design section 23): simulates the corporate network. It is peered to the hub and routed
# through the Firewall like on-premises traffic, and its DNS forwards to the hub Private DNS Resolver like the
# corporate DNS servers would (sandbox mode: Azure DNS with the hub zones linked). Internal test clients and load generators for the int-* zones live here.
resource "azurerm_resource_group" "client" {
  provider = azurerm.connectivity
  name     = "rg-client-${var.location}"
  location = var.location
  tags     = var.tags
}

resource "azurerm_virtual_network" "client" {
  provider            = azurerm.connectivity
  name                = "vnet-client-${var.location}"
  location            = var.location
  resource_group_name = azurerm_resource_group.client.name
  address_space       = [var.client_address_space]
  dns_servers         = local.spoke_dns_servers
  tags                = var.tags
}

resource "azurerm_route_table" "client" {
  count                         = local.routed ? 1 : 0
  provider                      = azurerm.connectivity
  name                          = "rt-client-${var.location}"
  location                      = var.location
  resource_group_name           = azurerm_resource_group.client.name
  bgp_route_propagation_enabled = false
  tags                          = var.tags

  route {
    name                   = "default-via-firewall"
    address_prefix         = "0.0.0.0/0"
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = local.firewall_ip
  }
}

resource "azurerm_network_security_group" "client" {
  provider            = azurerm.connectivity
  name                = "nsg-client-${var.location}"
  location            = var.location
  resource_group_name = azurerm_resource_group.client.name
  tags                = var.tags

  security_rule {
    name                       = "allow-bastion-ssh"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = var.hub_bastion_subnet_prefix
    destination_address_prefix = var.client_address_space
  }
}

resource "azurerm_subnet" "client" {
  provider                        = azurerm.connectivity
  for_each                        = local.client
  name                            = replace(each.key, "_", "-")
  resource_group_name             = azurerm_resource_group.client.name
  virtual_network_name            = azurerm_virtual_network.client.name
  address_prefixes                = [each.value]
  default_outbound_access_enabled = false
}

resource "azurerm_subnet_network_security_group_association" "client" {
  provider                  = azurerm.connectivity
  for_each                  = azurerm_subnet.client
  subnet_id                 = each.value.id
  network_security_group_id = azurerm_network_security_group.client.id
}

resource "azurerm_subnet_route_table_association" "client" {
  provider       = azurerm.connectivity
  for_each       = local.routed ? azurerm_subnet.client : {}
  subnet_id      = each.value.id
  route_table_id = azurerm_route_table.client[0].id
}

# Sandbox mode: the clients reach the Internet through a NAT gateway, which only exists while the test client does.
# The internal entry points (the cells of onek8s/aks-terraform) are not peered to the client VNet yet
locals {
  client_nat = !local.routed && var.client_vm_enabled
}

resource "azurerm_public_ip" "client_nat" {
  provider            = azurerm.connectivity
  count               = local.client_nat ? 1 : 0
  name                = "pip-nat-client-${var.location}"
  location            = var.location
  resource_group_name = azurerm_resource_group.client.name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = ["1", "2", "3"]
  tags                = var.tags
}

resource "azurerm_nat_gateway" "client" {
  provider            = azurerm.connectivity
  count               = local.client_nat ? 1 : 0
  name                = "nat-client-${var.location}"
  location            = var.location
  resource_group_name = azurerm_resource_group.client.name
  sku_name            = "Standard"
  tags                = var.tags
}

resource "azurerm_nat_gateway_public_ip_association" "client" {
  provider             = azurerm.connectivity
  count                = local.client_nat ? 1 : 0
  nat_gateway_id       = azurerm_nat_gateway.client[0].id
  public_ip_address_id = azurerm_public_ip.client_nat[0].id
}

resource "azurerm_subnet_nat_gateway_association" "client" {
  provider       = azurerm.connectivity
  for_each       = local.client_nat ? azurerm_subnet.client : {}
  subnet_id      = each.value.id
  nat_gateway_id = azurerm_nat_gateway.client[0].id
}

resource "azurerm_virtual_network_peering" "client_to_hub" {
  provider                     = azurerm.connectivity
  name                         = "peer-client-to-hub"
  resource_group_name          = azurerm_resource_group.client.name
  virtual_network_name         = azurerm_virtual_network.client.name
  remote_virtual_network_id    = local.hub_vnet.id
  allow_forwarded_traffic      = true
  allow_virtual_network_access = true
}

resource "azurerm_virtual_network_peering" "hub_to_client" {
  provider                     = azurerm.connectivity
  name                         = "peer-hub-to-client"
  resource_group_name          = local.hub_vnet.resource_group_name
  virtual_network_name         = local.hub_vnet.name
  remote_virtual_network_id    = azurerm_virtual_network.client.id
  allow_forwarded_traffic      = true
  allow_virtual_network_access = true
}
