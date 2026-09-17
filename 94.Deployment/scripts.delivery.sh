#!/usr/bin/env bash
set -euo pipefail

BASE_URL="https://lucasartore.github.io/test-deploy-report/"

scripts=(
    check.sh
    configure.sh
    dependencies.install.sh
    deploy.lib.sh
    deploy.sh
    env.lib.sh
    healthcheck.sh
    index.sh
    install.offline.sh
    scripts.delivery.sh
)

main() {
    echo "⬇️  Downloading scripts..."

    for s in "${scripts[@]}"; do
        rm -f "$s"
        curl -fsSL "${BASE_URL}${s}" -o "$s"
        chmod +x "$s"
    done

    echo "✅ Scripts downloaded"
    echo

    read -rp "🚀 All scripts downloaded... would you like to proceed on to the index? [Y/N] " answer < /dev/tty
    case "$answer" in
        [Yy]|[Yy][Ee][Ss])
            echo "▶️  Proceeding to index.sh..."
            ./index.sh < /dev/tty
            ;;
        *)
            echo "🛑 Stopping here."
            ;;
    esac
}

main "$@"
