#!/usr/bin/env bash

# Verify that the deployed stack is up and answering. Shipped inside the
# offline package next to install.sh, and run by it after every deployment.

set -euo pipefail

PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOYMENT_DIR="${DEPLOYMENT_DIR:-${PKG_DIR}/deployments}"
TIMEOUT="${HEALTH_TIMEOUT:-180}"
WEB_SERVICE="web"
STORAGE_SERVICE="storage"
MAX_RESTARTS=3

FAILURES=0
declare -a COMPOSE=()
declare -A ONESHOT=()

usage() {
  cat <<'EOF'
Uso: sudo ./healthcheck.sh [opzioni]

  --timeout <s>   attesa massima perché lo stack risponda (default: 180)
  -h, --help      questo aiuto

Controlla il deployment corrente in deployments/current: ogni servizio in
esecuzione o terminato con successo, database pronto, storage e applicazione
web che rispondono in HTTP. Esce con 1 se qualcosa non risponde entro il
tempo massimo.
EOF
}

main() {
  args.parse "$@"

  deployment.locate
  compose.command
  services.oneshot

  echo "Verifica del deployment «$(readlink -f "${DEPLOYMENT_DIR}/current")»"
  echo

  services.wait
  storage.probe
  web.probe
  web.identity

  summary.print
}

args.parse() {
  while [[ $# -gt 0 ]]; do
    case "${1}" in
      -h|--help)  usage; exit 0 ;;
      --timeout)  TIMEOUT="${2:?--timeout richiede un valore}"; shift 2 ;;
      *)          echo "Opzione sconosciuta: ${1}" >&2; usage >&2; exit 1 ;;
    esac
  done
}

ok()   { echo "  OK      ${1}"; }
warn() { echo "  AVVISO  ${1}"; }
fail() { echo "  ERRORE  ${1}"; FAILURES=$((FAILURES + 1)); }

deployment.locate() {
  if [[ ! -d "${DEPLOYMENT_DIR}/current" ]]; then
    echo "Nessun deployment in «${DEPLOYMENT_DIR}/current»: lancia prima install.sh." >&2
    exit 1
  fi

  if ! docker info > /dev/null 2>&1; then
    echo "Il demone Docker non risponde: serve root, o l'utente nel gruppo docker." >&2
    exit 1
  fi
}

compose.command() {
  local file
  COMPOSE=(docker compose)
  for file in 10.prod.yml 99.offline.yml 99.local.yml; do
    [[ -f "${DEPLOYMENT_DIR}/current/${file}" ]] || continue
    COMPOSE+=(-f "${DEPLOYMENT_DIR}/current/${file}")
  done
}

services.oneshot() {
  local service
  while read -r service; do
    ONESHOT["${service}"]=1
  done < <("${COMPOSE[@]}" config 2>/dev/null | awk '
    /^    depends_on:/ { inside = 1; next }
    /^    [^ ]/        { inside = 0 }
    inside && /^      [^ ]+:$/ { sub(/^ +/, ""); sub(/:$/, ""); dependency = $0 }
    inside && /condition: service_completed_successfully/ { print dependency }
  ' | sort -u)
}

services.wait() {
  local waited=0 verdict
  while true; do
    verdict="$(services.verdict)"
    case "${verdict}" in
      ready) break ;;
      wait:*)
        if [[ "${waited}" -ge "${TIMEOUT}" ]]; then
          fail "dopo ${TIMEOUT}s ${verdict#wait:}"
          services.report
          summary.print
        fi
        sleep 2
        waited=$((waited + 2))
        ;;
      fail:*)
        services.report
        echo "  ${verdict#fail:}"
        summary.print
        ;;
    esac
  done

  services.report
}

services.verdict() {
  local service state code health id restarts
  while IFS=$'\t' read -r service state code health; do
    case "${state}" in
      exited)
        [[ "${code}" == "0" ]] || { echo "fail:${service} è terminato con codice ${code}: docker compose logs ${service}"; return 0; }
        [[ -n "${ONESHOT[${service}]+x}" ]] || { echo "fail:${service} è fermo: docker compose up -d lo riavvia"; return 0; }
        ;;
      running)
        id="$("${COMPOSE[@]}" ps -q "${service}")"
        restarts="$(docker inspect -f '{{.RestartCount}}' "${id}")"
        [[ "${restarts}" -lt "${MAX_RESTARTS}" ]] || { echo "fail:${service} è ripartito ${restarts} volte: docker compose logs ${service}"; return 0; }
        [[ -z "${health}" || "${health}" == "healthy" ]] || { echo "wait:${service} è ${health}"; return 0; }
        ;;
      *)
        echo "wait:${service} è ${state}"
        return 0
        ;;
    esac
  done < <(services.list)

  echo "ready"
}

