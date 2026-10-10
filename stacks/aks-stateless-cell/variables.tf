variable "environment" {
  type        = string
  description = "Environment name: dev, acc or prd."
}

variable "cell" {
  type        = string
  description = "Stateless cell = cluster slot: sl-az1, sl-az2 or sl-az3. The cell runs entirely in availability zone <N>."
  validation {
    condition     = contains(["sl-az1", "sl-az2", "sl-az3"], var.cell)
    error_message = "sl-az1, sl-az2 or sl-az3."
  }
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
  description = "Must be the same as in the environment stack."
}

variable "name_suffix" {
  type        = string
  description = "Same name_suffix as the environment stack (Key Vault and ACR names)."
}

variable "dns_domain" {
  type        = string
  description = "Test domain; zone names are <zone>.<env>.<domain> (cluster-vars)."
}

variable "kubernetes_version" {
  type        = string
  default     = null
  description = "Kubernetes version of control plane and system pool, written by the version pipeline (aks-design section 12). null: the newest patch of the minor given by kubernetes_minor_offset."
}

variable "kubernetes_minor_offset" {
  type        = number
  default     = 1
  description = "Update speed when kubernetes_version is null: 1 = second latest GA minor (N-1, sl-az1, fast), 2 = N-2 (sl-az2/sl-az3, slow)."
}

variable "system_pool" {
  type = object({
    vm_size    = optional(string, "Standard_D4ds_v5") # VNet encryption + encryption at host + ephemeral OS disk
    node_count = optional(number, 3)
    max_pods   = optional(number, 110)
  })
  default     = {}
  description = "System node pool: fixed node count, tainted CriticalAddonsOnly, pinned to the cell's AZ (aks-design sections 3 and 4)."
}

variable "pod_cidr" {
  type        = string
  default     = "192.168.0.0/16"
  description = "Overlay pod CIDR; the same in every stateless cluster, outside all VNet and on-premises prefixes."
}

variable "service_cidr" {
  type    = string
  default = "172.16.0.0/16"
}

variable "dns_service_ip" {
  type    = string
  default = "172.16.0.10"
}

variable "admin_group_object_ids" {
  type        = list(string)
  default     = []
  description = "Entra ID groups with cluster admin (Azure RBAC for Kubernetes); in acc/prd only through PIM."
}

variable "defender_enabled" {
  type        = bool
  default     = true
  description = "Defender for Containers sensor in the cluster."
}

variable "fleet" {
  type = object({
    kind       = optional(string, "GitRepository") # GitRepository while prototyping, OCIRepository (environment ACR) later
    url        = string
    branch     = optional(string, "main")
    tag        = optional(string) # OCIRepository: <env>-<cell> (one tag per cell, aks-design section 10)
    path       = optional(string) # default ./clusters/<env>/<cell>
    sync_every = optional(number, 600)
  })
  default     = null
  description = "Fleet repository reconciled by the GitOps extension (Flux). null: install Flux without configuration."
}

variable "tags" {
  type    = map(string)
  default = {}
}
