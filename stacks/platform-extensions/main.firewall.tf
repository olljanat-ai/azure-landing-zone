# Hub Firewall rules (aks-design sections 5, 8 and 16). The Firewall decides what a *zone* may reach; Cilium FQDN
# policies decide what an *application* may reach. Rules are written with zone prefixes from the address plan
# (IP groups), never with the VirtualNetwork service tag.
locals {
  github_fqdns = [
    "github.com",
    "*.github.com",
    "*.githubusercontent.com",
    "*.actions.githubusercontent.com",
    "ghcr.io",
    "*.ghcr.io",
    "*.pkg.github.com",
    "*.blob.core.windows.net", # Actions artifacts, caches and job logs (GitHub-owned storage accounts)
  ]
  tooling_fqdns = [
    "registry.terraform.io",
    "releases.hashicorp.com",
    "checkpoint-api.hashicorp.com",
    "management.azure.com",
    "login.microsoftonline.com",
    "graph.microsoft.com",
    "aka.ms",
    "azcliprod.blob.core.windows.net",
    "packages.microsoft.com",
    "dl.k8s.io",
    "cdn.dl.k8s.io",
    "get.helm.sh",
    "mcr.microsoft.com",
    "*.data.mcr.microsoft.com",
  ]
  ubuntu_fqdns = [
    "*.ubuntu.com",
    "*.archive.ubuntu.com",
    "security.ubuntu.com",
    "*.snapcraft.io",
  ]
}

resource "azurerm_resource_group" "firewall_ip_groups" {
  provider = azurerm.connectivity
  name     = "rg-hub-ipgroups-${var.location}"
  location = var.location
  tags     = var.tags
}

resource "azurerm_ip_group" "management" {
  provider            = azurerm.connectivity
  name                = "ipg-mgmt"
  location            = var.location
  resource_group_name = azurerm_resource_group.firewall_ip_groups.name
  cidrs               = [local.management.snet_runners, local.management.snet_jump]
  tags                = var.tags
}

resource "azurerm_ip_group" "client" {
  provider            = azurerm.connectivity
  name                = "ipg-client"
  location            = var.location
  resource_group_name = azurerm_resource_group.firewall_ip_groups.name
  cidrs               = [var.client_address_space]
  tags                = var.tags
}

resource "azurerm_firewall_policy_rule_collection_group" "build_tenant" {
  provider           = azurerm.connectivity
  name               = "rcg-build-tenant"
  firewall_policy_id = module.platform.firewall_policy_id
  priority           = 200

  application_rule_collection {
    name     = "management-egress"
    priority = 100
    action   = "Allow"

    rule {
      name             = "runners-github"
      source_ip_groups = [azurerm_ip_group.management.id]
      destination_fqdns = concat(local.github_fqdns, [
        "${var.state_storage_account_name}.blob.core.windows.net",
      ])
      protocols {
        type = "Https"
        port = 443
      }
    }

    rule {
      name              = "runners-and-jump-tooling"
      source_ip_groups  = [azurerm_ip_group.management.id]
      destination_fqdns = local.tooling_fqdns
      protocols {
        type = "Https"
        port = 443
      }
    }

    rule {
      name              = "jump-and-clients-os-updates"
      source_ip_groups  = [azurerm_ip_group.management.id, azurerm_ip_group.client.id]
      destination_fqdns = local.ubuntu_fqdns
      protocols {
        type = "Http"
        port = 80
      }
      protocols {
        type = "Https"
        port = 443
      }
    }
  }

  network_rule_collection {
    name     = "management-network"
    priority = 200
    action   = "Allow"

    rule {
      name                  = "entra-id"
      protocols             = ["TCP"]
      source_ip_groups      = [azurerm_ip_group.management.id, azurerm_ip_group.client.id]
      destination_addresses = ["AzureActiveDirectory"]
      destination_ports     = ["443"]
    }
  }
}

# One rule collection group per AKS environment
resource "azurerm_ip_group" "zone_frontend" {
  provider = azurerm.connectivity
  for_each = merge([for env, plan in module.address_plan : {
    for zone, z in plan.zones : "${env}-${zone}" => { env = env, cidrs = [z.frontend] }
  }]...)
  name                = "ipg-${each.key}-frontend"
  location            = var.location
  resource_group_name = azurerm_resource_group.firewall_ip_groups.name
  cidrs               = each.value.cidrs
  tags                = var.tags
}

