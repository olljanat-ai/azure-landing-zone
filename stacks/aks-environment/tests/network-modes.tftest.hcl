# Plans the stack in both network modes with mocked providers (no Azure access needed): `terraform test`.
mock_provider "azurerm" {}
mock_provider "azurerm" {
  alias = "connectivity"
}
mock_provider "azurerm" {
  alias = "management"
}
mock_provider "azapi" {}

variables {
  environment     = "dev"
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
  target = module.platform.data.azurerm_firewall_policy.hub
  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000002/resourceGroups/rg-hub-swedencentral/providers/Microsoft.Network/firewallPolicies/fwp-hub-swedencentral"
  }
}

override_data {
  target = module.platform.data.azurerm_private_dns_resolver_inbound_endpoint.hub
  values = {
    ip_configurations = [{ private_ip_address = "10.0.0.164", private_ip_allocation_method = "Static", subnet_id = "" }]
  }
}

override_data {
  target = module.platform.data.azurerm_private_dns_zone.hub
  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000002/resourceGroups/rg-hub-dns-swedencentral/providers/Microsoft.Network/privateDnsZones/privatelink.vaultcore.azure.net"
  }
}

override_data {
  target = module.platform.data.azurerm_log_analytics_workspace.management
  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-management-swedencentral/providers/Microsoft.OperationalInsights/workspaces/law-management-swedencentral"
  }
}

override_data {
  target = data.azurerm_virtual_network.management
  values = {
    id                  = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-mgmt-network-swedencentral/providers/Microsoft.Network/virtualNetworks/vnet-mgmt-swedencentral"
    name                = "vnet-mgmt-swedencentral"
    resource_group_name = "rg-mgmt-network-swedencentral"
  }
}

override_data {
  target = data.azurerm_subnet.management
  values = {
    address_prefixes = ["10.0.8.0/26"]
  }
}

override_data {
  target = data.azurerm_virtual_network.client
  values = {
    id                  = "/subscriptions/00000000-0000-0000-0000-000000000002/resourceGroups/rg-client-swedencentral/providers/Microsoft.Network/virtualNetworks/vnet-client-swedencentral"
    name                = "vnet-client-swedencentral"
    resource_group_name = "rg-client-swedencentral"
    address_space       = ["10.200.0.0/22"]
  }
}

override_data {
  target = data.azurerm_client_config.current
  values = {
    tenant_id = "00000000-0000-0000-0000-0000000000aa"
    object_id = "00000000-0000-0000-0000-0000000000bb"
  }
}

run "firewall_mode" {
  command = plan

  variables {
    network_mode = "firewall"
  }

  assert {
    condition     = length(azurerm_route_table.backend) == 5 && length(azurerm_route_table.edge) == 2 && length(azurerm_virtual_network_peering.backend_to_management) == 0
    error_message = "firewall mode: route tables via the Firewall, no direct peerings."
  }

  assert {
    condition     = azurerm_virtual_network.backend.dns_servers[0] == "10.0.0.4"
    error_message = "firewall mode uses the Firewall DNS proxy."
  }
}

run "sandbox_mode" {
  command = plan

  variables {
    network_mode = "sandbox"
  }

  assert {
    condition     = length(azurerm_route_table.backend) == 0 && length(azurerm_route_table.edge) == 0
    error_message = "sandbox mode has no route tables."
  }

  assert {
    condition = (
      length(azurerm_virtual_network_peering.backend_to_management) == 1 &&
      length(azurerm_virtual_network_peering.management_to_backend) == 1 &&
      length(azurerm_virtual_network_peering.edge_to_client) == 1 &&
      length(azurerm_virtual_network_peering.client_to_edge) == 1
    )
    error_message = "sandbox mode peers management <-> backend and client <-> edge directly."
  }

  assert {
    condition     = azurerm_virtual_network.edge.dns_servers[0] == "10.0.0.164" && contains(one(azurerm_network_security_group.edge["int-fi"].security_rule).source_address_prefixes, "10.200.0.0/22") && length(one(azurerm_network_security_group.edge["int-fi"].security_rule).source_address_prefixes) == 1
    error_message = "sandbox mode: hub DNS resolver, entry points open to the client VNet only."
  }
}
