#!/usr/bin/env bash

# Install Quindi on a machine with no internet access, from the package built
# by 92.Delivery/offline.bundle.sh. Shipped inside the package as install.sh.

set -euo pipefail

PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENV_FILE="${ENV_FILE:-${PKG_DIR}/.env}"
OVERRIDE_FILE="${OVERRIDE_FILE:-}"
RELEASE_DIR="${RELEASE_DIR:-${PKG_DIR}/releases}"
DEPLOYMENT_DIR="${DEPLOYMENT_DIR:-${PKG_DIR}/deployments}"
SKIP_ENGINE="false"
SKIP_CHECKSUM="false"
SKIP_CHECK="false"
SKIP_HEALTH="false"
DAEMON_TIMEOUT="${DAEMON_TIMEOUT:-60}"

# 99.offline.yml vieta il pull: senza rete un load fallito deve dare un errore
# immediato invece di un timeout verso il registry.
COMPOSE_FILES=("10.prod.yml" "99.offline.yml")
# shellcheck source=94.Deploy/deploy.lib.sh
source "${PKG_DIR}/deploy.lib.sh"

usage() {
  cat <<'EOF'
Uso: sudo ./install.sh [env-file]

  --skip-engine     Docker è già installato, non toccarlo
  --skip-checksum   non verificare SHA256SUMS
  --skip-check      non verificare il .env prima di installare (check.sh)
  --skip-health     non verificare lo stack dopo l'avvio (healthcheck.sh)
  --override <file> compose che sovrascrive quello del pacchetto
  -h, --help        questo aiuto

Senza env-file viene usato il .env accanto allo script; se manca e il
terminale è interattivo parte configure.sh per crearlo. Senza --override viene
usato il local.yml se sta lì accanto. L'override serve per ciò che il .env non
copre, per esempio la porta pubblicata da una versione che non la legge da
variabile:

  services:
    web:
      ports: !override
        - "19000:8080"
EOF
}

main() {
  args.parse "$@"

  VERSION="$(package.version)"

  if [[ -z "${OVERRIDE_FILE}" && -f "${PKG_DIR}/local.yml" ]]; then
    OVERRIDE_FILE="${PKG_DIR}/local.yml"
  fi

  preflight.check
  checksum.verify
  env.configure
  env.check
  engine.install
  daemon.start
  images.load
  release.stage
  release.deploy "${RELEASE_DIR}" "${VERSION}" "${ENV_FILE}" "${DEPLOYMENT_DIR}" "${OVERRIDE_FILE}"
  stack.health

  echo "Installazione completata: versione ${VERSION}."
}

args.parse() {
  while [[ $# -gt 0 ]]; do
    case "${1}" in
      -h|--help)       usage; exit 0 ;;
      --skip-engine)   SKIP_ENGINE="true"; shift ;;
      --skip-checksum) SKIP_CHECKSUM="true"; shift ;;
      --skip-check)    SKIP_CHECK="true"; shift ;;
      --skip-health)   SKIP_HEALTH="true"; shift ;;
      --override)      OVERRIDE_FILE="${2:?--override richiede un valore}"; shift 2 ;;
      -*)              echo "Opzione sconosciuta: ${1}" >&2; usage >&2; exit 1 ;;
      *)               ENV_FILE="${1}"; shift ;;
    esac
  done
}

package.version() {
  [[ -f "${PKG_DIR}/ops/.env" ]] || return 0
  sed -n 's/^VERSION=//p' "${PKG_DIR}/ops/.env"
}

preflight.check() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Serve root: rilancia con sudo." >&2
    exit 1
  fi

  local dir
  for dir in ops images; do
    if [[ ! -d "${PKG_DIR}/${dir}" ]]; then
      echo "Pacchetto incompleto: manca «${dir}»." >&2
      exit 1
    fi
  done

  if [[ -z "${VERSION}" ]]; then
    echo "Versione non leggibile da ops/.env." >&2
    exit 1
  fi

  if [[ ! -f "${ENV_FILE}" && ! -t 0 ]]; then
    echo "File di configurazione «${ENV_FILE}» non trovato: lancia ./configure.sh per crearlo." >&2
    exit 1
  fi

  if [[ -n "${OVERRIDE_FILE}" && ! -f "${OVERRIDE_FILE}" ]]; then
    echo "Override compose «${OVERRIDE_FILE}» non trovato." >&2
    exit 1
  fi
}

env.configure() {
  [[ ! -f "${ENV_FILE}" ]] || return 0

  echo "File di configurazione «${ENV_FILE}» non trovato: parte la configurazione guidata."
  echo
  "${PKG_DIR}/configure.sh" "${ENV_FILE}"
  echo
}

env.check() {
  if [[ "${SKIP_CHECK}" == "true" ]]; then
    echo "Verifica della configurazione saltata."
    return 0
  fi

  "${PKG_DIR}/check.sh" "${ENV_FILE}"
  echo
}