resource "azurerm_ip_group" "zone_backend" {
  provider = azurerm.connectivity
  for_each = merge([for env, plan in module.address_plan : {
    for zone, z in plan.zones : "${env}-${zone}" => { env = env, cidrs = [z.backend] }
  }]...)
  name                = "ipg-${each.key}-backend"
  location            = var.location
  resource_group_name = azurerm_resource_group.firewall_ip_groups.name
  cidrs               = each.value.cidrs
  tags                = var.tags
}

resource "azurerm_ip_group" "environment" {
  provider            = azurerm.connectivity
  for_each            = module.address_plan
  name                = "ipg-${each.key}-all"
  location            = var.location
  resource_group_name = azurerm_resource_group.firewall_ip_groups.name
  cidrs               = [each.value.environment_prefix]
  tags                = var.tags
}

# Control plane zones (system pools) of the stateless cells
resource "azurerm_ip_group" "control_planes" {
  provider            = azurerm.connectivity
  for_each            = module.address_plan
  name                = "ipg-${each.key}-control-planes"
  location            = var.location
  resource_group_name = azurerm_resource_group.firewall_ip_groups.name
  cidrs               = [for s in ["sl-az1", "sl-az2", "sl-az3"] : each.value.control_plane[s]]
  tags                = var.tags
}

# Everything in the frontend network: stateless cells and internal entry points. The backend prefixes (stateful
# cluster) are not in it, so they get no Internet access apart from the Entra ID and Azure Policy exceptions.
resource "azurerm_ip_group" "frontend" {
  provider            = azurerm.connectivity
  for_each            = module.address_plan
  name                = "ipg-${each.key}-frontend"
  location            = var.location
  resource_group_name = azurerm_resource_group.firewall_ip_groups.name
  cidrs = concat(
    [for s in ["sl-az1", "sl-az2", "sl-az3"] : each.value.control_plane[s]],
    [for z in each.value.zones : z.frontend],
  )
  tags = var.tags
}

