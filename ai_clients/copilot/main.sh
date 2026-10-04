#!/bin/bash
# GitHub Copilot CLI setup orchestrator.
# Run with no args for an interactive menu, or pass step names directly:
#   ./main.sh all
#   ./main.sh agents_md

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/../lib/utils.sh"
source "$SCRIPT_DIR/../lib/shared_agents_md.sh"
# COPILOT_HOME is the CLI's own override env var (defaults to ~/.copilot);
# respecting it here keeps the deploy target in sync with what Copilot reads.
COPILOT_DIR="${COPILOT_HOME:-$HOME/.copilot}"

# ── Step registry ─────────────────────────────────────────────────────────────
# Each entry: "key|label"

STEPS=(
    "agents_md|Install shared instructions (copilot-instructions.md)"
)

dispatch_step() {
    local key="$1"
    case "$key" in
        # Copilot CLI does not read AGENTS.md at the user level — its global
        # instructions file is copilot-instructions.md (verified 2026-09-13,
        # GitHub Docs: "Adding custom instructions for GitHub Copilot CLI").
        agents_md) install_shared_agents_md "$COPILOT_DIR/copilot-instructions.md" ;;
        *) print_status "error" "Unknown step: $key"; return 1 ;;
    esac
}

# ── Interactive menu ───────────────────────────────────────────────────────────

show_menu() {
    echo ""
    echo -e "${MAGENTA}========================================${NC}"
    echo -e "${MAGENTA} GITHUB COPILOT CLI SETUP — Select steps${NC}"
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
        read -rp "Enter numbers separated by spaces (e.g. 1 2), or a/q: " input || [[ -n "$input" ]] || { print_status "info" "No input (stdin closed); exiting."; exit 0; }

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
    print_status "section" "GITHUB COPILOT CLI CONFIGURATION SCRIPT"
    print_status "info" "Log: $LOG_FILE"
    print_status "info" "Copilot dir: $COPILOT_DIR"

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
    print_status "success" "GitHub Copilot CLI configuration applied to: $COPILOT_DIR"
}

main "$@"
