#!/usr/bin/env bash
# Tests of the platform's Kubernetes policies (OneK8s design section 9), run by CI and locally:
#
#   stacks/aks-policy/kubernetes/test.sh        (needs gator, python3 with PyYAML)
#
# 1. gator verify: every constraint template against its cases (tests/suite.yaml).
# 2. The mutations: each tests/mutations/<case>.input.yaml (a Deployment) is expanded into its pod
#    with every mutation applied, rendered for every zone as kubernetes.tf renders them, and compared with
#    <case>.expected.yaml (only spec.nodeSelector, spec.tolerations and spec.affinity).
# 3. What the mutations produce passes the validations: the expanded pods go through the zone and
#    placement-label templates, which must find nothing (but for the recorded exceptions,
#    labelled platform/zone-placement: "off").
#
# UPDATE=1 rewrites the expected files from the current output instead of comparing.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
zones=(int-fi int-se ext-fi ext-se) # var.isolation_zones' default
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "== gator verify"
gator verify "$here/tests"

echo "== mutations"
mkdir -p "$work/mutators"
for template in "$here"/mutations/*.yaml.tftpl; do
  name="$(basename "$template" .yaml.tftpl)"
  if grep -q '\${zone}' "$template"; then
    for zone in "${zones[@]}"; do sed "s/\${zone}/$zone/g" "$template" > "$work/mutators/$name-$zone.yaml"; done
  else
    cp "$template" "$work/mutators/$name.yaml"
  fi
done
cat > "$work/mutators/expansion.yaml" <<'EOF'
apiVersion: expansion.gatekeeper.sh/v1alpha1
kind: ExpansionTemplate
metadata:
  name: deployments
spec:
  applyTo:
    - groups: ["apps"]
      kinds: ["Deployment"]
      versions: ["v1"]
  templateSource: spec.template
  generatedGVK:
    kind: Pod
    group: ""
    version: v1
EOF

fail=0
mkdir -p "$work/pods"
for input in "$here"/tests/mutations/*.input.yaml; do
  case_name="$(basename "$input" .input.yaml)"
  gator expand -n "$work/mutators" -n "$input" -o "$work/pods/$case_name.yaml" </dev/null >/dev/null
  expected="$here/tests/mutations/$case_name.expected.yaml"
  python3 - "$work/pods/$case_name.yaml" "$expected" "${UPDATE:-}" <<'EOF' || fail=1
import sys, yaml
got_path, expected_path, update = sys.argv[1:4]
pod = yaml.safe_load(open(got_path))
got = {k: pod["spec"][k] for k in ("nodeSelector", "tolerations", "affinity") if k in pod["spec"]}
if update:
    open(expected_path, "w").write(yaml.safe_dump(got, sort_keys=True))
    print(f"updated {expected_path}")
    sys.exit(0)
expected = yaml.safe_load(open(expected_path)) or {}
name = expected_path.rsplit("/", 1)[-1]
if got != expected:
    print(f"FAIL {name}:\n--- expected\n{yaml.safe_dump(expected)}--- got\n{yaml.safe_dump(got)}")
    sys.exit(1)
print(f"ok   {name}")
EOF
done

echo "== mutated pods pass the validations"
cp "$here/templates/zone-placement.yaml" "$here/templates/placement-labels.yaml" "$work/"
cp "$here/tests/zone-placement/constraint.yaml" "$work/zone-constraint.yaml"
cp "$here/tests/placement-labels/constraint.yaml" "$work/labels-constraint.yaml"
# The recorded exceptions (platform/zone-placement: "off") are reported by design
grep -l 'platform/zone-placement: "*off' "$work"/pods/*.yaml | xargs rm
if ! gator test -f "$work/zone-placement.yaml" -f "$work/placement-labels.yaml" -f "$work/zone-constraint.yaml" \
  -f "$work/labels-constraint.yaml" -f "$work/pods" </dev/null; then
  echo "FAIL a mutated pod violates the validations"; fail=1
else
  echo "ok   no violations"
fi
exit $fail
