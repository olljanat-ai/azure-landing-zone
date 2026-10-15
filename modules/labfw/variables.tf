variable "location" {
  type = string
}

variable "resource_group_name" {
  type        = string
  description = "Resource group the module creates for the labfw VM, NIC, NSG, public IP and identity."
}

variable "name_prefix" {
  type        = string
  default     = "labfw"
  description = "Resource names <prefix>-fw, <prefix>-fw-nic, ... - the names onek8s/azure-lab-fw's operations workflows (upgrade-lab, view-logs, e2e-lab, power-lab, vpn-peer) look for."
}

variable "hub_virtual_network" {
  type = object({
    id                  = string
    name                = string
    resource_group_name = string
  })
  description = "The hub VNet: snet-labfw is added to it."
}

variable "subnet_prefix" {
  type        = string
  description = "snet-labfw inside the hub address space; labfw gets the subnet's first usable address (.4)."
}

variable "policy_id" {
  type        = string
  description = "The Firewall Policy labfw enforces (with its base policy)."
}

variable "trusted_prefixes" {
  type        = list(string)
  description = "Prefixes routed through labfw (hub and spokes): its DNS proxy clients and the NSG's inbound allow."
}

variable "vm_size" {
  type    = string
  default = "Standard_B2ats_v2"
}

variable "arch" {
  type    = string
  default = "x64"
  validation {
    condition     = contains(["x64", "arm64"], var.arch)
    error_message = "x64 or arm64 (must match vm_size)."
  }
}

variable "os_disk_type" {
  type    = string
  default = "Standard_LRS"
}

variable "admin_ssh_public_key" {
  type        = string
  description = "Provisioning key only: the VM is managed with Run Command, its NSG has no SSH rule."
}

variable "release_version" {
  type        = string
  description = "labfw GitHub release tag, e.g. v0.2.0."
}

variable "release_repo" {
  type    = string
  default = "onek8s/azure-lab-fw"
}

variable "dns_proxy" {
  type        = bool
  default     = true
  description = "Run labfw's DNS proxy even when the policy does not enable it (dns.forceEnable)."
}

variable "vpn" {
  type = object({
    enabled         = optional(bool, false)
    address         = optional(string, "10.0.12.1/24")
    listen_port     = optional(number, 51820)
    source_prefixes = optional(list(string), ["Internet"])
    client_routes   = optional(list(string), [])
    # SNAT the clients' traffic to private destinations to labfw's address: private endpoints answer the source
    # directly, ignoring route tables, so without it their answers to the pool get lost
    snat_to_private = optional(bool, true)
    peers = optional(list(object({
      name        = string
      public_key  = string
      allowed_ips = list(string)
    })), [])
  })
  default     = {}
  description = "WireGuard VPN for agent and management machines outside Azure (labfw `vpn`)."
}

variable "reader_scopes" {
  type        = list(string)
  description = "Scopes where labfw's identity gets Reader: the policies, their IP groups and the service tags (the connectivity subscription)."
}

variable "operator_principal_ids" {
  type        = list(string)
  default     = []
  description = "Principals (e.g. onek8s/azure-lab-fw's OIDC app) that get Virtual Machine Contributor on the labfw resource group, for its Run Command based operations workflows."
}

variable "tags" {
  type    = map(string)
  default = {}
}
