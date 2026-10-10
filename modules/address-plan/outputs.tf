output "environment_prefix" {
  description = "The environment /12."
  value       = local.environment_prefix
}

output "platform_prefix" {
  description = "The platform /16 holding the control plane zone of every cluster."
  value       = local.platform_prefix
}

output "country_prefixes" {
  description = "Country code => /16."
  value       = local.country_prefixes
}

output "zones" {
  description = "Isolation zone => prefix (/17), frontend and backend /18, one /20 per slot."
  value       = local.zones
}

output "control_plane" {
  description = "Slot => control plane zone /20."
  value       = local.control_plane
}

output "cells" {
  description = "Stateless cell slot (sl-az1..3) => address spaces and subnet prefixes of its VNet."
  value       = local.cells
}

output "backend" {
  description = "Address spaces and subnet prefixes of the backend spoke vnet-<env>-sf."
  value       = local.backend
}

output "edge" {
  description = "Address spaces and subnet prefixes of the edge VNet vnet-<env>-edge."
  value       = local.edge
}
