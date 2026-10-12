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
