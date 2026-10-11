# Key Vaults (aks-design sections 6, 13 and 18): one per isolation zone for application secrets and one platform
# vault for the environment's certificates and the clusters' customer-managed keys. RBAC permission model,
# public network access disabled, purge protection. The private endpoints are in the backend spoke and reached
# through the Firewall: zone X only from zone X (rule "frontend-to-backend"), the platform vault from every node.
# Lab (key_vault_public_access): public endpoint with Entra ID / RBAC as the only control and no private endpoints,
# so the GitHub-hosted runners reach the data plane.
resource "azurerm_key_vault" "this" {
  for_each                      = local.key_vault_names
  name                          = each.value
  location                      = var.location
  resource_group_name           = azurerm_resource_group.shared.name
  tenant_id                     = data.azurerm_client_config.current.tenant_id
  sku_name                      = var.key_vault_sku # premium: HSM-protected keys (open question)
  rbac_authorization_enabled    = true
  public_network_access_enabled = var.key_vault_public_access
  purge_protection_enabled      = true
  soft_delete_retention_days    = 90
  tags                          = merge(local.tags, { zone = each.key })

  network_acls {
    default_action = var.key_vault_public_access ? "Allow" : "Deny"
    # Trusted services: disk encryption sets reach the platform vault although public access is disabled
    bypass = "AzureServices"
  }

}

resource "azurerm_management_lock" "platform_key_vault" {
  name       = "lock-${azurerm_key_vault.this["platform"].name}"
  scope      = azurerm_key_vault.this["platform"].id
  lock_level = "CanNotDelete"
  notes      = "Deleting the platform vault destroys every cluster's KMS and disk keys (aks-design section 18)."
}

resource "azurerm_private_endpoint" "key_vault" {
  for_each            = var.key_vault_public_access ? {} : local.key_vault_names
  name                = "pe-${each.value}"
  location            = var.location
  resource_group_name = azurerm_resource_group.shared.name
  subnet_id           = azurerm_subnet.backend[each.key == "platform" ? "shared" : each.key].id
  tags                = local.tags

  private_service_connection {
    name                           = "vault"
    private_connection_resource_id = azurerm_key_vault.this[each.key].id
    subresource_names              = ["vault"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [module.platform.private_dns_zone_ids["key_vault"]]
  }
}

resource "azurerm_monitor_diagnostic_setting" "key_vault" {
  for_each                   = local.key_vault_names
  name                       = "diag-to-law"
  target_resource_id         = azurerm_key_vault.this[each.key].id
  log_analytics_workspace_id = module.platform.log_analytics_workspace_id

  enabled_log {
    category_group = "audit"
  }
  enabled_metric {
    category = "AllMetrics"
  }
}

# One wildcard certificate per zone in the platform vault (section 13). Created as a short-lived self-signed
# placeholder (issuer Self) so that the role assignments below can exist; the renewal job in the management
# network replaces it with the Let's Encrypt certificate (DNS-01) on its first run.
resource "azurerm_key_vault_certificate" "zone_wildcard" {
  for_each     = local.zones
  name         = "cert-${each.key}-wildcard"
  key_vault_id = azurerm_key_vault.this["platform"].id
  tags         = merge(local.tags, { zone = each.key, placeholder = "true" })

  certificate_policy {
    issuer_parameters {
      name = "Self"
    }
    key_properties {
      exportable = true
      key_type   = "EC"
      curve      = "P-256"
      reuse_key  = false
    }
    secret_properties {
      content_type = "application/x-pem-file"
    }
    x509_certificate_properties {
      subject            = "CN=*.${each.key}.${local.env}.${var.dns_domain}"
      validity_in_months = 1
      key_usage          = ["digitalSignature", "keyAgreement"]
      extended_key_usage = ["1.3.6.1.5.5.7.3.1"]
      subject_alternative_names {
        dns_names = ["*.${each.key}.${local.env}.${var.dns_domain}", "*.sl-az1.${each.key}.${local.env}.${var.dns_domain}", "*.sl-az2.${each.key}.${local.env}.${var.dns_domain}", "*.sl-az3.${each.key}.${local.env}.${var.dns_domain}"]
      }
    }
    lifetime_action {
      action {
        action_type = "EmailContacts"
      }
      trigger {
        days_before_expiry = 10
      }
    }
  }

  lifecycle {
    # Owned by the renewal job after the first import
    ignore_changes = [certificate_policy, tags]
  }

  # Data plane through the private endpoint (self-hosted runners in the management VNet) or, in the lab, the
  # public endpoint. The apply identity has Key Vault Administrator on the subscription (stacks/platform-extensions).
  depends_on = [azurerm_private_endpoint.key_vault]
}
