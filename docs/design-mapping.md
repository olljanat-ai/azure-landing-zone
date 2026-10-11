# How the code implements the OneK8s design

Requirements from [docs/requirements.md](https://github.com/onek8s/onek8s.github.io/blob/main/docs/requirements.md)
and where this repository implements them. "Fleet" means the fleet repository with the in-cluster state
(OneK8s design section 10), which is not part of the landing zone.

| # | Requirement | Implemented in | Status |
|---|---|---|---|
| R1 | Control plane in a dedicated network | `stacks/aks-stateless-cell/main.cluster.tf` (private, API Server VNet Integration, delegated `snet-apiserver`), `main.api-access.tf` (Private Link Service → private endpoint in the management VNet, NSG on `snet-aks-api-pe`) | Built, smoke-tested by the AKS cell workflow |
| R2, R3 | int / ext and country isolation | `modules/address-plan`: one `/17` per zone, one `/20` per zone and cluster | Built |
| R4 | Key Vault + network + nodes per zone | Zone vaults (`stacks/aks-environment/main.keyvault.tf`), zone subnets, NSGs and route tables (`main.network.tf` of both stacks); zone NAP `NodePool`s from the fleet with the subnet IDs in `cluster-vars` | Network and vaults built; NodePools: fleet |
| R5 | Only Kubernetes-mandatory flows between zones | NSGs with the flows of section 5 (`stacks/aks-stateless-cell/main.network.tf`), per-zone UDRs to the Firewall incl. one route per other zone, Firewall rules with zone IP groups (`stacks/platform-extensions/main.firewall.tf`); Cilium policies: fleet | Built (NSG, Firewall) |
| R6 | Namespace + network policies | Fleet | – |
| R7, R7a, R7b | Key Vault RBAC + ABAC, workload identity, ESO only | `stacks/aks-environment/main.identities.tf` (reader identities, ABAC on `<app>-`, per-certificate roles), federated credentials per cell (`main.workload-identity.tf`), Secrets Store CSI add-on disabled, workload identity enabled | Built; ESO: fleet |
| R8, R8a, R9 | Stateless + optional stateful cluster in the backend network | Backend spoke `vnet-<env>-sf` exists from day one with the private endpoints (the ACR is aks-terraform's); the stateful cluster is not built (no approved workload) | Backend built; stateful module: later |
| R9b | Overlay CNI, Cilium, TLS-only Gateway API | Azure CNI Overlay + Cilium, VNet encryption on every cell VNet, HTTPS-only NSGs on `snet-<zone>-ilb`; Traefik: fleet | Built (network part) |
| R10 | Stateful cluster zone-redundant + LTS | – | Later, with the first exception |
| R11 | One cluster per AZ, NAP | `environments/dev/sl-az1.tfvars`, `sl-az2.tfvars`; system pool pinned to the AZ, `nodeProvisioningProfile` Auto with no default NodePools | Built |
| R12, R12a | Automated zero-downtime upgrades, two speeds | Auto-upgrade channels `none`; `kubernetes_minor_offset` 1 (sl-az1) / 2 (sl-az2) picks N-1 / N-2 until the version pipeline writes explicit versions; cells applied one after another | Speeds built; version pipeline: phase 2 |
| R13 | dev, acc, prd in sync | Same stacks with one tfvars set per environment; dev only in the build tenant | dev built |
| R14 | One policy engine | Azure Policy add-on on every cluster; ALZ initiatives (`platform/`) and AKS assignments per environment subscription (`stacks/aks-environment/main.policy.tf`), all following `policy_enforcement_mode` | Built (built-ins); custom `Microsoft.Kubernetes.Data` definitions: phase 2 |
| R15 | Certificates through the platform Key Vault | `kv-<env>-platform-<suffix>`, one `cert-<zone>-wildcard` placeholder per zone, Secrets User per certificate for `id-<zone>-gateway-secrets` | Built; renewal job: phase 2 |
| R16 | Countries added online | `countries` map: a new country adds address spaces, subnets, route-table routes, IP groups and vaults without touching existing zones (test `new_country_does_not_move_existing_zones`) | Built |
| R17 | amd64 / arm64, on-demand / spot | NAP enabled; NodePools and Azure Policy mutations: fleet / phase 2 | – |
| R18 | AI-driven day 2 operations | Plan identities are read-only; every write goes through a workflow with an apply environment | Partly; agents: phase 2 |
| R19 | ACNS + eBPF host routing | `advancedNetworking` with observability, FQDN security and `accelerationMode: BpfVeth`; Azure Linux 3 system pool | Built, smoke-tested |
| R20 | FQDN egress per application | ACNS FQDN policies enabled; zone allow-lists `zone_fqdn_allow_lists` in the Firewall; application policies: fleet | Platform part built |
| R21 | Customer-managed keys | `key-<cell>-kms` (KMS, private vault) and `key-<cell>-disk` (disk encryption set) per cell in the platform vault, encryption at host, no key expiry, rotation policy, `CanNotDelete` lock and purge protection on the vault | Built |

## Decisions taken while building, to confirm in phase 2

These follow from building the design on the ALZ accelerator; each is a candidate design change or an open
question answered by experiment.

1. **One private endpoint per Key Vault, in the backend spoke.** The design places a private endpoint to the
   platform vault and the zone vaults in every cluster spoke. With the hub private DNS zones (one
   `privatelink.vaultcore.azure.net` for everything, as ALZ sets up), several endpoints of the same vault would
   overwrite each other's DNS record. The build therefore has one endpoint per vault in `vnet-<env>-sf`
   (zone vaults in `snet-<zone>-pe`, the platform vault in `snet-shared-pe`), reached through the
   Firewall with the zone rule "frontend zone X → backend zone X" – the zone separation of flow ⑤ is kept by the
   Firewall and the NSGs. The cell subnets `snet-<zone>-pe` and `snet-platform-pe` stay reserved.
2. **Pod-to-pod NSG rule.** With Azure CNI Overlay, pod traffic between nodes keeps the overlay pod IPs, which the
   NSGs cannot attribute to a zone. Node-subnet NSGs therefore allow the pod CIDR; zone separation between pods is
   enforced by Cilium (the third layer of section 5), while node-level traffic between zones is still denied by
   NSG and Firewall.
3. **KMS with a private vault and custom DNS.** The cell VNets use the Firewall DNS proxy. Whether AKS's own
   private endpoint and DNS for KMS work in that setup is to be confirmed (open question in section 18:
   "in which subnet AKS places the private endpoint").
4. **Flux on the system pool.** The GitOps extension is configured with the toleration key `CriticalAddonsOnly`
   (`toleration-keys`), so Flux runs on the system pool and never on zone nodes. Confirm the setting with the
   extension version in use.
5. **API server DNS for the management VNet.** A private DNS zone per cluster (`<rest of the private FQDN>`) in
   `rg-aks-<env>-api-access-<region>` points the private FQDN to the private endpoint in `snet-aks-api-pe`. It is
   linked to the hub VNet because the management VNet resolves through the Firewall DNS proxy.
6. **Deployment identities in sub-mgmt.** Like the accelerator's own identities, the AKS environment identities
   live in `sub-mgmt`, so rebuilding `sub-aks-dev` from an empty subscription (phase 3) keeps the deployment path.
   The apply identity is Owner of `sub-aks-dev` in the build tenant; the least-privilege roles are derived in
   phase 2 like those of the agents.

7. **Sandbox network mode.** `network-mode.tfvars` can switch the whole tenant to a mode without Azure Firewall
   for labs and early prototyping (direct peerings, NSGs, NAT gateways; see
   [deployment](deployment.md#network-mode-firewall-or-sandbox)). It weakens R5 to two layers (NSG + Cilium) and
   gives nodes open Internet egress, so it is not used for acceptance.

## Not built yet (phase 2 backlog)

- Fleet repository: NAP `NodePool` / `AKSNodeClass` per zone, Traefik + Gateways, External Secrets Operator per
  zone, Cilium baseline and FQDN policies. Set `fleet` in `environments/dev/sl-az*.tfvars` when it exists.
- Front Door origin groups per cell (Private Link origins on the Traefik internal load balancers, which the fleet
  creates) and the NGINXaaS configuration (`nginxaas_enabled`).
- Certificate renewal job (Let's Encrypt DNS-01) in the management network and the public validation zone.
- The platform's custom Azure Policy definitions for Kubernetes (zone pinning, FQDN egress, ESO-only secrets,
  Gateway API only, NAP NodePool validation) with `gator verify` in CI.
- Version pipeline (section 12), Azure Monitor Private Link Scope, Managed Prometheus / Grafana.
- Stateful cluster module (only when the first exception is approved).
