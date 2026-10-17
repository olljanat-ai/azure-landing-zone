# OneK8s landing zone - notes for Claude sessions

The shared working notes for all OneK8s repos are in `onek8s/aks-terraform/CLAUDE.md`. Read that first.

This repo builds the tenant foundation (ALZ, hub, management, deployment identities) and the AKS
policy assignments (`stacks/aks-policy`). It holds **no AKS clusters**: the old
`stacks/aks-stateless-cell` and `stacks/aks-environment` were removed on purpose - clusters and their
shared resources live in aks-terraform. `docs/design-mapping.md` maps the design's requirements to
the code across all repos; keep it current when a decision changes. `docs/traffic-flows/<spoke>/` holds the **generated**
traffic flow pages (design section 23): a Mermaid picture per application namespace and per isolation zone, written by
aks-ai-agents' `aks-agent docs traffic` (aks-terraform workflow `Traffic flow docs`) from the rule files in
`stacks/platform-extensions/firewall-applications/`, the cell tfvars, the applications' Flux configuration and the fleet's
allow-lists - never edit them by hand; regenerate them after a change to a rule file.
