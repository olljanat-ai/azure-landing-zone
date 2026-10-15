#!/usr/bin/env bash
# Usage: scripts/vendor-labfw.sh <git ref of onek8s/azure-lab-fw, e.g. a release tag>
# Refreshes modules/labfw/vendor from onek8s/azure-lab-fw: the cloud-init template and the install script that
# its Bicep deployment uses too. The labfw binary itself comes from the GitHub release named by
# labfw.release_version in stacks/platform-extensions; vendor the same ref as that release.
set -euo pipefail
ref="${1:?usage: $0 <ref>}"
repo="onek8s/azure-lab-fw"
root="$(cd "$(dirname "$0")/.." && pwd)"
dir="$root/modules/labfw/vendor"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
git -C "$work" init -q
git -C "$work" fetch -q --depth 1 "https://github.com/$repo.git" "$ref"
commit="$(git -C "$work" rev-parse FETCH_HEAD)"
git -C "$work" show "FETCH_HEAD:deploy/cloud-init/cloud-init.yaml" >"$dir/cloud-init.yaml"
git -C "$work" show "FETCH_HEAD:deploy/cloud-init/install-labfw.sh" >"$dir/install-labfw.sh"
chmod 0755 "$dir/install-labfw.sh"
sed -i -E "s|^commit: .*|commit: $commit|" "$dir/UPSTREAM"
echo "vendored $repo@$ref ($commit) into modules/labfw/vendor - review git diff and commit"
