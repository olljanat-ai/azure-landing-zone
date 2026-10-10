output "cluster" {
  description = "The cell's cluster."
  value = {
    id                  = azapi_resource.cluster.id
    name                = local.cluster_name
    kubernetes_version  = local.kubernetes_version
    private_fqdn        = local.cluster_private_fqdn
    oidc_issuer_url     = local.oidc_issuer_url
    node_resource_group = local.node_resource_group
  }
}

output "kubernetes_version_candidates" {
  description = "Newest patch of the minor of this cell's speed (what the version pipeline would choose)."
  value       = local.computed_version
}

output "api_server_private_endpoint_ip" {
  description = "API server address in the management VNet."
  value       = azurerm_private_endpoint.apiserver.private_service_connection[0].private_ip_address
}

output "cluster_vars" {
  description = "Variables handed to Flux (cluster-vars)."
  value       = local.cluster_vars
}
