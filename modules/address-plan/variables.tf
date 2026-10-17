variable "environment" {
  type        = string
  description = "Environment name: dev, acc or prd."
  validation {
    condition     = contains(keys(var.environment_indexes), var.environment)
    error_message = "environment must be one of the keys of environment_indexes."
  }
}

variable "base_prefix" {
  type        = string
  default     = "10.0.0.0/8"
  description = "Prefix the environment /12s are taken from (OneK8s design section 3.1: dev 10.16.0.0/12, acc 10.32.0.0/12, prd 10.48.0.0/12)."
}

variable "environment_indexes" {
  type        = map(number)
  default     = { dev = 1, acc = 2, prd = 3 }
  description = "Index of each environment's /12 inside base_prefix."
}

variable "countries" {
  type        = map(number)
  default     = { fi = 1, se = 2 }
  description = "Countries and the index of their /16 inside the environment /12 (index 0 is the platform /16). Adding a country adds two isolation zones."
  validation {
    condition     = alltrue([for k, v in var.countries : v > 0 && v < 16 && can(regex("^[a-z]{2}$", k))])
    error_message = "Country codes are two lowercase letters with an index 1-15."
  }
}
