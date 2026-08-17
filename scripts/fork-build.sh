#!/usr/bin/env bash
#
# Fork-local desktop build wrapper.
#
# Upstream's release CI aligns every package.json to the release version *before*
# packaging, then passes the same string to --build-version. Building the fork
# without that first step is why the app always reported 0.0.33 no matter how far
# main had moved.
#
# The version this stamps answers one question: which upstream nightly is this
# fork based on? It is always marked as a fork, because the branch carries local
# customizations and is never the upstream build:
#
#   0.0.34-nightly.20260815.1102-fork.a4760a4
#   \_______ upstream nightly main sits on ___/ \__ this branch __/
#
# Read the nightly portion to confirm the fork was pulled from the same nightly as
# another machine's app. The trailing short SHA identifies the exact fork build.
#
# One string is used for both the package.json versions (what the app displays and
# what the client/server skew check compares) and --build-version (product name,
# icons, artifact filename). That is safe because build-desktop-artifact.ts only
# treats a version as nightly when /-nightly\.\d{8}\.\d+$/ matches at the *end* of
# the string; the -fork suffix keeps the app named "T3 Code (Alpha)" and prevents a
# collision with an installed Nightly.
#
# Usage:
#   scripts/fork-build.sh [--dry-run] [--output-dir DIR]
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

DRY_RUN=0
OUTPUT_DIR="release-next"

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

# Files update-release-package-versions.ts rewrites. They are tracked, so they get
# restored on exit; leaving them modified would conflict on every upstream rebase.
VERSIONED_MANIFESTS=(
  apps/server/package.json
  apps/desktop/package.json
  apps/web/package.json
  packages/contracts/package.json
)

NIGHTLY_TAG_GLOB='v*-nightly.*'
NIGHTLY_TAG_RE='^v[0-9]+\.[0-9]+\.[0-9]+-nightly\.[0-9]{8}\.[0-9]+$'

# --- which upstream nightly is main based on? -------------------------------------

base_tag="$(git tag --points-at main 2>/dev/null | grep -E "$NIGHTLY_TAG_RE" | head -1 || true)"
ahead=0

if [ -z "$base_tag" ]; then
  base_tag="$(git describe --tags --abbrev=0 --match "$NIGHTLY_TAG_GLOB" main 2>/dev/null || true)"
  if [ -z "$base_tag" ]; then
    echo "error: no upstream nightly tag found for main." >&2
    echo "       run: git fetch upstream --tags" >&2
    exit 1
  fi
  ahead="$(git rev-list --count "${base_tag}..main")"
fi

base_version="${base_tag#v}"
branch_sha="$(git rev-parse --short HEAD)"

if [ "$ahead" -gt 0 ]; then
  version="${base_version}-fork.${branch_sha}.ahead${ahead}"
else
  version="${base_version}-fork.${branch_sha}"
fi

echo
echo "  upstream nightly base : $base_version"
if [ "$ahead" -gt 0 ]; then
  echo "                          (main is $ahead commit(s) past this tag)"
fi
echo "  fork build version    : $version"
echo
echo "  Compare the nightly portion against another machine's app to confirm both"
echo "  were pulled from the same upstream nightly."
echo

if [ "$DRY_RUN" -eq 1 ]; then
  echo "dry run — nothing built."
  exit 0
fi

# --- stamp, build, restore ---------------------------------------------------------

if ! git diff --quiet -- "${VERSIONED_MANIFESTS[@]}"; then
  echo "error: version manifests already have uncommitted changes; refusing to" >&2
  echo "       overwrite them. Commit or revert them first." >&2
  exit 1
fi

restore_manifests() {
  git checkout -- "${VERSIONED_MANIFESTS[@]}" 2>/dev/null || true
}
trap restore_manifests EXIT

node scripts/update-release-package-versions.ts "$version"
node scripts/build-desktop-artifact.ts \
  --platform mac --target dmg --arch arm64 \
  --build-version "$version" \
  --output-dir "$OUTPUT_DIR"

echo
echo "Built into $OUTPUT_DIR/ — version $version"
