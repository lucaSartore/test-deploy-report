#!/usr/bin/env bash

set -eou pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=94.Deploy/deploy.lib.sh
source "${SCRIPT_DIR}/deploy.lib.sh"

REPO="${REPO:-PROROB-IT/quindi.solution}"
VERSION=${1}
DEVELOPER_VERSION=${DEVELOPER_VERSION:-}
RELEASE_DIR=${RELEASE_DIR:-"./releases"}
DEPLOYMENT_DIR=${DEPLOYMENT_DIR:-"./deployments"}
ENV_FILE="${ENV_FILE:-".env"}"
OVERRIDE_FILE="${OVERRIDE_FILE:-}"
TMP_DIR=$(mktemp -d)
BUNDLE_PATH="${TMP_DIR}/bundle_v${VERSION}.zip"

# version that include optional developer override of
# the base docker image
if [[ -n "${DEVELOPER_VERSION:-}" ]]; then
  FULL_VERSION=${VERSION}-${DEVELOPER_VERSION}
else
  FULL_VERSION=${VERSION}
fi



main() {
  if [[ -z "${OVERRIDE_FILE}" && -f "local.yml" ]]; then
    OVERRIDE_FILE="local.yml"
  fi

  bundle.download           "${VERSION}"     "${BUNDLE_PATH}"
  bundle.extract            "${BUNDLE_PATH}" "${RELEASE_DIR}" "${FULL_VERSION}"
  bundle.override           "${RELEASE_DIR}" "${FULL_VERSION}" "${DEVELOPER_VERSION}"
  release.deploy            "${RELEASE_DIR}" "${FULL_VERSION}" "${ENV_FILE}" "${DEPLOYMENT_DIR}" "${OVERRIDE_FILE}"
}

# Arguments:
# $1: Release version (e.g., 1.0.0)
# $2: Destination path for the downloaded ZIP bundle
bundle.download() {
  echo "Downloading release bundle version ${1}..."
  repo.release.find "${1}" \
  | repo.release.bundle.id \
  | repo.release.asset.download > "${2}"
}

# Arguments:
# $1: Path to the ZIP bundle to extract
# $2: Base directory for releases
# $3: Version string (used to create the sub-directory)
bundle.extract() {
  echo "Extracting release bundle to ${2}..."
  mkdir -p "${2}"
  unzip -o "${1}" -d "${2}/v${3}"
}

# override a bundled release to change the .env version
# with a developer build
# Arguments:
# $1: Base directory for releases
# $2: Version string (used to create the sub-directory)
# $3: Override version tag of the docker image
bundle.override() {
  if [[ -n "${3:-}" ]]; then
    local ENV_FILE
    ENV_FILE="${1}/v${2}/.env"
    # remove the line containing the version from the .env
    sed -i '/^VERSION=/d' "${ENV_FILE}"
    # overriding
    echo "VERSION=${3}" >> "${ENV_FILE}"
  fi
}

# Arguments: (None - processes JSON via STDIN)
repo.release.bundle.id() {
  jq -r '.assets[] | select(.name | test("quindi-.*\\.zip")) | .id'
}

# Arguments: (None - processes Asset ID via STDIN)
repo.release.asset.download() {
  local ASSET_ID
  ASSET_ID=$(cat -)
  gh api \
    -H "Accept: application/octet-stream" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "/repos/${REPO}/releases/assets/${ASSET_ID}"
}

# Arguments:
# $1: Version tag to search for (e.g., 1.0.0)
repo.release.find() {
  repo.release.list \
  | jq -r --arg TAG "v${1}" '.[] | select(.tag_name == $TAG)'
}

# Arguments: (None)
repo.release.list() {
  gh api \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    /repos/${REPO}/releases
}

cleanup() {
  echo "Cleaning up temporary directory..."
  rm -rf "${TMP_DIR}"
}

trap cleanup EXIT
main "$@"
