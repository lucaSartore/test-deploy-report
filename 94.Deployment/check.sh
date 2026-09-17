#!/usr/bin/env bash

# Verify the operator's .env against the package before anything is installed.
# Shipped inside the offline package next to install.sh.

set -euo pipefail

PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPS_DIR="${OPS_DIR:-${PKG_DIR}/ops}"
ENV_FILE="${ENV_FILE:-${PKG_DIR}/.env}"
DOCKER_ROOT_DEFAULT="/var/lib/docker"

# shellcheck source=94.Deploy/env.lib.sh
source "${PKG_DIR}/env.lib.sh"

ERRORS=0
WARNINGS=0

usage() {
  cat <<'EOF'
Uso: ./check.sh [env-file]

  -h, --help   questo aiuto

Controlla che il .env sia completo e coerente con il pacchetto: segreti
richiesti dai compose, formato delle porte, release Ubuntu, spazio disco.
Esce con 1 se c'è almeno un errore; gli avvisi non bloccano.
EOF
}

main() {
  args.parse "$@"

  local -a files
  mapfile -t files < <(compose.files "${OPS_DIR}")

  echo "Verifica della configurazione «${ENV_FILE}»"
  echo

  check.file          || exit 1
  check.secrets       "${files[@]}"
  check.pinned
  check.project
  check.ports         "${files[@]}"
  check.extras
  check.release
  check.disk
  check.compose
  check.volumes

  summary.print
}

args.parse() {
  while [[ $# -gt 0 ]]; do
    case "${1}" in
      -h|--help) usage; exit 0 ;;
      -*)        echo "Opzione sconosciuta: ${1}" >&2; usage >&2; exit 1 ;;
      *)         ENV_FILE="${1}"; shift ;;
    esac
  done

  if [[ ! -f "${OPS_DIR}/10.prod.yml" ]]; then
    echo "Pacchetto incompleto: manca «${OPS_DIR}/10.prod.yml»." >&2
    exit 1
  fi
}

ok()   { echo "  OK      ${1}"; }
warn() { echo "  AVVISO  ${1}"; WARNINGS=$((WARNINGS + 1)); }
fail() { echo "  ERRORE  ${1}"; ERRORS=$((ERRORS + 1)); }

check.file() {
  if [[ ! -f "${ENV_FILE}" ]]; then
    fail "file non trovato: lancia ./configure.sh per crearlo"
    summary.print
    return 1
  fi

  if [[ ! -r "${ENV_FILE}" ]]; then
    fail "file non leggibile: appartiene a un altro utente, rilancia con sudo"
    summary.print
    return 1
  fi

  local mode
  mode="$(stat -c %a "${ENV_FILE}")"
  if [[ "${mode: -2}" != "00" ]]; then
    warn "permessi ${mode}: il file contiene segreti, chmod 600 li riserva al proprietario"
  fi
  ok "file presente"
}

check.secrets() {
  local name value reason
  while read -r name; do
    value="$(env.get "${ENV_FILE}" "${name}")"
    reason="$(secret.reject "${name}" "${value}")"
    if [[ -n "${reason}" ]]; then
      fail "${name}: ${reason}"
      continue
    fi

    reason="$(secret.weak "${value}")"
    if [[ -n "${reason}" ]]; then
      warn "${name}: ${reason}"
      continue
    fi
    ok "${name} impostata"
  done < <(env.required "$@")
}

check.pinned() {
  local name
  for name in REGISTRY VERSION; do
    if env.has "${ENV_FILE}" "${name}"; then
      fail "${name} è definita nel file: punterebbe a immagini che il pacchetto non contiene, rimuovila"
    fi
  done
}

check.project() {
  local value
  value="$(env.get "${ENV_FILE}" COMPOSE_PROJECT_NAME)"
  if [[ -z "${value}" ]]; then
    ok "COMPOSE_PROJECT_NAME non impostata: vale quella del pacchetto"
    return 0
  fi

  if [[ ! "${value}" =~ ${PROJECT_NAME_PATTERN} ]]; then
    fail "COMPOSE_PROJECT_NAME «${value}»: ammessi solo minuscole, cifre, trattini e underscore, con una lettera o cifra all'inizio"
    return 0
  fi
  ok "COMPOSE_PROJECT_NAME=${value}"
}

check.ports() {
  local line name value reason host
  local -A seen=()

  while read -r line; do
    name="${line%%=*}"
    value="$(env.get "${ENV_FILE}" "${name}")"
    [[ -n "${value}" ]] || value="${line#*=}"

    reason="$(port_map.reject "${value}")"
    if [[ -n "${reason}" ]]; then
      fail "${name}=${value}: ${reason}"
      continue
    fi

    host="${value%%:*}"
    if [[ -n "${seen[${host}]+x}" ]]; then
      fail "${name}=${value}: la porta host ${host} è già usata da ${seen[${host}]}"
      continue
    fi
    seen["${host}"]="${name}"

    if port.busy "${host}"; then
      warn "${name}=${value}: la porta host ${host} è in ascolto; va bene solo se è il deployment che stai aggiornando"
      continue
    fi
    ok "${name}=${value}"
  done < <(env.port_maps "$@")
}

