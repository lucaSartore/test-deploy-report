#!/usr/bin/env bash

# Ask the operator for the values the package needs and write the .env file.
# Shipped inside the offline package next to install.sh.

set -euo pipefail

PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPS_DIR="${OPS_DIR:-${PKG_DIR}/ops}"
ENV_FILE="${ENV_FILE:-${PKG_DIR}/.env}"
DEFAULTS="false"

# shellcheck source=94.Deploy/env.lib.sh
source "${PKG_DIR}/env.lib.sh"

declare -a NAMES=()
declare -A VALUES=()

usage() {
  cat <<'EOF'
Uso: ./configure.sh [env-file] [opzioni]

  --defaults   accetta tutti i valori proposti senza chiedere
  -h, --help   questo aiuto

Senza env-file scrive il .env accanto allo script. Se il file esiste già, i
valori correnti sono proposti come default. I segreti mancanti vengono
generati a caso: Invio accetta il valore proposto.
EOF
}

main() {
  args.parse "$@"

  local -a files
  mapfile -t files < <(compose.files "${OPS_DIR}")

  intro.print

  ask.project
  ask.secrets "${files[@]}"
  ask.ports "${files[@]}"

  summary.print
  confirm.write
  env.write

  echo
  echo "Configurazione scritta in «${ENV_FILE}»."
  echo "Prossimo passo: sudo ./install.sh"
}

args.parse() {
  while [[ $# -gt 0 ]]; do
    case "${1}" in
      -h|--help)   usage; exit 0 ;;
      --defaults)  DEFAULTS="true"; shift ;;
      -*)          echo "Opzione sconosciuta: ${1}" >&2; usage >&2; exit 1 ;;
      *)           ENV_FILE="${1}"; shift ;;
    esac
  done

  if [[ ! -f "${OPS_DIR}/10.prod.yml" ]]; then
    echo "Pacchetto incompleto: manca «${OPS_DIR}/10.prod.yml»." >&2
    exit 1
  fi

  if [[ -e "${ENV_FILE}" && ( ! -r "${ENV_FILE}" || ! -w "${ENV_FILE}" ) ]]; then
    echo "«${ENV_FILE}» appartiene a un altro utente: rilancia con sudo." >&2
    exit 1
  fi
}

intro.print() {
  echo "Configurazione di Quindi"
  echo
  if [[ -f "${ENV_FILE}" ]]; then
    echo "Trovato «${ENV_FILE}»: i valori correnti sono proposti come default."
  else
    echo "Per ogni voce Invio accetta il valore fra parentesi quadre."
  fi
  echo
}

ask.project() {
  local current
  current="$(env.get "${ENV_FILE}" COMPOSE_PROJECT_NAME)"
  ask COMPOSE_PROJECT_NAME "${current:-quindi}" project.reject
}

ask.secrets() {
  local name current
  local -a names
  mapfile -t names < <(env.required "$@")

  echo
  echo "Segreti dello stack"
  for name in "${names[@]}"; do
    current="$(env.get "${ENV_FILE}" "${name}")"
    [[ -n "${current}" ]] || current="$(secret.generate "${name}")"
    ask "${name}" "${current}" "secret.reject ${name}"
  done
}

ask.ports() {
  local line name current
  local -a lines
  mapfile -t lines < <(env.port_maps "$@")

  echo
  echo "Porte pubblicate sull'host"
  for line in "${lines[@]}"; do
    name="${line%%=*}"
    current="$(env.get "${ENV_FILE}" "${name}")"
    ask "${name}" "${current:-${line#*=}}" port_map.reject
  done
}

# Arguments:
# $1: variable name
# $2: proposed value
# $3: validator, prints a reason to refuse the value
ask() {
  local hint value reason
  hint="$(var.hint "${1}")"

  echo
  [[ -z "${hint}" ]] || echo "  ${1}: ${hint}"

  while true; do
    if [[ "${DEFAULTS}" == "true" ]]; then
      value="${2}"
      echo "  ${1} [${2}]: ${2}"
    else
      read -r -p "  ${1} [${2}]: " value || value=""
      [[ -n "${value}" ]] || value="${2}"
    fi

    reason="$(${3} "${value}")"
    if [[ -z "${reason}" ]]; then
      break
    fi

    echo "  Valore rifiutato: ${reason}." >&2
    if [[ "${DEFAULTS}" == "true" ]]; then
      exit 1
    fi
  done

  NAMES+=("${1}")
  VALUES["${1}"]="${value}"
}

# Arguments:
# $1: value
project.reject() {
  [[ "${1}" =~ ${PROJECT_NAME_PATTERN} ]] || echo "ammessi solo minuscole, cifre, trattini e underscore, con una lettera o cifra all'inizio"
}

summary.print() {
  local name
  echo
  echo "Riepilogo"
  for name in "${NAMES[@]}"; do
    printf '  %-24s %s\n' "${name}" "${VALUES[${name}]}"
  done
  echo
}

confirm.write() {
  [[ "${DEFAULTS}" != "true" ]] || return 0

  local answer
  read -r -p "Scrivo «${ENV_FILE}»? [S/n] " answer || answer=""
  case "${answer}" in
    ""|s|S|y|Y) return 0 ;;
    *) echo "Nessun file scritto."; exit 1 ;;
  esac
}

env.write() {
  local name tmp
  tmp="$(mktemp "${ENV_FILE}.XXXXXX")"

  {
    echo "# Configurazione dell'installazione, scritta da configure.sh il $(date -u +%Y-%m-%dT%H:%M:%SZ)."
    echo "# Rilancia ./configure.sh per modificarla: i valori correnti sono proposti come default."
    for name in "${NAMES[@]}"; do
      echo "${name}=${VALUES[${name}]}"
    done
    env.extra_lines
  } > "${tmp}"

  chmod 600 "${tmp}"
  mv "${tmp}" "${ENV_FILE}"
}

env.extra_lines() {
  [[ -f "${ENV_FILE}" ]] || return 0

  local line name first="true"
  while read -r line || [[ -n "${line}" ]]; do
    [[ "${line}" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)= ]] || continue
    name="${BASH_REMATCH[1]}"
    [[ -z "${VALUES[${name}]+x}" ]] || continue

    if [[ "${first}" == "true" ]]; then
      echo
      echo "# Voci conservate dal file precedente."
      first="false"
    fi
    echo "${line}"
  done < "${ENV_FILE}"
}

main "$@"
