#!/usr/bin/env bash
#
# install-deps.sh
#
# Verifies that a set of CLI dependencies are installed, and offers to
# install any that are missing. Auto-install only works on Ubuntu (apt).
#
# Dependencies checked:
#   - gh      (GitHub CLI)
#   - docker  (Docker Engine + Compose plugin)
#   - jq
#   - unzip
#

set -euo pipefail

# ------------------------------------------------------------------------
# Colors / emoji helpers
# ------------------------------------------------------------------------

readonly C_RESET='\033[0m'
readonly C_BOLD='\033[1m'
readonly C_GREEN='\033[0;32m'
readonly C_RED='\033[0;31m'
readonly C_YELLOW='\033[0;33m'
readonly C_BLUE='\033[0;34m'

info()  { printf "%b\n" "${C_BLUE}ℹ️  ${1}${C_RESET}"; }
ok()    { printf "%b\n" "${C_GREEN}✅ ${1}${C_RESET}"; }
warn()  { printf "%b\n" "${C_YELLOW}⚠️  ${1}${C_RESET}"; }
err()   { printf "%b\n" "${C_RED}❌ ${1}${C_RESET}"; }
title() { printf "\n%b\n" "${C_BOLD}${C_BLUE}🚀 ${1}${C_RESET}"; }

# ------------------------------------------------------------------------
# Utility functions
# ------------------------------------------------------------------------

# ask_yes_no "question" -> returns 0 for yes, 1 for no
ask_yes_no() {
    local prompt="$1"
    local answer

    while true; do
        read -r -p "$(printf "%b" "${C_YELLOW}❓ ${prompt} [y/N]: ${C_RESET}")" answer
        case "${answer,,}" in
            y | yes) return 0 ;;
            n | no | "") return 1 ;;
            *) warn "Please answer 'y' or 'n'." ;;
        esac
    done
}

is_ubuntu() {
    [[ -r /etc/os-release ]] || return 1
    # shellcheck disable=SC1091
    . /etc/os-release
    [[ "${ID:-}" == "ubuntu" ]]
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

apt_update_once() {
    if [[ "${APT_UPDATED:-0}" -eq 0 ]]; then
        info "Running 'sudo apt update'..."
        sudo apt update
        APT_UPDATED=1
    fi
}

# ------------------------------------------------------------------------
# Verification functions
# ------------------------------------------------------------------------

verify_gh() {
    command_exists gh
}

verify_jq() {
    command_exists jq
}

verify_unzip() {
    command_exists unzip
}

verify_docker() {
    command_exists docker && docker compose version >/dev/null 2>&1
}

# ------------------------------------------------------------------------
# Install functions
# ------------------------------------------------------------------------

install_gh() {
    info "Installing GitHub CLI (gh)..."
    apt_update_once
    sudo apt install -y gh
    ok "gh installed."
}

install_jq() {
    info "Installing jq..."
    apt_update_once
    sudo apt install -y jq
    ok "jq installed."
}

install_unzip() {
    info "Installing unzip..."
    apt_update_once
    sudo apt install -y unzip
    ok "unzip installed."
}

# Checks whether Docker's official apt source is already configured.
docker_apt_source_present() {
    [[ -f /etc/apt/sources.list.d/docker.sources ]] || \
    [[ -f /etc/apt/sources.list.d/docker.list ]] || \
    grep -Rqs "download.docker.com" /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null
}

add_docker_apt_source() {
    info "Adding Docker's official apt repository..."

    sudo apt update
    sudo apt install -y ca-certificates curl
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc

    # shellcheck disable=SC1091
    . /etc/os-release
    local codename="${UBUNTU_CODENAME:-$VERSION_CODENAME}"
    local arch
    arch="$(dpkg --print-architecture)"

    sudo tee /etc/apt/sources.list.d/docker.sources > /dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${codename}
Components: stable
Architectures: ${arch}
Signed-By: /etc/apt/keyrings/docker.asc
EOF

    sudo apt update
    APT_UPDATED=1
    ok "Docker apt repository added."
}

install_docker() {
    if ! docker_apt_source_present; then
        warn "Docker's official apt repository is not configured."
        if ask_yes_no "Add Docker's official apt repository now?"; then
            add_docker_apt_source
        else
            err "Cannot install Docker without its official apt repository. Skipping."
            return 1
        fi
    else
        ok "Docker's official apt repository is already configured."
    fi

    info "Installing Docker Engine, CLI, containerd, buildx and compose plugin..."
    apt_update_once
    sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    ok "Docker installed."
}

# ------------------------------------------------------------------------
# Orchestration
# ------------------------------------------------------------------------

# process_dependency <name> <verify_fn> <install_fn>
process_dependency() {
    local name="$1"
    local verify_fn="$2"
    local install_fn="$3"

    info "Checking ${name}..."
    if "$verify_fn"; then
        ok "${name} is already installed."
        return 0
    fi

    warn "${name} is not installed."
    if ask_yes_no "Install ${name} now?"; then
        if "$install_fn"; then
            ok "${name} setup complete."
        else
            err "${name} installation failed or was skipped."
            return 1
        fi
    else
        warn "Skipping ${name}."
        return 1
    fi
}

main() {
    APT_UPDATED=0

    title "Dependency check: gh, docker (+ compose), jq, unzip"

    if ! is_ubuntu; then
        warn "This system does not appear to be Ubuntu."
        warn "Automatic installation via apt only works on Ubuntu."
        if ! ask_yes_no "Continue anyway? (only checks will run reliably; installs may fail)"; then
            err "Aborted by user."
            exit 1
        fi
    else
        ok "Ubuntu detected."
        if ! ask_yes_no "Proceed with dependency check (and optional auto-install via apt)?"; then
            err "Aborted by user."
            exit 1
        fi
    fi

    local failures=0

    process_dependency "gh"     verify_gh     install_gh     || ((failures++))
    process_dependency "jq"     verify_jq     install_jq     || ((failures++))
    process_dependency "unzip"  verify_unzip  install_unzip  || ((failures++))
    process_dependency "docker" verify_docker install_docker || ((failures++))

    echo
    if [[ "$failures" -eq 0 ]]; then
        ok "All dependencies are satisfied. 🎉"
    else
        warn "${failures} dependency issue(s) remain unresolved."
        exit 1
    fi
}

main "$@"
