# OneK8s landing zone - notes for Claude sessions

The shared working notes for all OneK8s repos are in `onek8s/aks-terraform/CLAUDE.md`. Read that first.

This repo builds the tenant foundation (ALZ, hub, management, deployment identities) and the AKS
policy assignments (`stacks/aks-policy`). It holds **no AKS clusters**: the old
`stacks/aks-stateless-cell` and `stacks/aks-environment` were removed on purpose - clusters and their
shared resources live in aks-terraform. `docs/design-mapping.md` maps the design's requirements to
the code across all repos; keep it current when a decision changes.