services.list() {
  "${COMPOSE[@]}" ps -a --format '{{.Service}}\t{{.State}}\t{{.ExitCode}}\t{{.Health}}'
}

services.report() {
  local service state code health
  while IFS=$'\t' read -r service state code health; do
    if [[ "${state}" == "exited" && "${code}" == "0" && -n "${ONESHOT[${service}]+x}" ]]; then
      ok "${service} completato"
    elif [[ "${state}" == "exited" && "${code}" == "0" ]]; then
      fail "${service} fermo"
    elif [[ "${state}" == "exited" ]]; then
      fail "${service} terminato con codice ${code}"
    elif [[ "${state}" == "running" ]]; then
      ok "${service} in esecuzione${health:+ (${health})}"
    else
      fail "${service} ${state}"
    fi
  done < <(services.list)
}

# Arguments:
# $1: service name
service.host_port() {
  local id
  id="$("${COMPOSE[@]}" ps -q "${1}")"
  [[ -n "${id}" ]] || return 1
  docker inspect -f '{{range $p, $c := .NetworkSettings.Ports}}{{if $c}}{{(index $c 0).HostPort}}{{"\n"}}{{end}}{{end}}' "${id}" \
    | head -n 1
}

# Arguments:
# $1: host port
# $2: path
http.status() {
  if command -v curl > /dev/null 2>&1; then
    curl -s -o /dev/null -m 5 -w '%{http_code}' "http://127.0.0.1:${1}${2}" || true
    return 0
  fi

  # shellcheck disable=SC2016
  timeout 5 bash -c '
    exec 3<>"/dev/tcp/127.0.0.1/${1}" &&
    printf "GET %s HTTP/1.0\r\nHost: localhost\r\n\r\n" "${2}" >&3 &&
    read -r _ code _ <&3 && echo "${code}"
  ' _ "${1}" "${2}" 2>/dev/null || echo 000
}

# Arguments:
# $1: service name
# $2: path
# $3: accepted status codes, regex
# $4: description
http.wait() {
  local port waited=0 status
  port="$(service.host_port "${1}")" || port=""
  if [[ -z "${port}" ]]; then
    fail "${4}: nessuna porta pubblicata per ${1}"
    return 0
  fi

  while true; do
    status="$(http.status "${port}" "${2}")"
    if [[ "${status}" =~ ${3} ]]; then
      ok "${4} risponde ${status} su http://127.0.0.1:${port}${2}"
      return 0
    fi
    if [[ "${waited}" -ge "${TIMEOUT}" ]]; then
      fail "${4} risponde ${status} su http://127.0.0.1:${port}${2} dopo ${TIMEOUT}s: docker compose logs ${1}"
      return 0
    fi
    sleep 2
    waited=$((waited + 2))
  done
}

storage.probe() {
  http.wait "${STORAGE_SERVICE}" "/" '^[1-5][0-9][0-9]$' "lo storage S3"
}

web.probe() {
  http.wait "${WEB_SERVICE}" "/" '^200$' "l'applicazione web"
}

web.identity() {
  local line tag version
  line="$("${COMPOSE[@]}" logs --no-color --no-log-prefix "${WEB_SERVICE}" 2>/dev/null | grep -o 'Deployment identity: .*' | tail -n 1 || true)"
  if [[ -z "${line}" ]]; then
    warn "l'applicazione web non ha ancora scritto nel log la propria identità"
    return 0
  fi

  tag="$(echo "${line}" | sed -n 's/.*tag=\([^ ]*\).*/\1/p')"
  version="$(sed -n 's/^VERSION=//p' "${DEPLOYMENT_DIR}/current/.env" | tail -n 1)"
  if [[ -n "${version}" && "${tag}" != "v${version}" ]]; then
    warn "${line}: il pacchetto è la versione ${version}"
    return 0
  fi
  ok "${line}"
}

summary.print() {
  echo
  if [[ "${FAILURES}" -gt 0 ]]; then
    echo "Stack non operativo: ${FAILURES} controlli falliti."
    echo "Log completi: ${COMPOSE[*]} logs"
    exit 1
  fi
  echo "Stack operativo."
  exit 0
}

main "$@"