stack.health() {
  if [[ "${SKIP_HEALTH}" == "true" ]]; then
    echo "Verifica dello stack saltata."
    return 0
  fi

  echo
  DEPLOYMENT_DIR="${DEPLOYMENT_DIR}" "${PKG_DIR}/healthcheck.sh"
  echo
}

checksum.verify() {
  if [[ "${SKIP_CHECKSUM}" == "true" ]]; then
    echo "Verifica dei checksum saltata."
    return 0
  fi

  echo "Verifica dei checksum..."

  # -c stampa una riga OK per file: si tiene solo il rumore che non lo è.
  local report
  if ! report="$(cd "${PKG_DIR}" && sha256sum -c SHA256SUMS 2>&1)"; then
    echo "${report}" | grep -v ': OK$' >&2
    echo "Checksum non validi: pacchetto corrotto o incompleto." >&2
    exit 1
  fi
}

engine.install() {
  if [[ "${SKIP_ENGINE}" == "true" ]]; then
    echo "Installazione di Docker saltata."
    return 0
  fi

  if command -v docker > /dev/null 2>&1; then
    echo "Docker già presente: $(docker --version)."
    return 0
  fi

  if [[ ! -f "${PKG_DIR}/engine/Packages.gz" ]]; then
    echo "Docker non è installato e il pacchetto non contiene gli installer." >&2
    exit 1
  fi

  echo "Installazione di Docker Engine..."

  # Repository apt locale, con le sorgenti della macchina escluse: apt risolve
  # le dipendenze e non installa nulla che sia già presente in versione uguale
  # o più recente, cosa che dpkg -i farebbe.
  local list
  list="$(mktemp)"
  echo "deb [trusted=yes] file://${PKG_DIR}/engine ./" > "${list}"

  local -a apt_opts=(
    -o "Dir::Etc::SourceList=${list}"
    -o "Dir::Etc::SourceParts=/dev/null"
    -o "APT::Get::List-Cleanup=0"
  )

  DEBIAN_FRONTEND=noninteractive apt-get "${apt_opts[@]}" update
  DEBIAN_FRONTEND=noninteractive apt-get "${apt_opts[@]}" install -y \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  rm -f "${list}"
}

# Il pacchetto docker-ce installa sia l'unit systemd sia lo script SysV, quindi
# c'è un modo di avviare il demone anche dove systemd non è l'init (WSL, LXC).
daemon.start() {
  if docker info > /dev/null 2>&1; then
    return 0
  fi

  echo "Avvio del demone Docker..."

  # /run/systemd/system esiste solo se la macchina è stata avviata con systemd:
  # è il test canonico, e il codice di uscita di systemctl non lo sostituisce
  # perché su alcune release --now viene ignorato uscendo comunque con 0.
  if [[ -d /run/systemd/system ]]; then
    systemctl enable --now docker
  elif [[ -x /etc/init.d/docker ]]; then
    /etc/init.d/docker start
  fi

  daemon.wait
}

daemon.wait() {
  local waited=0

  until docker info > /dev/null 2>&1; do
    if [[ "${waited}" -ge "${DAEMON_TIMEOUT}" ]]; then
      echo "Il demone Docker non risponde dopo ${DAEMON_TIMEOUT}s." >&2
      echo "Avvialo a mano, poi rilancia questo script con --skip-engine." >&2
      exit 1
    fi
    sleep 1
    waited=$((waited + 1))
  done

  echo "Demone Docker attivo."
}

images.load() {
  local tarball="${PKG_DIR}/images/quindi-images-${VERSION}.tar.gz"

  if [[ ! -f "${tarball}" ]]; then
    echo "Archivio delle immagini «${tarball}» non trovato." >&2
    exit 1
  fi

  echo "Caricamento delle immagini..."
  docker load -i "${tarball}"

  images.check
}

# Ogni immagine richiesta dal compose deve essere fra quelle caricate: se manca,
# senza rete il compose non ha modo di rimediare.
images.check() {
  local image missing=0 merged
  local -a images

  merged="$(mktemp)"
  cat "${PKG_DIR}/ops/.env" "${ENV_FILE}" > "${merged}"
  mapfile -t images < <(docker compose --project-directory "${PKG_DIR}/ops" --env-file "${merged}" -f "${PKG_DIR}/ops/10.prod.yml" config --images)
  rm -f "${merged}"

  if [[ "${#images[@]}" -eq 0 ]]; then
    echo "Elenco delle immagini non leggibile da ops/10.prod.yml." >&2
    exit 1
  fi

  for image in "${images[@]}"; do
    if ! docker image inspect "${image}" > /dev/null 2>&1; then
      echo "Immagine mancante dopo il load: ${image}" >&2
      missing=1
    fi
  done

  [[ "${missing}" -eq 0 ]] || exit 1
}

# release.deploy legge da <release-dir>/v<version>, lo stesso layout che il
# percorso online ottiene scompattando lo zip della release.
release.stage() {
  mkdir -p "${RELEASE_DIR}"
  rm -rf "${RELEASE_DIR:?}/v${VERSION}"
  cp -r "${PKG_DIR}/ops" "${RELEASE_DIR}/v${VERSION}"
}

main "$@"