check.extras() {
  local dir
  dir="$(dirname "${ENV_FILE}")"
  [[ ! -f "${dir}/.env.app" ]]  || ok ".env.app presente: le sue variabili passano ai container web e migrate"
  [[ ! -f "${dir}/local.yml" ]] || ok "local.yml presente: viene applicato per ultimo al compose"
}

check.release() {
  [[ -f "${PKG_DIR}/MANIFEST.txt" ]] || return 0

  local expected actual
  expected="$(sed -n 's/^ubuntu:[[:space:]]*//p' "${PKG_DIR}/MANIFEST.txt")"
  [[ -n "${expected}" ]] || return 0

  if command -v docker > /dev/null 2>&1; then
    ok "Docker già installato: gli installer del pacchetto non servono"
    return 0
  fi

  if [[ ! -f "${PKG_DIR}/engine/Packages.gz" ]]; then
    fail "Docker non è installato e il pacchetto non contiene gli installer"
    return 0
  fi

  actual="$(. /etc/os-release 2>/dev/null && echo "${VERSION_ID:-}")"
  if [[ -z "${actual}" ]]; then
    warn "release della macchina non leggibile da /etc/os-release; gli installer sono per Ubuntu ${expected}"
    return 0
  fi

  if [[ "${actual}" != "${expected}" ]]; then
    fail "gli installer di Docker sono per Ubuntu ${expected}, la macchina è ${actual}: serve un pacchetto costruito con --release ${actual}"
    return 0
  fi
  ok "Ubuntu ${actual} come gli installer di Docker"
}

check.disk() {
  local tarball needed_kb free_kb root
  tarball="$(find "${PKG_DIR}/images" -maxdepth 1 -name 'quindi-images-*.tar.gz' 2>/dev/null | head -n 1)"
  [[ -n "${tarball}" ]] || return 0

  root="${DOCKER_ROOT_DEFAULT}"
  if command -v docker > /dev/null 2>&1; then
    root="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo "${DOCKER_ROOT_DEFAULT}")"
  fi
  while [[ ! -d "${root}" ]]; do root="$(dirname "${root}")"; done

  needed_kb=$(( $(stat -c %s "${tarball}") * 3 / 1024 ))
  free_kb="$(df -Pk "${root}" | awk 'NR==2 {print $4}')"

  if [[ "${free_kb}" -lt "${needed_kb}" ]]; then
    warn "spazio libero su ${root}: $((free_kb / 1024)) MB, le immagini ne chiedono circa $((needed_kb / 1024)) MB"
    return 0
  fi
  ok "spazio libero su ${root}: $((free_kb / 1024)) MB"
}

check.compose() {
  if ! docker compose version > /dev/null 2>&1; then
    warn "docker compose non disponibile: il rendering dei compose viene verificato dopo l'installazione di Docker"
    return 0
  fi

  local merged report
  merged="$(mktemp)"
  cat "${OPS_DIR}/.env" "${ENV_FILE}" > "${merged}"

  if ! report="$(docker compose --project-directory "${OPS_DIR}" --env-file "${merged}" -f "${OPS_DIR}/10.prod.yml" config -q 2>&1)"; then
    fail "i compose non renderizzano con questo .env: ${report}"
  else
    ok "i compose renderizzano con questo .env"
  fi
  rm -f "${merged}"
}

check.volumes() {
  docker info > /dev/null 2>&1 || return 0

  local project
  project="$(env.get "${ENV_FILE}" COMPOSE_PROJECT_NAME)"
  [[ -n "${project}" ]] || project="$(env.get "${OPS_DIR}/.env" COMPOSE_PROJECT_NAME)"
  [[ "${project}" =~ ${PROJECT_NAME_PATTERN} ]] || return 0

  if docker volume inspect "${project}_postgres_data" > /dev/null 2>&1; then
    warn "volume ${project}_postgres_data esistente: POSTGRES_PASSWORD deve essere la password già in uso nel database, vedi README § Aggiornamento"
  else
    ok "prima installazione del progetto ${project}: nessun volume esistente"
  fi
}

summary.print() {
  echo
  if [[ "${ERRORS}" -gt 0 ]]; then
    echo "Configurazione non valida: ${ERRORS} errori, ${WARNINGS} avvisi."
    exit 1
  fi
  if [[ "${WARNINGS}" -gt 0 ]]; then
    echo "Configurazione valida con ${WARNINGS} avvisi."
    return 0
  fi
  echo "Configurazione valida."
}

main "$@"
