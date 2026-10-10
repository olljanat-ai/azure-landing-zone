# Self-hosted GitHub runners in the management VNet, built the same way as the ALZ accelerator's GitHub
# bootstrap (accelerator-bootstrap-modules/modules/azure: container_registry.tf, container_instances.tf):
# a private ACR builds the runner image with an ACR task, and Azure Container Instances run ephemeral runners
# registered to this repository. Their traffic leaves through the hub Firewall (rules in main.firewall.tf).
locals {
  runners_enabled = nonsensitive(var.github_runner_token != "" || (var.github_runner_app_id != "" && var.github_runner_app_private_key != ""))
  runner_image    = "github-runner:${substr(var.github_runners.image_ref, 0, 7)}"
  runner_url      = "https://github.com/${var.github_repository}"
}

resource "random_string" "acr" {
  length  = 6
  special = false
  upper   = false
}

resource "azurerm_resource_group" "runners" {
  name     = "rg-mgmt-runners-${var.location}"
  location = var.location
  tags     = var.tags
}

resource "azurerm_container_registry" "runners" {
  name                          = "acrmgmtrunners${random_string.acr.result}"
  resource_group_name           = azurerm_resource_group.runners.name
  location                      = var.location
  sku                           = "Premium"
  admin_enabled                 = false
  public_network_access_enabled = false
  zone_redundancy_enabled       = true
  network_rule_bypass_option    = "AzureServices"
  tags                          = var.tags
}

resource "azapi_update_resource" "runners_acr_task_bypass" {
  type        = "Microsoft.ContainerRegistry/registries@2025-05-01-preview"
  resource_id = azurerm_container_registry.runners.id
  body = {
    properties = {
      networkRuleBypassAllowedForTasks = true
    }
  }
}

resource "azurerm_private_endpoint" "runners_acr" {
  name                = "pe-${azurerm_container_registry.runners.name}"
  location            = var.location
  resource_group_name = azurerm_resource_group.runners.name
  subnet_id           = azurerm_subnet.management_pe.id
  tags                = var.tags

  private_service_connection {
    name                           = "registry"
    private_connection_resource_id = azurerm_container_registry.runners.id
    subresource_names              = ["registry"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [module.platform.private_dns_zone_ids["acr"]]
  }
}

resource "azurerm_container_registry_task" "runner_image" {
  name                  = "image-build-task"
  container_registry_id = azurerm_container_registry.runners.id
  tags                  = var.tags

  platform {
    os = "Linux"
  }

  docker_step {
    dockerfile_path      = "Dockerfile"
    context_path         = "${var.github_runners.image_repository}#${var.github_runners.image_ref}:${var.github_runners.image_folder}"
    context_access_token = "a" # dummy value, not needed for a public repository (same as the accelerator)
    image_names          = [local.runner_image]
  }

  identity {
    type = "SystemAssigned"
  }

  registry_credential {
    custom {
      login_server = azurerm_container_registry.runners.login_server
      identity     = "[system]"
    }
  }
}

resource "azurerm_role_assignment" "runner_image_push" {
  scope                = azurerm_container_registry.runners.id
  role_definition_name = "AcrPush"
  principal_id         = azurerm_container_registry_task.runner_image.identity[0].principal_id
}

resource "azurerm_container_registry_task_schedule_run_now" "runner_image" {
  container_registry_task_id = azurerm_container_registry_task.runner_image.id
  depends_on                 = [azurerm_role_assignment.runner_image_push, azapi_update_resource.runners_acr_task_bypass]
  lifecycle {
    replace_triggered_by = [azurerm_container_registry_task.runner_image]
  }
}

resource "azurerm_user_assigned_identity" "runners" {
  name                = "id-mgmt-runners-${var.location}"
  location            = var.location
  resource_group_name = azurerm_resource_group.runners.name
  tags                = var.tags
}

resource "azurerm_role_assignment" "runners_pull" {
  scope                = azurerm_container_registry.runners.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.runners.principal_id
}

resource "azurerm_container_group" "runners" {
  for_each            = local.runners_enabled ? { for i in range(var.github_runners.count) : format("%02d", i + 1) => i } : {}
  name                = "aci-mgmt-runner-${each.key}"
  location            = var.location
  resource_group_name = azurerm_resource_group.runners.name
  ip_address_type     = "Private"
  os_type             = "Linux"
  subnet_ids          = [azurerm_subnet.management_runners.id]
  zones               = [tostring(each.value % 3 + 1)]
  restart_policy      = "Always" # ephemeral runners: the container exits after each job and registers again
  tags                = var.tags

  dns_config {
    nameservers = [local.firewall_ip]
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.runners.id]
  }

  image_registry_credential {
    server                    = azurerm_container_registry.runners.login_server
    user_assigned_identity_id = azurerm_user_assigned_identity.runners.id
  }

  container {
    name   = "runner"
    image  = "${azurerm_container_registry.runners.login_server}/${local.runner_image}"
    cpu    = var.github_runners.cpu
    memory = var.github_runners.memory

    ports {
      port     = 80
      protocol = "TCP"
    }

    environment_variables = merge({
      GH_RUNNER_URL  = local.runner_url
      GH_RUNNER_NAME = "aci-mgmt-runner-${each.key}"
      }, var.github_runner_app_id != "" ? {
      GH_RUNNER_APP_ID = var.github_runner_app_id
    } : {})

    secure_environment_variables = var.github_runner_token != "" ? {
      GH_RUNNER_TOKEN = var.github_runner_token
      } : {
      GH_RUNNER_APP_PRIVATE_KEY = var.github_runner_app_private_key
    }
  }

  depends_on = [
    azurerm_container_registry_task_schedule_run_now.runner_image,
    azurerm_role_assignment.runners_pull,
    azurerm_private_endpoint.runners_acr,
    azurerm_firewall_policy_rule_collection_group.build_tenant,
  ]
}
