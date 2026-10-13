variable "environment" {
  type        = string
  description = "Environment name: dev, acc or prd."
  validation {
    condition     = contains(["dev", "acc", "prd"], var.environment)
    error_message = "dev, acc or prd."
  }
}

variable "location" {
  type        = string
  description = "Location of the assignments' managed identities and metadata."
}

variable "subscription_id" {
  type        = string
  description = "The environment subscription (sub-aks-<env>) the policies are assigned to."
}

variable "policy_enforcement_mode" {
  type        = string
  default     = "DoNotEnforce"
  description = "Enforcement of the AKS platform's policy assignments: DoNotEnforce (audit) in the build tenant until phase 3, then Default. Compliance is reported in both modes."
  validation {
    condition     = contains(["Default", "DoNotEnforce"], var.policy_enforcement_mode)
    error_message = "Default or DoNotEnforce."
  }
}

variable "container_registry_name" {
  type        = string
  description = "The environment's container registry, for the allowed-images policy. Not part of the landing zone: onek8s/aks-terraform creates it with the clusters (shared/, container_registry_name)."
}

variable "isolation_zones" {
  type        = list(string)
  default     = ["int-fi", "int-se", "ext-fi", "ext-se"]
  description = "The isolation zones (design: requirements, \"Isolation zone\"), as onek8s/aks-terraform's shared/ isolation_zones names them. The zone policies and mutations of kubernetes.tf are made for each."
}

variable "zone_domain_suffix" {
  type        = string
  description = "The environment's domain: zone <zone> publishes its applications' names below <zone>.<zone_domain_suffix> (e.g. ext-fi.dev.onek8s.lol)."
}

variable "stateless_cluster_name_pattern" {
  type        = string
  description = "The names of the environment's stateless clusters, an Azure Policy `like` pattern with at most one `*` (e.g. aks-dev-stateless-*)."
}

variable "stateful_cluster_name_pattern" {
  type        = string
  description = "The name of the environment's stateful cluster, an Azure Policy `like` pattern with at most one `*`."
}

variable "allowed_sku_series" {
  type        = list(string)
  default     = ["Ds_v5", "Ds_v6", "Es_v5", "Es_v6", "Dps_v6", "Eps_v6"]
  description = "VM series (karpenter.azure.com/sku-series) a zone's NAP NodePools may use: amd64 and arm64 series that support Azure Virtual Network encryption (design section 4)."
}
