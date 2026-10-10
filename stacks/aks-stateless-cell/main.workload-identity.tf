# Federated credentials (aks-design section 6): every cluster has its own OIDC issuer, so every identity of the
# environment that is used from a cluster gets one credential per cluster. A rebuilt cell gets a new issuer and
# replaces its credentials. Max 20 per identity: 3 cells + stateful cluster per environment.
resource "azurerm_federated_identity_credential" "cell" {
  for_each  = local.workload_identities
  name      = local.cluster_name
  parent_id = each.value.id
  audience  = ["api://AzureADTokenExchange"]
  issuer    = local.oidc_issuer_url
  subject   = "system:serviceaccount:${each.value.namespace}:${each.value.service_account}"
}
