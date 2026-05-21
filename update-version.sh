#!/usr/bin/env -S nix shell nixpkgs#bash nixpkgs#curl nixpkgs#jq nixpkgs#nix --command bash

# Pins pin.nix to a specific (or the latest) release of `slskd_api` from PyPI and re-validates the source hash. Run from the flake root:
#
#   nix run .#update-version              # latest from PyPI
#   nix run .#update-version -- 0.2.6     # specific version
#
# Always recomputes the source hash and rewrites pin.nix if anything changed; that means it doubles as a "re-validate this exact pin" pass (e.g., for catching an upstream re-upload).

set -euo pipefail

FLAKE_ROOT="${FLAKE_ROOT:-${PWD}}"
pin="${FLAKE_ROOT}/pin.nix"

if [[ ! -f "${pin}" ]]; then
  echo "error: no pin.nix in ${FLAKE_ROOT}" >&2
  echo "Run from the flake root (where pin.nix lives), or set FLAKE_ROOT to point at it." >&2
  exit 1
fi

if [[ $# -ge 1 && -n "${1}" ]]; then
  new_version="${1}"
  echo "Using requested version: ${new_version}"
else
  echo "Querying PyPI for latest release of slskd_api..."
  new_version=$(curl -sSfL https://pypi.org/pypi/slskd_api/json | jq -r '.info.version')
fi
cur_version=$(nix eval --raw --file "${pin}" version)
cur_hash=$(nix eval --raw --file "${pin}" hash)

echo "Computing source hash for ${new_version}..."
url="https://files.pythonhosted.org/packages/source/s/slskd_api/slskd_api-${new_version}.tar.gz"
new_hash=$(nix store prefetch-file --json --hash-type sha256 "${url}" | jq -r '.hash')

if [[ "${cur_version}" == "${new_version}" && "${cur_hash}" == "${new_hash}" ]]; then
  echo "Already up to date (${cur_version} / ${cur_hash:0:20}...)."
  exit 0
fi

echo "Writing pin.nix..."
echo "  version: ${cur_version} -> ${new_version}"
echo "  hash:    ${cur_hash:-<empty>} -> ${new_hash}"
cat > "${pin}" <<EOF
{
  version = "${new_version}";
  hash = "${new_hash}";
}
EOF

echo "Verifying build..."
nix build --option post-build-hook "" "${FLAKE_ROOT}#slskd-api" --no-link

echo
echo "Updated to ${new_version}."
echo "  pin.nix updated. Commit to capture."
