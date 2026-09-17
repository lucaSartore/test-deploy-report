#!/usr/bin/env bash

# The variables a release's compose files read from the operator's .env.
# Sourced by offline.bundle.sh when it renders .env.sample and by the scripts
# shipped in the package (configure.sh, check.sh). Sourced, never executed.

# shellcheck disable=SC2034
PROJECT_NAME_PATTERN='^[a-z0-9][a-z0-9_-]*$'
PORT_MAP_PATTERN='^[0-9]+:[0-9]+$'
HEX64_PATTERN='^[0-9a-fA-F]{64}$'

# Arguments:
# $1: ops directory holding 10.prod.yml
compose.files() {
  local f
  printf '%s\n' "${1}/10.prod.yml"
  while read -r f || [[ -n "${f}" ]]; do
    printf '%s\n' "${1}/${f}"
  done < <(sed -nE "s|^[[:space:]]*-[[:space:]]*'?\./([^'[:space:]]+)'?[[:space:]]*$|\1|p" "${1}/10.prod.yml")
}

# Arguments: compose files
env.required() {
  { grep -ohE '\$\{[A-Z_][A-Z0-9_]*:\?[^}]*\}' "$@" || true; } \
    | sed -E 's/\$\{([A-Z_][A-Z0-9_]*):\?.*/\1/' \
    | sort -u
}

# Arguments: compose files
env.port_maps() {
  { grep -ohE '\$\{[A-Z_][A-Z0-9_]*_PORT_MAP:-[0-9]+:[0-9]+\}' "$@" || true; } \
    | sed -E 's/\$\{([A-Z_][A-Z0-9_]*_PORT_MAP):-([0-9]+:[0-9]+)\}/\1=\2/' \
    | sort -u
}

# Arguments:
# $1: env file
# $2: variable name
env.get() {
  [[ -f "${1}" ]] || return 0
  sed -nE "s/^[[:space:]]*${2}=(.*)$/\1/p" "${1}" \
    | tail -n 1 \
    | sed -E "s/^\"(.*)\"$/\1/; s/^'(.*)'$/\1/"
}

# Arguments:
# $1: env file
# $2: variable name
env.has() {
  [[ -f "${1}" ]] && grep -qE "^[[:space:]]*${2}=" "${1}"
}

# Arguments:
# $1: variable name
var.hint() {
  case "${1}" in
    COMPOSE_PROJECT_NAME)  echo "nome del progetto Compose e prefisso dei volumi: cambiarlo dopo la prima installazione fa ripartire il sistema con dati vuoti" ;;
    POSTGRES_PASSWORD)     echo "password dell'utente Postgres, fissata alla prima inizializzazione del volume" ;;
    S3_SECRET_KEY)         echo "chiave segreta S3 dello storage, fissata alla creazione del bucket" ;;
    GARAGE_RPC_SECRET)     echo "segreto RPC di Garage, 64 caratteri esadecimali" ;;
    GARAGE_ADMIN_TOKEN)    echo "token dell'API di amministrazione di Garage" ;;
    GARAGE_METRICS_TOKEN)  echo "token dell'endpoint metriche di Garage" ;;
    *_PORT_MAP)            echo "porta pubblicata sull'host, nella forma <host>:<container>" ;;
    *)                     echo "" ;;
  esac
}

# Arguments:
# $1: variable name
secret.generate() {
  case "${1}" in
    GARAGE_RPC_SECRET) rand.hex 32 ;;
    *)                 rand.hex 16 ;;
  esac
}

# Arguments:
# $1: number of random bytes
rand.hex() {
  if command -v openssl > /dev/null 2>&1; then
    openssl rand -hex "${1}"
  else
    od -An -N"${1}" -tx1 /dev/urandom | tr -d ' \n'
  fi
}

# Prints the reason the value is not acceptable, nothing when it is.
# Arguments:
# $1: variable name
# $2: value
secret.reject() {
  if [[ -z "${2}" ]]; then
    echo "il valore è vuoto"
    return 0
  fi

  case "${1}" in
    GARAGE_RPC_SECRET)
      [[ "${2}" =~ ${HEX64_PATTERN} ]] || echo "servono esattamente 64 caratteri esadecimali (openssl rand -hex 32)"
      ;;
  esac
}

# Prints why the value is weak, nothing when it is not.
# Arguments:
# $1: value
secret.weak() {
  case "${1}" in
    pass|dev-*|*-dev-*|dead0*) echo "è un valore di sviluppo" ;;
    *) [[ "${#1}" -ge 16 ]] || echo "ha meno di 16 caratteri" ;;
  esac
}

# Prints the reason the mapping is not acceptable, nothing when it is.
# Arguments:
# $1: value
port_map.reject() {
  if [[ ! "${1}" =~ ${PORT_MAP_PATTERN} ]]; then
    echo "serve la forma <host>:<container>, per esempio 9000:8080"
    return 0
  fi

  local host="${1%%:*}" container="${1##*:}"
  if [[ "${host}" -lt 1 || "${host}" -gt 65535 || "${container}" -lt 1 || "${container}" -gt 65535 ]]; then
    echo "le porte vanno da 1 a 65535"
  fi
}

# Arguments:
# $1: host port
port.busy() {
  command -v ss > /dev/null 2>&1 || return 1
  ss -Hltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${1}$"
}
