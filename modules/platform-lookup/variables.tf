variable "location" {
  type        = string
  description = "Region of the platform landing zone (starter_location_01 of accelerator/config/platform-landing-zone.tfvars)."
}

variable "private_dns_zone_names" {
  type        = map(string)
  default     = {}
  description = "Additional hub private DNS zones to look up, key => zone name."
}
