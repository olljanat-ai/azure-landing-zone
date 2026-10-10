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
| [`environments/dev/*.tfvars`](../environments/dev) | the same subscription IDs, `name_suffix` (globally unique Key Vault / ACR names), `dns_domain`, `admin_group_object_ids` |

Then regenerate the accelerator output and commit:

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
identities from the bootstrap output.

## 3. Put sub-aks-dev under the hierarchy

The platform places `sub-aks-dev` into the `corp` management group (`subscription_placement.aks_dev`), which the
apply identity can only do once the subscription is below `alz`:

```bash
az account management-group subscription add --name alz --subscription <sub-aks-dev>
```

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

The AKS stacks need the self-hosted runners because Key Vault (keys, certificates), ACR and the API servers have
no public endpoint.

## 6. Platform

Run the **Platform** workflow (Actions → Platform → Run workflow), approve the two apply jobs. It deploys:

- management groups and all ALZ policy assignments with `enforcementMode: DoNotEnforce`,
- Log Analytics and data collection rules in `sub-mgmt`,
- the hub in `sub-hub`: Azure Firewall Premium (DNS proxy), Bastion, Private DNS Resolver, the private link DNS
  zones and the split-horizon zones `<zone>.dev.<domain>`,
- the management VNet with two ACI GitHub runners and the jump host, the client VNet with a test client,
  the Firewall rule collection groups and the dev deployment identities.

Copy the client IDs from the output `aks_environment_identities` of the extensions apply job into the
`aks-dev-plan` / `aks-dev-apply` environments. Check that the runners `aci-mgmt-runner-01/02` are online
(Settings → Actions → Runners), then set the repository variable `AKS_DEV_ENABLED` to `true`.

Until `BACKEND_AZURE_STORAGE_ACCOUNT_NAME` is set the Platform workflow skips its jobs, so pushes before the
bootstrap stay green.

## 7. dev environment and cells

Run the **AKS dev** workflow. It applies the environment (backend and edge VNets, Key Vaults, ACR, identities,
policies, Front Door), then `sl-az1` and, after it, `sl-az2`. A cell takes roughly 20–30 minutes.

Connect from the jump host (`az network bastion ssh --name bas-hub-<region> --resource-group rg-hub-<region>
--target-resource-id <vm id> --auth-type AAD`):

```bash
az aks get-credentials -g rg-aks-dev-sl-az1-<region> -n aks-dev-sl-az1
kubelogin convert-kubeconfig -l azurecli
kubectl get nodes
```

## 8. Phase 1 exit criterion: create and delete a cell by the pipeline

Actions → **AKS cell** → environment `dev`, cell `sl-az2`, action `delete` → approve. Then the same with
`create`: the cell is rebuilt from IaC (new OIDC issuer, federated credentials replaced, the same keys reused with
a new version) and the smoke test checks the cluster settings against the requirements and reaches the API
server through the management VNet private endpoint.

## Phase 3: switch from audit to deny

Before acceptance testing every policy goes to its production effect (section 17, "Switch policies to deny first"):

- `policy_enforcement_mode = "Default"` in `accelerator/config/platform-landing-zone.tfvars` (then
  `scripts/sync-platform.sh`) and in `environments/dev/environment.tfvars`,
- `intrusion_detection.mode = "Deny"` and `threat_intelligence_mode = "Deny"` in the Firewall policy,
- the Front Door WAF policies follow `policy_enforcement_mode` (Detection → Prevention).
