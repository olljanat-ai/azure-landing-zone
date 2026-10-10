#!/usr/bin/env bash
# Regenerates the policy_assignments_to_modify block of accelerator/config/platform-landing-zone.tfvars from the
# ALZ library version referenced in accelerator/config/lib/alz_library_metadata.json, so that every ALZ policy
# assignment follows the `policy_enforcement_mode` switch (DoNotEnforce in the build tenant until phase 3).
# Run it after changing the library version.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tfvars="$root/accelerator/config/platform-landing-zone.tfvars"
ref="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["dependencies"][0]["ref"])' "$root/accelerator/config/lib/alz_library_metadata.json")"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
git clone -q --depth 1 --branch "platform/alz/$ref" https://github.com/Azure/Azure-Landing-Zones-Library.git "$tmp/lib"
python3 -I "$root/scripts/generate-policy-enforcement.py" "$tmp/lib" > "$tmp/block"
python3 -I - "$tfvars" "$tmp/block" <<'PY'
import re, sys
path, block = sys.argv[1], open(sys.argv[2]).read()
text = open(path).read()
pattern = re.compile(r"(  # BEGIN GENERATED policy_assignments_to_modify[^\n]*\n).*?(  # END GENERATED policy_assignments_to_modify)", re.S)
new, n = pattern.subn(lambda m: m.group(1) + block + m.group(2), text)
if n != 1:
    sys.exit("markers not found in " + path)
open(path, "w").write(new)
PY
terraform fmt "$tfvars" >/dev/null
echo "updated $tfvars for ALZ library $ref"
