variable "environment" {
  type        = string
  description = "Environment name: dev, acc or prd (aks-design section 9)."
}

variable "location" {
  type    = string
  default = "swedencentral"
}

variable "subscription_id" {
  type        = string
  description = "Environment subscription (sub-aks-<env>)."
}

variable "platform_subscription_ids" {
  type        = map(string)
  description = "management (sub-mgmt) and connectivity (sub-hub) subscription IDs."
}

variable "countries" {
  type        = map(number)
  default     = { fi = 1, se = 2 }
  description = "Countries and their /16 index (modules/address-plan). Adding one adds the zones int-<cc> and ext-<cc> online."
}

variable "name_suffix" {
  type        = string
  description = "Short suffix that makes the globally unique names (Key Vaults, ACR) unique, e.g. 'x7k2'."
  validation {
    condition     = can(regex("^[a-z0-9]{2,5}$", var.name_suffix))
    error_message = "2-5 lowercase letters or digits."
  }
}

variable "dns_domain" {
  type        = string
  description = "Registered test domain of the build tenant (platform_dns_domain); zone names are <zone>.<env>.<domain>."
}

variable "policy_enforcement_mode" {
  type        = string
  default     = "DoNotEnforce"
  description = "Enforcement of the AKS platform's policy assignments: DoNotEnforce (audit) in the build tenant until phase 3, then Default."
  validation {
    condition     = contains(["Default", "DoNotEnforce"], var.policy_enforcement_mode)
    error_message = "Default or DoNotEnforce."
  }
}

variable "front_door_enabled" {
  type        = bool
  default     = false
  description = "Azure Front Door Premium with a WAF policy per external zone (cell router for ext-* zones, aks-design section 8). Premium only: the Private Link origins and the managed WAF rule sets need it. Off in the lab until the external zones are tested (~330 USD/month base fee)."
}

variable "key_vault_sku" {
  type        = string
  default     = "standard"
  description = "SKU of the zone and platform Key Vaults. premium: HSM-protected cluster keys (RSA-HSM, open question in the design); standard (lab): software-protected keys."
  validation {
    condition     = contains(["standard", "premium"], var.key_vault_sku)
    error_message = "standard or premium."
  }
}

variable "container_registry" {
  type = object({
    name                = string
    resource_group_name = string
  })
  description = "The environment's container registry. Not part of the landing zone: onek8s/aks-terraform creates it with the clusters (shared/, container_registry_name). Only its name is used here, for the allowed-images policy."
}

variable "nginxaas_enabled" {
  type        = bool
  default     = false
  description = "F5 NGINXaaS deployment per internal zone in the edge VNet (open question: partner service). The delegated subnets always exist."
}

variable "applications" {
  type = map(object({
    zone               = string
    needs_secrets      = optional(bool, false) # Key Vault secret exception: reader identity with ABAC on <app>-*
    needs_certificate  = optional(bool, false) # cert-<zone>-wildcard through ESO (TLS-terminating apps)
    secret_officer_ids = optional(list(string), [])
  }))
  default     = {}
  description = "Onboarded applications (aks-design section 6): name => zone and exceptions. Creates id-<zone>-<app> and, when needed, id-<zone>-<app>-secrets."
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "network_mode" {
  type        = string
  default     = "firewall"
  description = "firewall (design) or sandbox (no Azure Firewall: direct peerings, NSGs, NAT gateways) – network-mode.tfvars."
  validation {
    condition     = contains(["firewall", "sandbox"], var.network_mode)
    error_message = "firewall or sandbox."
  }
}
