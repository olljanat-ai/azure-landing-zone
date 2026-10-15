# Network mode "labfw": labfw (onek8s/azure-lab-fw, modules/labfw) in the hub instead of Azure Firewall. It
# enforces the exposure's child Firewall Policy of main.firewall.policies.tf together with the parent - the same
# policies a hub Firewall would get (D53) - and holds the build tenant's egress rules in the parent
# (main.firewall.tf). The management and client VNets send 0.0.0.0/0 to it like to the Firewall; everything else
# stays as in sandbox mode: no Azure Firewall, the cells (onek8s/aks-terraform) keep their own NAT gateways and
# direct peerings.
#
# The optional WireGuard VPN connects agent and management machines outside Azure: its client pool is treated as
# management (ipg-mgmt in the policies, the API server private endpoints' NSG).
locals {
  labfw_vpn      = local.labfw && var.labfw.vpn.enabled
  labfw_vpn_pool = local.labfw_vpn ? [cidrsubnet(var.labfw.vpn.address, 0, 0)] : []
  # Routed through labfw: the hub and the spokes of this stack
  labfw_trusted_prefixes = concat(local.hub_vnet.address_space, [var.management_address_space, var.client_address_space])
}

module "labfw" {
  source = "../../modules/labfw"
  count  = local.labfw ? 1 : 0
  providers = {
    azurerm = azurerm.connectivity
  }

  location            = var.location
  resource_group_name = "rg-hub-labfw-${var.location}"
  hub_virtual_network = local.hub_vnet
  subnet_prefix       = var.labfw.subnet_prefix
  policy_id           = azurerm_firewall_policy.exposure[var.labfw.policy_exposure].id
  trusted_prefixes    = local.labfw_trusted_prefixes
  vm_size             = var.labfw.vm_size
  arch                = var.labfw.arch
  # Provisioning only: the VM is managed with Run Command
  admin_ssh_public_key   = tls_private_key.vm.public_key_openssh
  release_version        = var.labfw.release_version
  release_repo           = var.labfw.release_repo
  dns_proxy              = true # also the VPN clients' DNS server for the private link zones
  reader_scopes          = ["/subscriptions/${module.platform.connectivity_subscription_id}"]
  operator_principal_ids = var.labfw.operator_principal_ids
  tags                   = var.tags

  vpn = {
    enabled         = var.labfw.vpn.enabled
    address         = var.labfw.vpn.address
    listen_port     = var.labfw.vpn.listen_port
    source_prefixes = var.labfw.vpn.source_prefixes
    client_routes   = local.labfw_trusted_prefixes
    peers           = var.labfw.vpn.peers
  }

  # The policy hierarchy is complete before labfw first reads it
  depends_on = [
    azurerm_firewall_policy_rule_collection_group.build_tenant,
    azurerm_firewall_policy_rule_collection_group.exposure_environment,
  ]
}

# VPN clients reach the API server private endpoints like the runners and the jump host. labfw SNATs their
# traffic to private destinations (private endpoints answer the source directly), so the NSG sees labfw's address;
# what may pass is decided by the policy (rcg-build-tenant, management-vpn).
resource "azurerm_network_security_rule" "management_api_pe_vpn" {
  count                       = local.labfw_vpn ? 1 : 0
  name                        = "allow-labfw-vpn-to-api-servers"
  priority                    = 110
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = module.labfw[0].private_ip
  destination_address_prefix  = local.management.snet_aks_api_pe
  resource_group_name         = azurerm_resource_group.management_network.name
  network_security_group_name = azurerm_network_security_group.management["aks-api-pe"].name
}

resource "azurerm_network_security_rule" "management_jump_vpn" {
  count                       = local.labfw_vpn ? 1 : 0
  name                        = "allow-labfw-vpn-ssh"
  priority                    = 110
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "22"
  source_address_prefix       = module.labfw[0].private_ip
  destination_address_prefix  = local.management.snet_jump
  resource_group_name         = azurerm_resource_group.management_network.name
  network_security_group_name = azurerm_network_security_group.management["jump"].name
}
