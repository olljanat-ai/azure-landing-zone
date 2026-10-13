# AKS policy assignments of dev (OneK8s design section 14), stacks/aks-policy
environment     = "dev"
location        = "swedencentral"
subscription_id = "3b9f032a-0165-4b8c-9e1e-d7a664c661a8" # sub-aks-dev

# DoNotEnforce until phase 3 (acceptance testing), then Default – together with policy_enforcement_mode in
# accelerator/config/platform-landing-zone.tfvars and environments/dev/environment.tfvars
policy_enforcement_mode = "DoNotEnforce"

# The environment's container registry: created by onek8s/aks-terraform (shared/envs/dev.tfvars)
container_registry_name = "acronek8sdev"

# The environment's Key Vaults, <prefix>-<zone> and <prefix>-platform (onek8s/aks-terraform shared/envs/dev.tfvars)
key_vault_name_prefix = "kv-onek8s-dev"

# The platform's own Kubernetes policies (stacks/aks-policy/kubernetes.tf): the zones' domain and which
# clusters are stateless or stateful, as onek8s/aks-terraform names them (envs/*.tfvars)
zone_domain_suffix          = "dev.onek8s.lol"
cluster_resource_group_name = "rg-aks-dev"
stateless_cluster_names     = ["aks-dev-stateless-az1", "aks-dev-stateless-az2"]
stateful_cluster_name       = "aks-dev-stateful"

# Promoted from Audit to Deny (design section 14: audit first, then deny, rule by rule): every rule
# here reported no violation on aks-dev-stateless-az1 (2026-10-13, Cluster status, constraints audited
# after the new rules were applied), and the isolation tests' forbidden manifests check that each now
# refuses. Still in Audit, with the reason:
#   zone-placement                   aks-hello's lab cost exception (system pool) is reported by design
#   k8s-pod-security-restricted      App Routing's gateway pods set no seccomp profile (AKS-managed)
#   k8s-deployment-safeguards        probes / seccomp / images of AKS-managed and upstream platform pods
#   k8s-allowed-images               ESO, external-dns and Flux images come from upstream registries
#   k8s-no-service-account-token-automount, k8s-internal-load-balancers (the external zones' gateways
#   are public by design), k8s-image-integrity (preview, audit only)
kubernetes_deny = [
  # The platform's own validations
  "fqdn-egress",
  "gateway-only",
  "node-pools",
  "placement-labels",
  "placement-labels-stateful",
  "secrets-via-eso",
  "eso-objects",
  "service-accounts",
  "rollout-guardrails",
  "rollout-guardrails-stateful",
  "vertical-pod-autoscalers",
  "vertical-pod-autoscalers-stateful",
  # Built-in Kubernetes definitions
  "k8s-no-ingress",
  "k8s-read-only-root-filesystem",
]
