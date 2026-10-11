# Deploying the build tenant and the dev environment

This is phase 1 (Foundation) of the [implementation project](https://github.com/olljanat-ai/aks-design/blob/main/docs/17-implementation-project-and-acceptance-testing.md):
build tenant, management and hub, `sub-aks-dev`, pipelines with OIDC, Azure Policy in audit mode and the client
VNet. **Exit criterion: a stateless cell can be created and deleted by the pipeline** (step 8).

```text
 step 2  Deploy-Accelerator (alz_local)  ──► state storage + plan/apply identities, federated with GitHub
 step 6  workflow "Platform"             ──► platform/ (ALZ: management groups, policy, management, hub)
                                          └► stacks/platform-extensions (management VNet + runners, client VNet,
                                             Firewall rules, AKS deployment identities)
 step 7  workflow "AKS dev"              ──► stacks/aks-environment (environments/dev/environment.tfvars)
                                          └► stacks/aks-stateless-cell sl-az1, then sl-az2
 step 8  workflow "AKS cell"             ──► create / delete one cell + smoke test
```

## Network mode: firewall or sandbox

One flag in [`network-mode.tfvars`](../network-mode.tfvars) decides how the networks are connected. Switch it
with the script – it also sets `primary_firewall_enabled` in the accelerator configuration and regenerates
`platform/`; CI fails if the two disagree:

```bash
scripts/set-network-mode.sh sandbox   # or: firewall
git add -A && git commit -m "Network mode sandbox" && git push
```

| | `firewall` (the design) | `sandbox` (lab / prototype) |
|---|---|---|
| Azure Firewall | in the hub (Standard in the lab, Premium in the design), DNS proxy, rule collection groups per zone | not deployed |
| Routing | every subnet: `0.0.0.0/0` and the other zones' address spaces → Firewall; spokes peered to the hub only | no route tables; direct peerings: cells ↔ backend, cells ↔ edge, management ↔ backend, client ↔ edge (plus hub peerings for DNS) |
| Zone isolation | NSG + Firewall + Cilium | NSG + Cilium – the same deny-by-default NSGs are the only network boundary |
| Internet egress | Firewall FQDN allow-lists, AKS outbound type `userDefinedRouting` | NAT gateways (cells: zonal in the cell's AZ, AKS outbound type `userAssignedNATGateway`; management VNet only with runners or the jump host, client VNet only with the test client); nodes have open egress, pods are still limited by Cilium FQDN policies |
| DNS | Firewall DNS proxy | Azure DNS; each stack links its VNets to every hub private DNS zone |
| Cost | the Firewall is the largest fixed cost of the build tenant | NAT gateways and public IPs only |

Use `sandbox` for a first run in your own lab; acceptance testing (phase 3) runs in `firewall` mode, because the
Firewall is part of what is accepted. Switching later is an ordinary change: with `firewall` the next runs create
the Firewall, route tables and rules and remove the direct peerings and NAT gateways (run Platform, then AKS
dev). The NAT gateway public IPs are flagged by the ALZ `corp` policies – fine while they are in audit mode.

## 0. Prerequisites

- A new Entra ID tenant (the build tenant) with three subscriptions: `sub-mgmt`, `sub-hub`, `sub-aks-dev`.
- An operator account with Owner on the three subscriptions and on the Tenant Root Group for the bootstrap
  ([accelerator prerequisites](https://azure.github.io/Azure-Landing-Zones/accelerator/1_prerequisites/)).
- PowerShell 7.4+, Azure CLI, Terraform 1.12+, Git, and the ALZ module:
  ```powershell
  Install-PSResource -Name ALZ
  ```
- Admin rights on this repository (environments, variables, secrets).
- A registered test domain for the zone names and Let's Encrypt (`platform_dns_domain`, default
  `example-test.com`), never the corporate one.
- vCPU quota in the region for the system pools (2 cells × 3 × D4ds_v5) and the NAP VM families, and the
  region must offer availability zones 1–3, API Server VNet Integration and NAP.

## 1. Fill in the IDs

Replace the placeholder subscription IDs (`00000000-0000-0000-0000-00000000000{1,2,3}`) and check the names in:

| File | What |
|---|---|
| [`accelerator/config/inputs.yaml`](../accelerator/config/inputs.yaml) | `subscription_ids`, `bootstrap_subscription_id`, `bootstrap_location`, the GitHub repository in `federated_credentials` |
| [`accelerator/config/platform-landing-zone.tfvars`](../accelerator/config/platform-landing-zone.tfvars) | `subscription_id_aks_dev`, `defender_email_security_contact`, `platform_dns_domain`, address prefixes |
| [`stacks/platform-extensions/terraform.tfvars`](../stacks/platform-extensions/terraform.tfvars) | the same subscription IDs |
| [`environments/dev/*.tfvars`](../environments/dev) | the same subscription IDs, `name_suffix` (globally unique Key Vault names), `container_registry` (the registry aks-terraform creates), `dns_domain`, `admin_group_object_ids` |

Choose the network mode (see above, e.g. `scripts/set-network-mode.sh sandbox` for a lab). Then regenerate the
accelerator output and commit:

```bash
scripts/sync-platform.sh
git add -A && git commit -m "Set build tenant IDs" && git push
```

## 2. Bootstrap with the accelerator

From the repository root, signed in to the build tenant (`az login --tenant <build tenant>`):

```powershell
Deploy-Accelerator `
  -inputs "./accelerator/config/inputs.yaml", "./accelerator/config/platform-landing-zone.tfvars" `
  -starterAdditionalFiles "./accelerator/config/lib" `
  -output "./accelerator/output"
```

The `alz_local` bootstrap creates in `sub-mgmt`:

- the intermediate root management group `alz` and moves `sub-mgmt` and `sub-hub` under it,
- the Terraform state storage account (Entra ID auth only) and container,
- the managed identities `id-alz-build-<region>-plan-1` (Reader) and `id-alz-build-<region>-apply-1`
  (Owner) on `alz`, federated with the GitHub environments `platform-plan` / `platform-apply`,

and writes the starter module into [`platform/`](../platform). `git diff platform/` should be empty apart from
the generated `scripts/deploy-local.ps1` (not used: the GitHub workflows deploy). If the accelerator wrote other
differences, commit them and align `scripts/sync-platform.sh`, which CI uses to keep `platform/` and
`accelerator/config` in sync.

Note the names of the state resource group, storage account and container and the client IDs of the two
identities from the bootstrap output. Keep `accelerator/output` (the bootstrap's own local state).

The GitHub OIDC subjects in `inputs.yaml` (and `github_oidc_subject_prefix` of the platform extensions) must
match the repository's token subject, which for new organizations contains the immutable owner and repository
IDs: `gh api repos/onek8s/azure-landing-zone/actions/oidc/customization/sub`.

Do not apply the bootstrap again once the platform has run: it would move `sub-mgmt` and `sub-hub` back from
`management` / `connectivity` to `alz`. To change only the federated credentials, plan the bootstrap with
`-target='module.azure[0].azurerm_federated_identity_credential.alz["github_platform_plan"]'` (and `_apply`).

## 3. Put sub-aks-dev under the hierarchy

The platform places `sub-aks-dev` into the `corp` management group (`subscription_placement.aks_dev`), which the
apply identity can only do once the subscription is below `alz`:

```bash
az account management-group subscription add --name alz --subscription <sub-aks-dev>
```

## 3b. Public DNS zone

The public zone `onek8s.lol` is created once, outside Terraform, so that a lab reset or a rebuilt stack never
changes its name servers (the registrar points at them). It lives in `rg-onek8s-dns` in `sub-aks-dev`, which the
Lab reset keeps; [aks-terraform](https://github.com/onek8s/aks-terraform) only looks it up and lets each
cluster's external-dns write its own records.

```bash
az group create --subscription <sub-aks-dev> -n rg-onek8s-dns -l swedencentral --tags purpose=public-dns
az network dns zone create --subscription <sub-aks-dev> -g rg-onek8s-dns -n onek8s.lol
az network dns zone show --subscription <sub-aks-dev> -g rg-onek8s-dns -n onek8s.lol --query nameServers
```

Set the four name servers as the domain's NS records at the registrar.

## 4. GitHub environments, variables and secrets

Repository **variables** (Settings → Secrets and variables → Actions → Variables):

| Variable | Value |
|---|---|
| `BACKEND_AZURE_RESOURCE_GROUP_NAME` | state resource group from step 2 |
| `BACKEND_AZURE_STORAGE_ACCOUNT_NAME` | state storage account from step 2 |
| `BACKEND_AZURE_STORAGE_ACCOUNT_CONTAINER_NAME` | state container from step 2 (`build-tfstate`) |
| `RUNNER_APP_ID` | optional: GitHub App for runner registration |
| `AKS_DEV_ENABLED` | `true` once the self-hosted runners are online (step 6); until then the AKS dev workflow is skipped |

Repository **secrets**: `RUNNER_REGISTRATION_TOKEN` – a fine-grained PAT for this repository with
*Administration: read and write* (or `RUNNER_APP_PRIVATE_KEY` with `RUNNER_APP_ID`). It is only used to register
the self-hosted runners.

**Environments** – each with the variables `AZURE_CLIENT_ID`, `AZURE_TENANT_ID` and `AZURE_SUBSCRIPTION_ID`:

| Environment | Protection | `AZURE_CLIENT_ID` | `AZURE_SUBSCRIPTION_ID` |
|---|---|---|---|
| `platform-plan` | – | plan identity from step 2 | `sub-mgmt` |
| `platform-apply` | required reviewers, branch `main` | apply identity from step 2 | `sub-mgmt` |
| `aks-dev-plan` | – | from step 6 output `aks_environment_identities` | `sub-aks-dev` |
| `aks-dev-apply` | required reviewers, branch `main` | from step 6 output | `sub-aks-dev` |

Protect `main` with a ruleset (pull request required, status checks of the **CI** workflow).

## 5. What runs where

| Workflow | Root module | State key | Runner | Identity |
|---|---|---|---|---|
| Platform | `platform` | `terraform.tfstate` | GitHub-hosted | accelerator plan / apply |
| Platform | `stacks/platform-extensions` | `platform-extensions.tfstate` | GitHub-hosted | accelerator plan / apply |
| AKS dev | `stacks/aks-environment` + `environments/dev/environment.tfvars` | `aks-dev-environment.tfstate` | self-hosted (management VNet) | `id-aks-dev-plan` / `-apply` |
| AKS dev, AKS cell | `stacks/aks-stateless-cell` + `environments/dev/sl-az<N>.tfvars` | `aks-dev-sl-az<N>.tfstate` | self-hosted (management VNet) | `id-aks-dev-plan` / `-apply` |

The AKS stacks need the self-hosted runners because Key Vault (keys, certificates) and the API servers have no
public endpoint.

## Lab SKUs

The build tenant runs with the cheapest SKUs that keep the design working. Each one is a single switch back to
the design:

| Component | Lab (default) | Design | Switch |
|---|---|---|---|
| Jump host, test client | not deployed – use `az aks command invoke` or the runners | Linux VMs reached through Bastion | `jump_host_enabled` / `client_vm_enabled` in `stacks/platform-extensions`, together with `primary_bastion_enabled = true` |
| Bastion | not deployed | Standard | `primary_bastion_enabled` in `accelerator/config/platform-landing-zone.tfvars` |
| Azure Firewall (`firewall` mode) | Standard, no IDPS | Premium, IDPS | `primary_firewall_sku_tier` and `intrusion_detection` in the accelerator config |
| GitHub runners | 1 | 2 | `github_runners.count` |
| Runner ACR | Basic, public endpoint, Entra ID authentication only | Premium, private endpoint | `runner_registry_sku` |
| Environment ACR | not part of the landing zone: created by [aks-terraform](https://github.com/onek8s/aks-terraform) (`shared/`) | | `environments.<env>.public_registry` in `stacks/platform-extensions` for the Firewall rules |
| Key Vaults | standard, software-protected cluster keys (RSA) | premium, RSA-HSM | `key_vault_sku` – changing it later replaces the cluster keys, so rebuild the cells |
| Front Door | not deployed | Premium | `front_door_enabled` (Premium only: Private Link origins and managed WAF rules) |
| AKS | Free tier, 1 system node | Standard tier, 3 system nodes | `sku_tier`, `system_pool.node_count` in `environments/dev/sl-az*.tfvars` |
| AKS monitoring | control plane diagnostic settings only | Container Insights, Defender for Containers sensor | `container_insights_enabled`, `defender_enabled` in `environments/dev/sl-az*.tfvars` |
| Private link DNS zones | Key Vault and ACR only | all ~90 ALZ zones | `private_link_private_dns_zones` in the accelerator config (remove it for all zones); add a zone there and in `modules/platform-lookup` before a stack uses it |
| Private DNS Resolver | not deployed – sandbox spokes use Azure DNS with the hub zones linked | inbound endpoint for the corporate DNS forwarders | `primary_private_dns_resolver_enabled` in the accelerator config |
| Management VNet NAT gateway | only while runners or the jump host exist | always (sandbox mode) | follows `github_runner_token` / `github_runner_app_*` and `jump_host_enabled` |
| Management resources | Log Analytics workspace with a 1 GB/day cap | + Azure Monitor Agent identity and the VM data collection rules | `management_resource_settings` in the accelerator config |

Delete the cells (Actions → AKS cell → `delete`) when they are not needed: they are the largest cost of the lab.
Acceptance testing (phase 3) runs with the design values.

## 6. Platform

Run the **Platform** workflow (Actions → Platform → Run workflow), approve the two apply jobs. It deploys:

- management groups and all ALZ policy assignments with `enforcementMode: DoNotEnforce`,
- Log Analytics and data collection rules in `sub-mgmt`,
- the hub in `sub-hub`: the private link DNS zones and the split-horizon zones
  `<zone>.dev.<domain>`, plus Azure Firewall (DNS proxy) in `firewall` mode and Bastion when enabled,
- the management VNet with an ACI GitHub runner (the jump host only when enabled), the client VNet (the test
  client only when enabled), the Firewall rule collection groups and the dev deployment identities.

Copy the client IDs from the output `aks_environment_identities` of the extensions apply job into the
`aks-dev-plan` / `aks-dev-apply` environments. Check that the runner `aci-mgmt-runner-01` is online
(Settings → Actions → Runners), then set the repository variable `AKS_DEV_ENABLED` to `true`.

Until `BACKEND_AZURE_STORAGE_ACCOUNT_NAME` is set the Platform workflow skips its jobs, so pushes before the
bootstrap stay green.

## 7. dev environment and cells

Run the **AKS dev** workflow. It applies the environment (backend and edge VNets, Key Vaults, identities,
policies, Front Door when enabled), then `sl-az1` and, after it, `sl-az2`. A cell takes roughly 20–30 minutes.

The API servers are private. Without a jump host, run kubectl through the AKS API (no network path needed, your
Entra ID account needs a Kubernetes RBAC role on the cluster):

```bash
az aks command invoke -g rg-aks-dev-sl-az1-<region> -n aks-dev-sl-az1 --command "kubectl get nodes"
```

With the jump host enabled, connect with `az network bastion ssh --name bas-hub-<region> --resource-group
rg-hub-<region> --target-resource-id <vm id> --auth-type AAD`, then `az aks get-credentials`,
`kubelogin convert-kubeconfig -l azurecli` and `kubectl` as usual.

## 8. Phase 1 exit criterion: create and delete a cell by the pipeline

Actions → **AKS cell** → environment `dev`, cell `sl-az2`, action `delete` → approve. Then the same with
`create`: the cell is rebuilt from IaC (new OIDC issuer, federated credentials replaced, the same keys reused with
a new version) and the smoke test checks the cluster settings against the requirements and reaches the API
server through the management VNet private endpoint.

## Lab reset

When the lab is broken beyond repair, Actions → **Lab reset** removes everything the platform and AKS stacks
created – resource groups, policy assignments and definitions, the ALZ custom roles, the management groups below
`alz` – and then their Terraform state, so the next Platform run deploys from scratch. The subscriptions, the
accelerator bootstrap (state storage, plan / apply identities, the `alz` management group), the public DNS zone
`onek8s.lol` (resource group `rg-onek8s-dns` in `sub-aks-dev`, created once with the Azure CLI and delegated at the
registrar, so its name servers must not change) and the GitHub settings stay. It runs with the platform apply identity, so its reviewers approve it.

- Type `reset-lab` in *confirm*. *dry_run* (default) only lists what would be deleted.
- Deletions run in passes: a failure is logged and retried in the next pass. The Terraform state is deleted only
  when nothing is left; otherwise the run fails with the list of leftovers and can simply be started again.
- *redeploy* starts the Platform workflow afterwards; run AKS dev after it.
- Key Vaults with purge protection stay soft-deleted for 90 days and keep their names: change `name_suffix` in
  `environments/dev/*.tfvars` before redeploying the dev environment.

## Phase 3: switch from audit to deny

Before acceptance testing every policy goes to its production effect (section 17, "Switch policies to deny first"):

- `policy_enforcement_mode = "Default"` in `accelerator/config/platform-landing-zone.tfvars` (then
  `scripts/sync-platform.sh`) and in `environments/dev/environment.tfvars`,
- the design SKUs (see [Lab SKUs](#lab-skus)), in particular Firewall Premium with
  `intrusion_detection.mode = "Deny"` and `threat_intelligence_mode = "Deny"` in the Firewall policy,
- the Front Door WAF policies follow `policy_enforcement_mode` (Detection → Prevention).
