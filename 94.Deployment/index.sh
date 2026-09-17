#!/usr/bin/env bash
set -uo pipefail

scripts=(
    scripts.delivery.sh
    dependencies.install.sh
    configure.sh
    deploy.sh
    check.sh
    healthcheck.sh
    install.offline.sh
)

# --- colors (fallback gracefully if terminal doesn't support them) ---
if [[ -t 1 ]]; then
    BOLD=$(tput bold); RESET=$(tput sgr0)
    CYAN=$(tput setaf 6); GREEN=$(tput setaf 2)
    RED=$(tput setaf 1); YELLOW=$(tput setaf 3)
else
    BOLD=""; RESET=""; CYAN=""; GREEN=""; RED=""; YELLOW=""
fi

print_menu() {
    echo
    echo "${BOLD}${CYAN}📋  Script Runner Menu${RESET}"
    echo "${CYAN}────────────────────────────${RESET}"
    for i in "${!scripts[@]}"; do
        printf "  ${YELLOW}%d${RESET})  🔹 %s\n" "$i" "${scripts[$i]}"
    done
    echo "  ${YELLOW}N${RESET})  🚪 Exit"
    echo "${CYAN}────────────────────────────${RESET}"
    echo "  ${BOLD}💡 Tip:${RESET} pass extra args after the number, e.g. ${BOLD}3 1.11.0${RESET}"
}

run_script() {
    local script="$1"
    shift
    local args=("$@")

    if [[ ! -f "$script" ]]; then
        echo "${RED}❌  '$script' not found in current directory.${RESET}"
        return
    fi

    local display_cmd="$script"
    if (( ${#args[@]} > 0 )); then
        display_cmd="$script ${args[*]}"
    fi

    if [[ ! -x "$script" ]]; then
        echo "${YELLOW}⚠️   '$script' is not executable, running with bash instead.${RESET}"
        echo "${CYAN}▶️   Running: $display_cmd${RESET}"
        bash "$script" "${args[@]}"
    else
        echo "${CYAN}▶️   Running: $display_cmd${RESET}"
        ./"$script" "${args[@]}"
    fi

    local status=$?
    if [[ $status -eq 0 ]]; then
        echo "${GREEN}✅  '$display_cmd' finished successfully (exit code $status).${RESET}"
    else
        echo "${RED}💥  '$display_cmd' failed (exit code $status).${RESET}"
    fi
}

main() {
    while true; do
        print_menu
        read -rp "$(echo -e "${BOLD}👉  Your choice: ${RESET}")" choice

        # split input into index + remaining args, e.g. "3 1.11.0" -> index=3, args=(1.11.0)
        read -ra parts <<< "$choice"
        index="${parts[0]:-}"
        extra_args=("${parts[@]:1}")

        if [[ "$index" =~ ^[Nn]$ ]]; then
            echo "${GREEN}👋  Goodbye!${RESET}"
            break
        fi

        if [[ "$index" =~ ^[0-9]+$ ]] && (( index >= 0 && index < ${#scripts[@]} )); then
            run_script "${scripts[$index]}" "${extra_args[@]}"
        else
            echo "${RED}❓  Invalid choice: '$choice'. Please try again.${RESET}"
        fi
    done
}

main "$@"
