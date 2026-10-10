# GitOps (aks-design section 10): the AKS GitOps extension (microsoft.flux) is installed by the cluster IaC, so
# Microsoft manages its lifecycle. Everything inside the cluster then comes from the fleet repository. The IaC
# hands the cluster its variables (the "cluster-vars" of section 9) as Flux post-build substitutions.
locals {
  cluster_vars = merge(
    {
      ENV              = local.env
      CLUSTER_TYPE     = "stateless"
      CLUSTER_NAME     = local.cluster_name
      CELL             = local.cell
      AZ               = local.az
      LOCATION         = var.location
      TENANT_ID        = data.azurerm_client_config.current.tenant_id
      ACR_LOGIN_SERVER = data.azurerm_container_registry.environment.login_server
      PLATFORM_VAULT   = data.azurerm_key_vault.platform.name
      DNS_DOMAIN       = "${local.env}.${var.dns_domain}"
      POD_CIDR         = var.pod_cidr
    },
    # Per zone: node subnet for the NAP AKSNodeClass, ILB subnet for Traefik, zone vault, secret reader identity
    merge([for z, s in local.plan.zones : {
      "SUBNET_ID_${upper(replace(z, "-", "_"))}"         = azurerm_subnet.this["${z}-nodes"].id
      "ILB_SUBNET_${upper(replace(z, "-", "_"))}"        = azurerm_subnet.this["${z}-ilb"].name
      "ZONE_VAULT_${upper(replace(z, "-", "_"))}"        = data.azurerm_key_vault.zone[z].name
      "GATEWAY_CLIENT_ID_${upper(replace(z, "-", "_"))}" = try(data.azurerm_user_assigned_identity.gateway_secrets[z].client_id, "")
    }]...),
  )

  fleet_path = var.fleet == null ? null : coalesce(var.fleet.path, "./clusters/${local.env}/${local.cell}")
}

data "azurerm_user_assigned_identity" "gateway_secrets" {
  for_each            = local.zones
  name                = "id-${each.key}-gateway-secrets"
  resource_group_name = "rg-aks-${local.env}-identities-${var.location}"
}

resource "azapi_resource" "flux" {
  type      = "Microsoft.KubernetesConfiguration/extensions@2024-11-01"
  name      = "flux"
  parent_id = azapi_resource.cluster.id

  body = {
    properties = {
      extensionType           = "microsoft.flux"
      autoUpgradeMinorVersion = true
      releaseTrain            = "Stable"
      scope = {
        cluster = {
          releaseNamespace = "flux-system"
        }
      }
      configurationSettings = {
        "multiTenancy.enforce"                = "false"
        "workloadIdentity.enable"             = "true"
        "helm-controller.enabled"             = "true"
        "image-automation-controller.enabled" = "false"
        "image-reflector-controller.enabled"  = "false"
        # Flux is a platform component: it runs on the system pool (taint CriticalAddonsOnly), never on zone nodes
        "toleration-keys" = "CriticalAddonsOnly"
      }
    }
  }

  timeouts {
    create = "30m"
  }
}

resource "azapi_resource" "fleet" {
  count     = var.fleet == null ? 0 : 1
  type      = "Microsoft.KubernetesConfiguration/fluxConfigurations@2024-11-01"
  name      = "fleet"
  parent_id = azapi_resource.cluster.id

  body = {
    properties = {
      scope      = "cluster"
      namespace  = "flux-system"
      sourceKind = var.fleet.kind
      suspend    = false
      gitRepository = var.fleet.kind == "GitRepository" ? {
        url                   = var.fleet.url
        repositoryRef         = { branch = var.fleet.branch }
        syncIntervalInSeconds = var.fleet.sync_every
        timeoutInSeconds      = 600
      } : null
      ociRepository = var.fleet.kind == "OCIRepository" ? {
        url                   = var.fleet.url
        repositoryRef         = { tag = coalesce(var.fleet.tag, "${local.env}-${local.cell}") }
        syncIntervalInSeconds = var.fleet.sync_every
        timeoutInSeconds      = 600
        useWorkloadIdentity   = true
      } : null
      kustomizations = {
        # Entry point of the cell; it holds the infra-controllers -> infra-configs -> apps chain (dependsOn)
        cluster = {
          path                   = local.fleet_path
          prune                  = true
          wait                   = true
          syncIntervalInSeconds  = var.fleet.sync_every
          timeoutInSeconds       = 1800
          retryIntervalInSeconds = 120
          postBuild = {
            substitute = local.cluster_vars
          }
        }
      }
    }
  }

  ignore_null_property = true # gitRepository / ociRepository: only the one of sourceKind is sent

  depends_on = [azapi_resource.flux]
}
