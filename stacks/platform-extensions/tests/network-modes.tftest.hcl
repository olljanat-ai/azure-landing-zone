# Plans the stack in both network modes with mocked providers (no Azure access needed): `terraform test`.
mock_provider "azurerm" {}
mock_provider "azurerm" {
  alias = "connectivity"
}
mock_provider "azurerm" {
  alias = "management"
}
mock_provider "azapi" {}
mock_provider "tls" {}
mock_provider "random" {}

variables {
  subscription_ids = {
    management   = "00000000-0000-0000-0000-000000000001"
    connectivity = "00000000-0000-0000-0000-000000000002"
  }
  environments = {
    dev = { subscription_id = "00000000-0000-0000-0000-000000000003" }
  }
  state_storage_account_name = "stoalzbuildswe1abcd"
  state_resource_group_name  = "rg-alz-build-state-swedencentral-1"
  state_container_name       = "build-tfstate"
  github_runner_token        = "github_pat_dummy"
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
  target = data.azurerm_storage_account.state
  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-alz-build-state-swedencentral-1/providers/Microsoft.Storage/storageAccounts/stoalzbuildswe1abcd"
  }
}

override_data {
  target = data.azurerm_subscription.environment
  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000003"
  }
}

override_data {
  target = data.azurerm_subscription.management
  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000001"
  }
}

run "firewall_mode" {
  command = plan

  variables {
    network_mode = "firewall"
  }

  assert {
    condition     = length(azurerm_firewall_policy_rule_collection_group.aks) == 1 && length(azurerm_route_table.management) == 1 && length(azurerm_nat_gateway.management) == 0
    error_message = "firewall mode: Firewall rules and route tables, no NAT gateways."
  }

  assert {
    condition     = length(azurerm_container_group.runners) == 2 && tolist(azurerm_container_group.runners["01"].dns_config[0].nameservers)[0] == "10.0.0.4"
    error_message = "two runners resolving through the Firewall DNS proxy."
  }
}

run "sandbox_mode" {
  command = plan

  variables {
    network_mode = "sandbox"
  }

  assert {
    condition     = length(azurerm_firewall_policy_rule_collection_group.aks) == 0 && length(azurerm_firewall_policy_rule_collection_group.build_tenant) == 0 && length(azurerm_ip_group.environment) == 0
    error_message = "sandbox mode creates no Firewall rules."
  }

  assert {
    condition     = length(azurerm_nat_gateway.management) == 1 && length(azurerm_nat_gateway.client) == 1 && length(azurerm_route_table.management) == 0 && length(azurerm_route_table.client) == 0
    error_message = "sandbox mode: NAT gateways instead of route tables."
  }

  assert {
    condition     = length(azurerm_role_assignment.aks_management_peering) == 1 && length(azurerm_role_assignment.aks_client_peering) == 1
    error_message = "sandbox mode lets the environment identity peer to the management and client VNets."
  }

  assert {
    condition     = tolist(azurerm_container_group.runners["01"].dns_config[0].nameservers)[0] == "10.0.0.164"
    error_message = "sandbox mode resolves through the hub DNS resolver."
  }
}
