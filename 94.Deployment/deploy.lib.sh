#!/usr/bin/env bash

# Deployment lifecycle shared by deploy.sh (online) and install.sh (offline).
# Sourced, never executed.

# Compose file names, relative to the deployment directory. L'installazione
# offline vi aggiunge 99.offline.yml.
if [[ -z "${COMPOSE_FILES+x}" ]]; then
  COMPOSE_FILES=("10.prod.yml")
fi

# Override dell'operatore. Non viaggia nel pacchetto, quindi non entra in
# SHA256SUMS, e va per ultimo così vince sui file consegnati.
LOCAL_COMPOSE_FILE="99.local.yml"

# Arguments:
# $1: Base release directory (where bundles are extracted)
# $2: Version string
# $3: Path to the .env file to be injected
# $4: Base deployment directory
# $5: Path to the operator's compose override, optional
release.deploy() {
  local ENV_HASH_NEW DEPLOYMENT_ID

  if [ ! -f "${3}" ]; then
    echo "Environment file «${3}» not found."
    exit 1
  fi

  if [[ -n "${5:-}" && ! -f "${5}" ]]; then
    echo "Compose override «${5}» not found."
    exit 1
  fi

  ENV_HASH_NEW=$(env.hash "${3}")
  DEPLOYMENT_ID="v${2}-${ENV_HASH_NEW}"

  echo "Deploying release version ${2} with env [${ENV_HASH_NEW}] from «${3}» to deployment dir «${4}»..."

  mkdir -p "${4}"
  # Azzera la destinazione: su una directory esistente cp -r annida la copia in
  # sé stessa e il .env dell'operatore verrebbe appeso una seconda volta.
  rm -rf "${4:?}/${DEPLOYMENT_ID}"
  cp -r "${1}/v${2}" "${4}/${DEPLOYMENT_ID}"
  cat "${3}" >> "${4}/${DEPLOYMENT_ID}/.env"

  if [[ -n "${5:-}" ]]; then
    echo "Applying compose override «${5}»..."
    cp "${5}" "${4}/${DEPLOYMENT_ID}/${LOCAL_COMPOSE_FILE}"
  fi

  deployment.stop   "${4}"
  deployment.switch "${4}" "${DEPLOYMENT_ID}"
  deployment.start  "${4}"
}

# Arguments:
# $1: Base deployment directory containing the "current" symlink
deployment.stop() {
  if [ ! -d "${1}/current" ]; then
    echo "No current release found. Skipping stop step."
    return 0
  fi

  echo "Stopping services..."
  local -a files
  mapfile -t files < <(compose.args "${1}")
  docker compose "${files[@]}" down
}

# Arguments:
# $1: Base deployment directory
# $2: The specific deployment ID (folder name) to link to
deployment.switch() {
  echo "Switching to deployment «${2}»..."
  # -s: symbolic, -f: force (overwrite existing), -n: treat link as a file
  ln -sfn "${2}" "${1}/current"
}

# Arguments:
# $1: Base deployment directory
deployment.start() {
  echo "Starting services ..."
  local -a files
  mapfile -t files < <(compose.args "${1}")
  docker compose "${files[@]}" up -d
}

# Emette gli argomenti "-f <path>", uno per riga, da leggere con mapfile.
# Arguments:
# $1: Base deployment directory
compose.args() {
  local file
  for file in "${COMPOSE_FILES[@]}"; do
    printf -- '-f\n%s\n' "${1}/current/${file}"
  done

  if [[ -f "${1}/current/${LOCAL_COMPOSE_FILE}" ]]; then
    printf -- '-f\n%s\n' "${1}/current/${LOCAL_COMPOSE_FILE}"
  fi
}

# Arguments:
# $1: Path to the file to hash
env.hash() {
  sha256sum "${1}" | awk '{print $1}'
}
