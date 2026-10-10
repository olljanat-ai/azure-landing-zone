module "platform" {
  source   = "../../modules/platform-lookup"
  location = var.location
  providers = {
    azurerm.connectivity = azurerm.connectivity
    azurerm.management   = azurerm.management
  }
}

module "address_plan" {
  source      = "../../modules/address-plan"
  environment = var.environment
  countries   = var.countries
}

data "azurerm_virtual_network" "management" {
  provider            = azurerm.management
  name                = "vnet-mgmt-${var.location}"
  resource_group_name = "rg-mgmt-network-${var.location}"
}

data "azurerm_subnet" "management" {
  provider             = azurerm.management
  for_each             = toset(["snet-runners", "snet-jump"])
  name                 = each.key
  virtual_network_name = data.azurerm_virtual_network.management.name
  resource_group_name  = data.azurerm_virtual_network.management.resource_group_name
}

data "azurerm_client_config" "current" {}

locals {
  env         = var.environment
  zones       = module.address_plan.zones
  firewall_ip = module.platform.firewall_private_ip
  hub_vnet    = module.platform.hub_virtual_network
  tags = merge({
    deployed_by = "terraform"
    platform    = "aks"
    environment = var.environment
  }, var.tags)

  management_prefixes = [for s in data.azurerm_subnet.management : s.address_prefixes[0]]

  key_vault_names = merge(
    { platform = "kv-${local.env}-platform-${var.name_suffix}" },
    { for z, _ in local.zones : z => "kv-${local.env}-${z}-${var.name_suffix}" },
  )
}

# Resource providers of everything the environment and its clusters use. Registration is idempotent.
resource "azapi_resource_action" "register_provider" {
  for_each = toset([
    "Microsoft.Cdn",
    "Microsoft.Compute",
    "Microsoft.ContainerRegistry",
    "Microsoft.ContainerService",
    "Microsoft.Dashboard",
    "Microsoft.Insights",
    "Microsoft.KeyVault",
    "Microsoft.KubernetesConfiguration",
    "Microsoft.ManagedIdentity",
    "Microsoft.Monitor",
    "Microsoft.Network",
    "Microsoft.OperationalInsights",
    "Microsoft.PolicyInsights",
    "Microsoft.Storage",
    "NGINX.NGINXPLUS",
  ])
  type        = "Microsoft.Resources/subscriptions@2022-12-01"
  resource_id = "/subscriptions/${var.subscription_id}"
  action      = "providers/${each.key}/register"
  method      = "POST"
}

resource "azurerm_resource_group" "shared" {
  name       = "rg-aks-${local.env}-shared-${var.location}"
  location   = var.location
  tags       = local.tags
  depends_on = [azapi_resource_action.register_provider]
}

resource "azurerm_resource_group" "network" {
  name       = "rg-aks-${local.env}-network-${var.location}"
  location   = var.location
  tags       = local.tags
  depends_on = [azapi_resource_action.register_provider]
}

resource "azurerm_resource_group" "identities" {
  name       = "rg-aks-${local.env}-identities-${var.location}"
  location   = var.location
  tags       = local.tags
  depends_on = [azapi_resource_action.register_provider]
}
