variable "location" {
  type        = string
  description = "Region of the platform landing zone (starter_location_01 of accelerator/config/platform-landing-zone.tfvars)."
}

variable "private_dns_zone_names" {
  type        = map(string)
  default     = {}
  description = "Additional hub private DNS zones to look up, key => zone name."
}

variable "network_mode" {
  type        = string
  default     = "firewall"
  description = "firewall: the hub Azure Firewall exists and is looked up; sandbox: no Firewall (network-mode.tfvars)."
  validation {
    condition     = contains(["firewall", "sandbox"], var.network_mode)
    error_message = "firewall or sandbox."
  }
}
