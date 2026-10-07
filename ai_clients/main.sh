#!/bin/bash
# Top-level AI clients router.
# Auto-discovers clients via ai_clients/*/main.sh.
# Usage:
#   ./main.sh                        — interactive client menu
#   ./main.sh all                    — run all clients (all steps each)
#   ./main.sh claude                 — interactive step menu for claude
#   ./main.sh claude all             — all steps for claude
#   ./main.sh claude settings rules  — specific steps for claude

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/lib/utils.sh"

# Display name overrides: directory key → human label.
# Add an entry here for each client whose directory name does not read well when capitalised.
declare -A CLIENT_NAMES=(
    ["claude"]="Claude Code"
    ["codex"]="OpenAI Codex CLI"
    ["qwen"]="Qwen Code"
    ["copilot"]="GitHub Copilot CLI"
    ["kimi"]="Kimi Code CLI"
)

# ── Discovery ──────────────────────────────────────────────────────────────────

discover_clients() {
    for path in "$SCRIPT_DIR"/*/main.sh; do
        [[ -f "$path" ]] || continue
        printf '%s\n' "$(basename "$(dirname "$path")")"
    done
}

get_display_name() {
    local key="$1"
    echo "${CLIENT_NAMES[$key]:-${key^}}"
}

# ── Delegation ─────────────────────────────────────────────────────────────────

run_client() {
    local key="$1"; shift
    local client_main="$SCRIPT_DIR/$key/main.sh"

    if [[ ! -f "$client_main" ]]; then
        print_status "error" "Unknown client: $key"
        exit 1
    fi

    print_status "section" "$(get_display_name "$key") SETUP"
    bash "$client_main" "$@"
}

# ── Interactive menu ───────────────────────────────────────────────────────────

show_menu() {
    local clients=("$@")
    echo ""
    echo -e "${MAGENTA}========================================${NC}"
    echo -e "${MAGENTA} AI CLIENTS SETUP — Select client${NC}"
    echo -e "${MAGENTA}========================================${NC}"
    echo ""
    local i=1
    for key in "${clients[@]}"; do
        echo "  $i) $(get_display_name "$key")"
        (( i++ ))
    done
    echo ""
    echo "  a) All of the above"
    echo "  q) Quit"
    echo ""
}

interactive_menu() {
    local clients=("$@")

    while true; do
        show_menu "${clients[@]}"
        read -rp "Enter choice: " input || [[ -n "$input" ]] || { print_status "info" "No input (stdin closed); exiting."; exit 0; }

        case "$input" in
            q|Q) print_status "info" "Aborted."; exit 0 ;;
            a|A)
                for key in "${clients[@]}"; do run_client "$key" all; done
                break
                ;;
            *)
                if [[ "$input" =~ ^[0-9]+$ ]] && (( input >= 1 && input <= ${#clients[@]} )); then
                    run_client "${clients[$((input-1))]}"
                    break
                else
                    print_status "error" "Invalid choice: $input"
                fi
                ;;
        esac
    done
}

# ── Entry point ────────────────────────────────────────────────────────────────

main() {
    local clients=()
    mapfile -t clients < <(discover_clients)

    if [[ ${#clients[@]} -eq 0 ]]; then
        print_status "error" "No AI clients found under $SCRIPT_DIR"
        print_status "info"  "Each client needs a main.sh at ai_clients/<name>/main.sh"
        exit 1
    fi

    if [[ $# -eq 0 ]]; then
        interactive_menu "${clients[@]}"
    elif [[ "$1" == "all" ]]; then
        for key in "${clients[@]}"; do run_client "$key" all; done
    else
        local client="$1"; shift
        run_client "$client" "$@"
    fi
}

main "$@"
