# Plans the cell in both network modes with mocked providers (no Azure access needed): `terraform test`.
mock_provider "azurerm" {}
mock_provider "azurerm" {
  alias = "connectivity"
}
mock_provider "azurerm" {
  alias = "management"
}
mock_provider "azapi" {}
mock_provider "time" {}

variables {
  environment     = "dev"
  cell            = "sl-az1"
  subscription_id = "00000000-0000-0000-0000-000000000003"
  platform_subscription_ids = {
    management   = "00000000-0000-0000-0000-000000000001"
    connectivity = "00000000-0000-0000-0000-000000000002"
  }
  name_suffix = "b1"
  dns_domain  = "example-test.com"
}

override_data {
  target = module.platform.data.azurerm_subscription.connectivity
  values = {
    id              = "/subscriptions/00000000-0000-0000-0000-000000000002"
    subscription_id = "00000000-0000-0000-0000-000000000002"
  }
}

override_data {
  target = module.platform.data.azurerm_virtual_network.hub
  values = {
    id                  = "/subscriptions/00000000-0000-0000-0000-000000000002/resourceGroups/rg-hub-swedencentral/providers/Microsoft.Network/virtualNetworks/vnet-hub-swedencentral"
    name                = "vnet-hub-swedencentral"
    resource_group_name = "rg-hub-swedencentral"
    address_space       = ["10.0.0.0/22"]
  }
}

override_data {
  target = module.platform.data.azurerm_firewall.hub
  values = {
    ip_configuration = [{ private_ip_address = "10.0.0.4", name = "default", subnet_id = "", public_ip_address_id = "" }]
  }
}

override_data {
  target = module.platform.data.azurerm_private_dns_resolver_inbound_endpoint.hub
  values = {
    ip_configurations = [{ private_ip_address = "10.0.0.164", private_ip_allocation_method = "Static", subnet_id = "" }]
  }
}

override_data {
  target = module.platform.data.azurerm_log_analytics_workspace.management
  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-management-swedencentral/providers/Microsoft.OperationalInsights/workspaces/law-management-swedencentral"
  }
}

override_data {
  target = data.azurerm_key_vault.platform
  values = {
    id   = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/rg-aks-dev-shared-swedencentral/providers/Microsoft.KeyVault/vaults/kv-dev-platform-b1"
    name = "kv-dev-platform-b1"
  }
}

override_data {
  target = data.azurerm_container_registry.environment
  values = {
    id           = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/rg-aks-dev-shared-swedencentral/providers/Microsoft.ContainerRegistry/registries/acrdevaksb1"
    login_server = "acrdevaksb1.azurecr.io"
  }
}

override_data {
  target = data.azurerm_kubernetes_service_versions.this
  values = {
    versions = ["1.33.5", "1.34.2", "1.34.4", "1.35.1", "1.36.0"]
  }
}

override_data {
  target = data.azurerm_resources.workload_identities
  values = {
    resources = [{
      id       = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/rg-aks-dev-identities-swedencentral/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-int-fi-gateway-secrets"
      name     = "id-int-fi-gateway-secrets"
      location = "swedencentral"
      type     = "Microsoft.ManagedIdentity/userAssignedIdentities"
      tags     = { namespace = "int-fi-gateway", service_account = "secrets-reader" }
    }]
  }
}

override_data {
  target = data.azurerm_subnet.management_api_pe
  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-mgmt-network-swedencentral/providers/Microsoft.Network/virtualNetworks/vnet-mgmt-swedencentral/subnets/snet-aks-api-pe"
  }
}

override_data {
  target = data.azurerm_virtual_network.management
  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-mgmt-network-swedencentral/providers/Microsoft.Network/virtualNetworks/vnet-mgmt-swedencentral"
  }
}

override_data {
  target = data.azurerm_virtual_network.environment
  values = {
    id                  = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/rg-aks-dev-network-swedencentral/providers/Microsoft.Network/virtualNetworks/vnet-dev-sf"
    name                = "vnet-dev-sf"
    resource_group_name = "rg-aks-dev-network-swedencentral"
  }
}

run "firewall_mode" {
  command = plan

  variables {
    network_mode = "firewall"
  }

  assert {
    condition     = azapi_resource.cluster.body.properties.networkProfile.outboundType == "userDefinedRouting"
    error_message = "firewall mode must route egress through the Firewall."
  }

  assert {
    condition     = length(azurerm_route_table.zone) == 4 && length(azurerm_nat_gateway.cell) == 0 && length(azurerm_virtual_network_peering.cell_to_environment) == 0
    error_message = "firewall mode: per-zone route tables, no NAT gateway, no direct peerings."
  }

  assert {
    condition     = azurerm_virtual_network.cell.dns_servers[0] == "10.0.0.4"
    error_message = "firewall mode uses the Firewall DNS proxy."
  }

  assert {
    condition     = local.kubernetes_version == "1.35.1"
    error_message = "sl-az1 runs the newest patch of the second latest minor (N-1)."
  }
}

run "sandbox_mode" {
  command = plan

  variables {
    network_mode            = "sandbox"
    cell                    = "sl-az2"
    kubernetes_minor_offset = 2
  }

  assert {
    condition     = azapi_resource.cluster.body.properties.networkProfile.outboundType == "userAssignedNATGateway"
    error_message = "sandbox mode egresses through the cell's NAT gateway."
  }

  assert {
    condition     = length(azurerm_route_table.zone) == 0 && length(azurerm_route_table.control_plane) == 0 && length(azurerm_subnet_nat_gateway_association.nodes) == 5
    error_message = "sandbox mode: no route tables, NAT gateway on the system and the four zone node subnets."
  }

  assert {
    condition     = toset(keys(azurerm_virtual_network_peering.cell_to_environment)) == toset(["sf", "edge"])
    error_message = "sandbox mode peers the cell directly with the backend and edge VNets."
  }

  assert {
    condition     = azurerm_virtual_network.cell.dns_servers[0] == "10.0.0.164" && azurerm_nat_gateway.cell[0].zones == toset(["2"])
    error_message = "sandbox mode resolves through the hub DNS resolver and uses a NAT gateway in the cell's AZ."
  }

  assert {
    condition     = local.kubernetes_version == "1.34.4"
    error_message = "sl-az2 runs the newest patch of N-2."
  }
}