resource "azurerm_firewall_policy_rule_collection_group" "aks" {
  provider           = azurerm.connectivity
  for_each           = module.address_plan
  name               = "rcg-aks-${each.key}"
  firewall_policy_id = module.platform.firewall_policy_id
  priority           = 300 + index(keys(module.address_plan), each.key) * 10

  network_rule_collection {
    name     = "aks-${each.key}-network"
    priority = 100
    action   = "Allow"

    # Stateless zone X -> zone X PaaS private endpoints and stateful applications (same zone only, TLS)
    dynamic "rule" {
      for_each = each.value.zones
      content {
        name                  = "${rule.key}-frontend-to-backend"
        protocols             = ["TCP"]
        source_ip_groups      = [azurerm_ip_group.zone_frontend["${each.key}-${rule.key}"].id]
        destination_ip_groups = [azurerm_ip_group.zone_backend["${each.key}-${rule.key}"].id]
        destination_ports     = ["443", "1433", "5432", "5671", "6380"]
      }
    }

    # All nodes -> shared private endpoints in the backend spoke (ACR, platform and zone Key Vaults)
    rule {
      name                  = "nodes-to-shared-pe"
      protocols             = ["TCP"]
      source_ip_groups      = [azurerm_ip_group.environment[each.key].id]
      destination_addresses = [each.value.backend.control_plane.snet_shared_pe]
      destination_ports     = ["443"]
    }

    # Workload identity token exchange: Entra ID has no Private Link for sign-in (aks-design open questions)
    rule {
      name                  = "entra-id"
      protocols             = ["TCP"]
      source_ip_groups      = [azurerm_ip_group.environment[each.key].id]
      destination_addresses = ["AzureActiveDirectory"]
      destination_ports     = ["443"]
    }

    # Runners and jump host -> private endpoints of the environment (Key Vault and ACR data plane, smoke tests)
    rule {
      name                  = "management-to-environment"
      protocols             = ["TCP"]
      source_ip_groups      = [azurerm_ip_group.management.id]
      destination_ip_groups = [azurerm_ip_group.environment[each.key].id]
      destination_ports     = ["443"]
    }

    # Corporate network (client VNet) -> internal entry points (NGINXaaS) of the int-* zones
    rule {
      name                  = "client-to-internal-entry-points"
      protocols             = ["TCP"]
      source_ip_groups      = [azurerm_ip_group.client.id]
      destination_addresses = [for z in each.value.edge.zones : z.prefix]
      destination_ports     = ["443"]
    }

    # Internal entry point of zone X -> Traefik of zone X in every cell. Network rule: no SNAT, so NGINX sees
    # the client address for client-IP affinity (aks-design section 8).
    dynamic "rule" {
      for_each = each.value.edge.zones
      content {
        name                  = "${rule.key}-edge-to-cells"
        protocols             = ["TCP"]
        source_addresses      = [rule.value.prefix]
        destination_addresses = [for s in ["sl-az1", "sl-az2", "sl-az3"] : each.value.zones[rule.key].slots[s]]
        destination_ports     = ["443"]
      }
    }
  }

  application_rule_collection {
    name     = "aks-${each.key}-platform"
    priority = 200
    action   = "Allow"

    rule {
      name                  = "aks-required"
      source_ip_groups      = [azurerm_ip_group.frontend[each.key].id]
      destination_fqdn_tags = ["AzureKubernetesService"]
      protocols {
        type = "Https"
        port = 443
      }
      protocols {
        type = "Http"
        port = 80
      }
    }

    rule {
      name             = "azure-policy-add-on"
      source_ip_groups = [azurerm_ip_group.environment[each.key].id]
      destination_fqdns = [
        "data.policy.core.windows.net",
        "store.policy.core.windows.net",
        "dc.services.visualstudio.com",
      ]
      protocols {
        type = "Https"
        port = 443
      }
    }

    rule {
      name             = "azure-monitor"
      source_ip_groups = [azurerm_ip_group.frontend[each.key].id]
      destination_fqdns = [
        "*.ods.opinsights.azure.com",
        "*.oms.opinsights.azure.com",
        "*.monitoring.azure.com",
        "global.handler.control.monitor.azure.com",
        "${var.location}.handler.control.monitor.azure.com",
        "*.ingest.monitor.azure.com",
        "*.metrics.ingest.monitor.azure.com",
      ]
      protocols {
        type = "Https"
        port = 443
      }
    }

    rule {
      name             = "defender-for-containers"
      source_ip_groups = [azurerm_ip_group.frontend[each.key].id]
      destination_fqdns = [
        "*.cloud.defender.microsoft.com",
      ]
      protocols {
        type = "Https"
        port = 443
      }
    }

    # GitOps extension (Flux) on the system pools of the stateless clusters (aks-design section 10). github.com
    # is only needed while the fleet is pulled from Git; with the OCI artifact in the environment ACR it is removed.
    rule {
      name             = "gitops-flux"
      source_ip_groups = [azurerm_ip_group.control_planes[each.key].id]
      destination_fqdns = [
        "${var.location}.dp.kubernetesconfiguration.azure.com",
        "management.azure.com",
        "login.microsoftonline.com",
        "${var.location}.login.microsoft.com",
        "mcr.microsoft.com",
        "*.data.mcr.microsoft.com",
        "github.com",
      ]
      protocols {
        type = "Https"
        port = 443
      }
    }
  }

  # Per-zone allow-lists: the union of what the zone's applications declare in their FQDN egress policies
  dynamic "application_rule_collection" {
    for_each = length(var.environments[each.key].zone_fqdn_allow_lists) > 0 ? [1] : []
    content {
      name     = "aks-${each.key}-zones"
      priority = 300
      action   = "Allow"
      dynamic "rule" {
        for_each = var.environments[each.key].zone_fqdn_allow_lists
        content {
          name              = "${rule.key}-allow-list"
          source_ip_groups  = [azurerm_ip_group.zone_frontend["${each.key}-${rule.key}"].id]
          destination_fqdns = rule.value
          protocols {
            type = "Https"
            port = 443
          }
        }
      }
    }
  }

  depends_on = [azurerm_firewall_policy_rule_collection_group.build_tenant]
}
