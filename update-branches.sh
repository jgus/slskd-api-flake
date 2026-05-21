#!/usr/bin/env -S nix shell nixpkgs#bash nixpkgs#git nixpkgs#curl nixpkgs#jq nixpkgs#gnused nixpkgs#coreutils --command bash

# Per-version branch orchestrator. Runs on main, exactly once per workflow run.
#
# For each upstream version >= $MINIMUM_TRACKING_VERSION, ensures:
#   - an exact branch `v<M>.<m>.<p>` exists and its pin is hash-validated
#   - aggregate pointer branches `v<M>.<m>`, `v<M>`, `main` are fast-forwarded
#     (force-pushed when needed) to the highest matching exact branch
#
# Single knob: $MINIMUM_TRACKING_VERSION env var. Permanent pins are done via
# git tags (which the action never touches); there is no in-band freeze list.
#
# The flake-specific bit is `list_upstream_versions` below — every other flake
# in this family copies this script and edits only that function.

set -euo pipefail

: "${MINIMUM_TRACKING_VERSION:?required env var}"

FLAKE_ROOT="${FLAKE_ROOT:-${PWD}}"
cd "${FLAKE_ROOT}"

# --- Flake-specific: list all upstream version strings, one per line ---
# Filter to versions that publish an sdist — fetchPypi needs it, wheel-only releases would 404.
list_upstream_versions() {
  curl -sSfL https://pypi.org/pypi/slskd_api/json \
    | jq -r '.releases | to_entries[] | select(.value | any(.packagetype == "sdist")) | .key'
}

# --- Semver helpers (sort -V is good enough for our purposes) ---
version_lt() { [[ "$1" != "$2" ]] && [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" == "$1" ]]; }

# --- Identify ourselves to git ---
git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

# --- Discover & filter upstream versions ---
echo "Querying upstream..."
mapfile -t raw_versions < <(list_upstream_versions)
# Keep only x.y.z (or x.y.z-suffix) tags; strip leading v if present.
declare -a all_versions=()
for v in "${raw_versions[@]}"; do
  v="${v#v}"
  if [[ "${v}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+a-zA-Z0-9.]+)?$ ]]; then
    all_versions+=("${v}")
  fi
done

declare -a tracked=()
for v in "${all_versions[@]}"; do
  if ! version_lt "${v}" "${MINIMUM_TRACKING_VERSION}"; then
    tracked+=("${v}")
  fi
done
if (( ${#tracked[@]} == 0 )); then
  echo "No upstream versions >= ${MINIMUM_TRACKING_VERSION}; nothing to do."
  exit 0
fi
mapfile -t tracked < <(printf '%s\n' "${tracked[@]}" | sort -V)
echo "Tracking ${#tracked[@]} upstream versions: ${tracked[*]}"

# --- Ensure each exact branch exists and its hash is current ---
git fetch --quiet origin
main_sha=$(git rev-parse --verify origin/main)

for v in "${tracked[@]}"; do
  branch="v${v}"
  wt=$(mktemp -d)
  if git ls-remote --exit-code --heads origin "${branch}" >/dev/null 2>&1; then
    echo
    echo "=== Refreshing existing branch ${branch}"
    git fetch --quiet origin "${branch}:refs/remotes/origin/${branch}" || true
    git worktree add -B "${branch}" "${wt}" "origin/${branch}" >/dev/null
  else
    echo
    echo "=== Creating new branch ${branch} from main"
    git worktree add -B "${branch}" "${wt}" "${main_sha}" >/dev/null
    # Reset pin.hash so update-version is forced to compute it.
    cat > "${wt}/pin.nix" <<EOF
{
  version = "${v}";
  hash = "";
}
EOF
  fi
  pushd "${wt}" >/dev/null
  # Bump nixpkgs first so update-version (and the build that re-validates the hash) runs against current nixpkgs. Hashes don't depend on nixpkgs for PyPI fetchers, but keeping flake.lock fresh is hygiene for consumers and ensures main (as an aggregate pointer to whichever exact branch wins) inherits a recent lock.
  nix flake update --option post-build-hook ""
  FLAKE_ROOT="${wt}" nix run --option post-build-hook "" .#update-version -- "${v}"
  if ! git diff --quiet -- pin.nix flake.lock || [[ -n "$(git ls-files --others --exclude-standard -- flake.lock)" ]]; then
    git add pin.nix flake.lock
    git commit -q -m "auto: ${v} pin"
    git push --quiet origin "${branch}"
  else
    echo "  no change on ${branch}"
  fi
  popd >/dev/null
  git worktree remove --force "${wt}" >/dev/null
done

# --- Compute aggregate targets ---
git fetch --quiet origin
declare -A agg_target_version=()
record() { local key="$1" v="$2"; cur="${agg_target_version[$key]:-}"; if [[ -z "${cur}" ]] || version_lt "${cur}" "${v}"; then agg_target_version[$key]="${v}"; fi; }
for v in "${tracked[@]}"; do
  IFS='.' read -r M m _ <<<"${v}"
  record "main" "${v}"
  record "v${M}" "${v}"
  record "v${M}.${m}" "${v}"
done

# --- Move aggregate pointers ---
echo
echo "=== Updating aggregate pointers"
for agg in "${!agg_target_version[@]}"; do
  target_v="${agg_target_version[$agg]}"
  target_branch="v${target_v}"
  target_sha=$(git rev-parse --verify "origin/${target_branch}")
  cur_sha=$(git rev-parse --verify "origin/${agg}" 2>/dev/null || echo "")
  if [[ "${cur_sha}" == "${target_sha}" ]]; then
    echo "  ${agg} already at ${target_branch}"
    continue
  fi
  echo "  ${agg} -> ${target_branch} (${target_sha:0:8})"
  git push --force --quiet origin "${target_sha}:refs/heads/${agg}"
done

echo
echo "Done."
