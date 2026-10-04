#!/bin/bash
# Kimi Code CLI (Moonshot AI, @moonshot-ai/kimi-code) setup orchestrator.
# Run with no args for an interactive menu, or pass step names directly:
#   ./main.sh all
#   ./main.sh agents_md
#
# UNVERIFIED (dotfiles-linux-dev#346): Kimi Code CLI is not installed on this
# machine. KIMI_CODE_HOME and the AGENTS.md delivery path below come from
# the official docs (moonshotai.github.io/kimi-code) rather than a real
# install — confirm against a real `kimi` install before relying on this.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/../lib/utils.sh"
source "$SCRIPT_DIR/../lib/shared_agents_md.sh"
# KIMI_CODE_HOME is the CLI's own override env var (defaults to
# ~/.kimi-code); respecting it here keeps the deploy target in sync with
# what Kimi Code reads.
KIMI_DIR="${KIMI_CODE_HOME:-$HOME/.kimi-code}"

# ── Step registry ─────────────────────────────────────────────────────────────
# Each entry: "key|label"

STEPS=(
    "agents_md|Install shared AGENTS.md"
)

dispatch_step() {
    local key="$1"
    case "$key" in
        agents_md) install_shared_agents_md "$KIMI_DIR/AGENTS.md" ;;
        *) print_status "error" "Unknown step: $key"; return 1 ;;
    esac
}

# ── Interactive menu ───────────────────────────────────────────────────────────

show_menu() {
    echo ""
    echo -e "${MAGENTA}========================================${NC}"
    echo -e "${MAGENTA} KIMI CODE CLI SETUP — Select steps${NC}"
    echo -e "${MAGENTA}========================================${NC}"
    echo ""
    local i=1
    for entry in "${STEPS[@]}"; do
        local label="${entry#*|}"
        echo "  $i) $label"
        (( i++ ))
    done
    echo ""
    echo "  a) All of the above"
    echo "  q) Quit"
    echo ""
}

interactive_menu() {
    local selected=()

    while true; do
        show_menu
        read -rp "Enter numbers separated by spaces (e.g. 1 2), or a/q: " input || { print_status "info" "No input (stdin closed); exiting."; exit 0; }

        case "$input" in
            q|Q) print_status "info" "Aborted."; exit 0 ;;
            a|A) selected=(); for entry in "${STEPS[@]}"; do selected+=("${entry%%|*}"); done; break ;;
            *)
                selected=()
                local valid=true
                for token in $input; do
                    if [[ "$token" =~ ^[0-9]+$ ]] && (( token >= 1 && token <= ${#STEPS[@]} )); then
                        selected+=("${STEPS[$((token-1))]%%|*}")
                    else
                        print_status "error" "Invalid choice: $token"
                        valid=false
                        break
                    fi
                done
                $valid && [ ${#selected[@]} -gt 0 ] && break
                ;;
        esac
    done

    echo ""
    for key in "${selected[@]}"; do
        dispatch_step "$key"
    done
}

# ── Entry point ───────────────────────────────────────────────────────────────

main() {
    print_status "section" "KIMI CODE CLI CONFIGURATION SCRIPT"
    print_status "info" "Log: $LOG_FILE"
    print_status "info" "Kimi dir: $KIMI_DIR"

    if [ $# -eq 0 ]; then
        interactive_menu
    elif [ "$1" = "all" ]; then
        for entry in "${STEPS[@]}"; do
            dispatch_step "${entry%%|*}"
        done
    else
        for key in "$@"; do
            dispatch_step "$key"
        done
    fi

    print_status "section" "DONE"
    print_status "success" "Kimi Code CLI configuration applied to: $KIMI_DIR"
}

main "$@"
