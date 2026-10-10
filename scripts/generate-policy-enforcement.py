#!/usr/bin/env python3
"""Generate the `policy_assignments_to_modify` block that puts every ALZ policy assignment in
enforcement mode `DoNotEnforce` (build tenant: audit only, see aks-design section 17).

Usage: generate-policy-enforcement.py <path-to-Azure-Landing-Zones-Library checkout at the ref in
accelerator/config/lib/alz_library_metadata.json>

Assignments removed by the archetype overrides in accelerator/config/lib are left out.

The output is pasted into accelerator/config/platform-landing-zone.tfvars between the
BEGIN/END GENERATED markers by scripts/update-policy-enforcement.sh.
"""
import json
import pathlib
import sys

import yaml

LOCAL_LIB = pathlib.Path(__file__).resolve().parent.parent / "accelerator" / "config" / "lib" / "archetype_definitions"

# management group id in the alz_custom architecture -> base archetype in the ALZ library
MANAGEMENT_GROUPS = {
    "alz": "root",
    "platform": "platform",
    "landingzones": "landing_zones",
    "corp": "corp",
    "online": "online",
    "local": "local",
    "sandbox": "sandbox",
    "security": "security",
    "management": "management",
    "connectivity": "connectivity",
    "identity": "identity",
    "decommissioned": "decommissioned",
}

# Parameters that must survive next to the enforcement mode (taken from the accelerator example).
EXTRA = {
    ("alz", "Deploy-MDFC-Config-H224"): """          parameters = {
            enableAscForServers                         = "DeployIfNotExists"
            enableAscForServersVulnerabilityAssessments = "DeployIfNotExists"
            enableAscForSql                             = "DeployIfNotExists"
            enableAscForAppServices                     = "DeployIfNotExists"
            enableAscForStorage                         = "DeployIfNotExists"
            enableAscForContainers                      = "DeployIfNotExists"
            enableAscForKeyVault                        = "DeployIfNotExists"
            enableAscForSqlOnVm                         = "DeployIfNotExists"
            enableAscForArm                             = "DeployIfNotExists"
            enableAscForOssDb                           = "DeployIfNotExists"
            enableAscForCosmosDbs                       = "DeployIfNotExists"
            enableAscForCspm                            = "DeployIfNotExists"
          }
""",
}


def main() -> None:
    lib = pathlib.Path(sys.argv[1]) / "platform" / "alz" / "archetype_definitions"
    out = ["  policy_assignments_to_modify = {"]
    for mg, archetype in MANAGEMENT_GROUPS.items():
        data = json.loads((lib / f"{archetype}.alz_archetype_definition.json").read_text())
        override = LOCAL_LIB / f"{archetype}_custom.alz_archetype_override.yaml"
        removed = set()
        if override.exists():
            removed = set(yaml.safe_load(override.read_text()).get("policy_assignments_to_remove") or [])
        names = sorted(set(data.get("policy_assignments", [])) - removed, key=str.lower)
        if not names:
            continue
        out.append(f"    {mg} = {{")
        out.append("      policy_assignments = {")
        width = max(len(n) for n in names)
        for name in names:
            extra = EXTRA.get((mg, name))
            if extra:
                out.append(f"        {name} = {{")
                out.append(f'          enforcement_mode = "$${{policy_enforcement_mode}}"')
                out.append(extra.rstrip("\n"))
                out.append("        }")
            else:
                out.append(f'        {name.ljust(width)} = {{ enforcement_mode = "$${{policy_enforcement_mode}}" }}')
        out.append("      }")
        out.append("    }")
    out.append("  }")
    print("\n".join(out))


if __name__ == "__main__":
    main()
