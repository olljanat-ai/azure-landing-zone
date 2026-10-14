# How the code implements the OneK8s design

Requirements from [docs/requirements.md](https://github.com/onek8s/onek8s.github.io/blob/main/docs/requirements.md)
and where the code implements them. Four repositories share the work:

| Repository | Role |
|---|---|
| **azure-landing-zone** (this one) | Build tenant, management groups, ALZ policy, hub, management and client VNets, deployment identities, the AKS policy assignments (`stacks/aks-policy`) |
| [aks-terraform](https://github.com/onek8s/aks-terraform) | The clusters and what an environment's clusters share: the cells' networks and NSGs, the platform and zone Key Vaults, customer-managed keys, private DNS, Traffic Manager, the container registry |
| [aks-fluxcd-platform](https://github.com/onek8s/aks-fluxcd-platform) | What Flux deploys into every cluster: the isolation zones' gateways, External Secrets Operators and Cilium policies, NAP NodePools, external-dns |
| [aks-fluxcd-example](https://github.com/onek8s/aks-fluxcd-example) | An application team's repository |

| # | Requirement | Implemented in | Status |
|---|---|---|---|
| R1 | Control plane in a dedicated network | aks-terraform: Entra ID with Azure RBAC, local accounts disabled | **Lab exception**: the dev API servers are public (authorized ranges, Entra ID only), because the lab has no network path into the cells; private API server + API Server VNet Integration are inputs of the module |
| R2 | int / ext isolation by subscription and cluster (D52) | `exposure` (`int`/`ext`) in aks-terraform's root module and `shared/` and in `stacks/aks-policy`, validated: every zone, namespace and policy of a subscription is of its exposure; aks-fluxcd-platform `clusters/dev-ext-*`, `node-pools/{internal,external}`, `external-dns/internal`; the Isolation tests' R2 step (one exposure per cluster and subscription) | Built for `ext`: `sub-aks-dev` plays `sub-aks-dev-ext`, only `aks-dev-ext-stateless-az1` runs; no internal subscription in the build tenant |
| R3 | Country isolation (node pool + network) | aks-terraform `shared/` `isolation_zones`: per cell one /24 per zone (nodes, internal load balancer), own NSG and vault; aks-fluxcd-platform `infrastructure/zones` | Built |
| R4 | Key Vault + network + nodes per zone | aks-terraform `shared/`: a vault per zone (`zone_key_vault_names`), a node and ILB subnet with its own NSG per zone and cell; aks-fluxcd-platform: a NAP `AKSNodeClass` per zone in its own subnet | Built |
| R5 | Only Kubernetes-mandatory flows between zones | NSGs per subnet (aks-terraform `shared/cells.tf`, the flows of section 5); Cilium baseline per zone (aks-fluxcd-platform `infrastructure/zones/cilium.yaml`) | Built (NSG + Cilium); no Firewall in the lab's `sandbox` network mode. Design D53 (2026-10-14) puts a hub VNet and Azure Firewall per exposure with no route between them; `stacks/platform-extensions/main.firewall.tf` still builds one rule collection group per environment with both exposures in one `frontend` IP group and the removed NGINXaaS edge rules - rewrite it before `firewall` mode is used |
| R6 | Namespace + network policies | Managed namespaces with `AllowSameNamespace` default policies (aks-terraform), the zone's `CiliumClusterwideNetworkPolicy` baseline; who may work in a namespace (D49): `managed_namespaces.<ns>.groups` binds an Entra ID group each to ClusterRole `view`, `edit` and `admin` (RoleBindings `platform-<role>` from aks-fluxcd-platform `infrastructure/namespace-access`, applied by a Flux configuration `<ns>-access`) plus `AKS Namespace User` on the namespace, and on the namespace's Key Vault share `admin` Key Vault Secrets Officer and `edit` the custom Key Vault Secrets Editor (write and update, attributes, no value, no delete - D51, defined at the resource group) under `<ns>--`, `view` nothing (aks-terraform `shared/` `key_vault_namespaces.<ns>.groups`); soft multi-tenancy (D50): no tenant lists namespaces or a vault (the ABAC conditions gate `readMetadata`), platform viewers (`shared/` `platform_viewer_group_object_ids`) list both through a custom role defined and assignable at the resource group; Isolation tests check them by impersonation and as tester applications, in the cluster and in the vault | Built |
| R7, R7a, R7b | Key Vault RBAC + ABAC, workload identity, ESO only | aks-terraform: a reader identity per namespace with an ABAC condition on `<namespace>--`, federated per cluster, Secrets Store CSI add-on stated off; aks-fluxcd-platform: one External Secrets Operator per zone (`controllerClass`), the platform's for platform namespaces; `stacks/aks-policy` `secrets-via-eso` (in a zone's namespaces only its ESO writes Secrets), `eso-objects` (SecretStores azurekv with workload identity on the zone's or platform vault, ExternalSecrets only on the namespace's `<namespace>--` keys, no PushSecret) and `service-accounts` (no pod as `key-vault`, no pull secrets), all **deny** | Built; ESO's RBAC is still cluster-wide (open question) |
| R8, R8a, R9 | Stateless + optional stateful cluster | The stateless cells are built; `envs/dev-ext-stateful.tfvars` defines a stateful cluster, not deployed | Stateful: later, with the first exception |
| R9b | Overlay CNI, Cilium, TLS-only Gateway API | Azure CNI Overlay + Cilium, VNet encryption on every cell VNet; a Gateway per zone (AKS App Routing, class `approuting-istio`) with HTTPS only (no port 80), NSGs allow 443 only | Built |
| R10 | Stateful cluster zone-redundant + LTS | – | Later |
| R11 | One cluster per AZ, NAP | `aks-dev-ext-stateless-az1` / `-az2`, system pool in one AZ, NAP with no default NodePools, zone NodePools on-demand and spot that scale to zero (the zones' gateways and ESOs run on the system pool); VPA add-on with `InPlaceOrRecreate`; `stacks/aks-policy` `rollout-guardrails` (≥ 2 replicas spread over nodes, `maxUnavailable: 0`, PDBs that allow a drain; 3 over zones in the stateful cluster) and `vertical-pod-autoscalers` (in place or off, requests only, `maxAllowed`), deny | Built; az2 is destroyed while not needed and rebuilt from its tfvars |
| R12, R12a | Automated zero-downtime upgrades, two speeds | Auto-upgrade channels `none` / `None`, every cell on 1.36 | Version pipeline: phase 2 (aks-ai-agents) |
| R13 | dev, acc, prd in sync | Same modules with one tfvars set per environment; dev only in the build tenant | dev built |
| R14 | One policy engine | Azure Policy add-on on every cluster; `stacks/aks-policy`: built-ins in audit, and the platform's own `Microsoft.Kubernetes.Data` definitions (`kubernetes.tf`, templates in `kubernetes/`, tested with `gator` in CI): storage, zone pinning, architecture, spot and GPUs, FQDN egress, Gateway API only, NAP NodePools (with each zone's GPU pool), namespace ownership (`platform/team`, `platform/cost-center`, `platform/contact`); image signatures: every image the registry builds is signed by aks-terraform's Sign images workflow (certificate `image-signing` in the platform vault) and checked at admission by AKS Image Integrity (Ratify, `k8s-image-integrity`, configured from aks-fluxcd-platform `infrastructure/image-verification`) | Built. Deny: the storage rules, FQDN egress, Gateway only, NodePools, placement labels, namespace ownership, ESO-only secrets and ESO objects, service accounts, rollout guardrails, VPAs, no Ingress, read-only root filesystem (`kubernetes_deny` in `environments/dev/policy.tfvars`, each promoted after zero violations on the running cell). Audit, with the reason in that file: zone placement (aks-hello's lab exception), pod security *restricted*, deployment safeguards and allowed images (AKS-managed and upstream platform pods), automount, internal load balancers, Image Integrity (preview). The mutations are on |
| R15 | Certificates through the platform Key Vault | One wildcard per zone (`<zone>-gateway--wildcard`) and one for the platform gateway in the platform vault, issued by aks-terraform's Renew Certificate workflow, read by each gateway's own identity | Built |
| R16 | Countries added online | A new zone is a new index in `isolation_zones` (new subnets, NSGs, vault) and a `zone-<zone>` Kustomization; existing zones are untouched | Built |
| R17 | amd64 / arm64, on-demand / spot, GPUs | NAP NodePools per zone with both architectures and spot, and a GPU NodePool per zone (`<zone>gpu`: NVIDIA H100 v5, on-demand, amd64, AKS's managed GPU stack, decision D42); `stacks/aks-policy` mutations turn the pod labels `platform/arch`, `platform/capacity` and `platform/accelerator` into the architecture selector, the spot toleration and preference and the GPU toleration, and put pods of `<zone>-*` on their zone's nodes; validations refuse placement stated any other way, a GPU request without the label and the label without a GPU request (deny) | Built; no GPU node created yet (the subscription's H100 quota starts at 0) |
| R18 | AI-driven day 2 operations | aks-ai-agents | Phase 2 |
| R19 | ACNS + eBPF host routing | aks-terraform `advanced_networking`: Hubble, FQDN policies, `BpfVeth`; Azure Linux 3.0 on every node | Built |
| R20 | FQDN egress per application | ACNS FQDN policies; the zone baseline denies all egress but cluster DNS; the application's `egress` policy; `check-egress.py` against the zone's allow-list in the team's CI; `stacks/aks-policy` `fqdn-egress` at admission (no CIDRs, entities or broad wildcards, DNS rules only for declared names, cluster DNS only) | Built; admission in audit until phase 3 |
| R21 | Customer-managed keys | aks-terraform `customer_managed_keys`: `key-<cluster>-kms` (KMS) and `key-<cluster>-disk` (disk encryption set) per cluster in the platform vault, encryption at host on every node | Built |
| R24 | Health probes and `/healthz` | aks-fluxcd-example: aks-hello's readiness and liveness probes on `/healthz`; aks-terraform `global_hostnames.health_path = "/healthz"`: Traffic Manager probes it over HTTPS through each cell's gateway; `stacks/aks-policy` deployment safeguards (probes) in audit; the Isolation tests check `/healthz` per cell and on the global name | Built; probes enforced (deny) and synthetic monitoring: phase 2 |

## Requirement tests

aks-terraform's **Isolation tests** workflow is the pipeline stage of design section 17 ("Requirement and isolation
tests"): after every apply of a stateless cell, every weekday, and by hand. Each check names the requirement it
covers (the run's summary is the table): R1–R8, R9b, R11–R17, R19, R20, R21 and R24 have automated checks - R7 with
a token for the namespace's own identity (its secret 200, another application's and another zone's 403), R7a with
every role assignment of the application identities, R11 the cell's AZ, NAP and VPA and the rollout guardrails, R13
Flux at the head of Git and every cell's tfvars and fleet directory equal but for name and AZ, R15 the certificate
from the vault to every listener, R16 every zone complete; R14 including the supply chain (registry access, Ratify,
every image's signature, the policy reporting an unsigned image, the Flux webhook's signature check). R9/R10
(stateful cluster), R18 and R22/R23 have none yet. Forbidden manifests refused by a rule still in audit are
reported as *audit only*.

## Changed while building, to confirm in phase 2

1. **Traffic Manager instead of Front Door.** External applications are published on a public load balancer of
   their zone's gateway in every cell, with one Azure Traffic Manager profile per external hostname
   (design section 8). Traffic Manager is DNS only: no WAF and no client-IP affinity.
2. **Namespace = application, and its share of a vault is `<namespace>--`.** A zone's application namespace is
   `<zone>-<app>`; its reader identity's ABAC condition is on the namespace's prefix, and the gateways'
   certificates are `<zone>-gateway--wildcard`, read under the same condition rather than a role per certificate.
3. **The cells' networks are not peered to the hub.** In the lab's `sandbox` mode each cell is a network of its
   own with load balancer egress; the Firewall mode (UDRs to the hub Firewall) is not built for the
   aks-terraform cells yet.
4. **Pod-to-pod NSG rule.** With Azure CNI Overlay, pod traffic between nodes keeps the overlay pod IPs, which
   the NSGs cannot attribute to a zone. Node-subnet NSGs therefore allow the pod range; zone separation
   between pods is enforced by Cilium.
5. **The platform's own Kubernetes rules enforce in the build tenant.** The stateless clusters' "no persistent
   storage" rule denies (it replaced a ValidatingAdmissionPolicy that refused the same), the placement mutations
   are on (they refuse nothing), and each platform validation and Kubernetes built-in that the running cell
   reported no violation of was promoted to deny (`kubernetes_deny`), ahead of phase 3; the rest - and every
   corporate and Azure resource assignment - audits, as section 17 says.

## Not built yet (phase 2 backlog)

- The backend network with the PaaS private endpoints, the edge network for the internal zones' entry points,
  and private endpoints for the vaults (all vaults are reached over their public endpoints with Entra ID).
- Requirement tests for what the Isolation tests do not cover yet: the image promotion tests (dev has one registry; its signatures are tested), the API server reachable only from the
  management VNet (after the lab's public API server goes), cross-cell tests while two cells run.
- The CI checks of design section 14 on rendered manifests (a PDB and a VPA for every Deployment).
- The version pipeline (section 12), observability (section 19), backups (section 20).
- The stateful cluster (only when the first exception is approved).
- A hub VNet and Azure Firewall Premium per exposure (design D53): the external hub in `firewall` mode first, the
  internal hub (gateway, resolver, Bastion, client VNet) with `sub-aks-dev-int`; the management VNet peered to both;
  `main.firewall.tf` rewritten as a parent Firewall Policy with a child per exposure, without the edge / NGINXaaS rules.
  IPv6 (design D54): not planned.
