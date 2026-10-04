#!/bin/bash
# Claude Code setup orchestrator.
# Run with no args for an interactive menu, or pass step names directly:
#   ./main.sh all
#   ./main.sh settings slash_commands claude_md rules
#   ./main.sh marketplaces plugins

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/../lib/utils.sh"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
source "$SCRIPT_DIR/lib/prerequisites.sh"
source "$SCRIPT_DIR/lib/settings.sh"
source "$SCRIPT_DIR/lib/hooks.sh"
source "$SCRIPT_DIR/lib/marketplaces.sh"
source "$SCRIPT_DIR/lib/plugins.sh"
source "$SCRIPT_DIR/lib/slash_commands.sh"
source "$SCRIPT_DIR/lib/skills.sh"
source "$SCRIPT_DIR/lib/agents.sh"
source "$SCRIPT_DIR/lib/claude_md.sh"
source "$SCRIPT_DIR/../lib/shared_agents_md.sh"
source "$SCRIPT_DIR/lib/rules.sh"
source "$SCRIPT_DIR/lib/mcp_servers.sh"
source "$SCRIPT_DIR/lib/profiles.sh"
source "$SCRIPT_DIR/lib/env.sh"
source "$SCRIPT_DIR/lib/claude_mem.sh"
source "$SCRIPT_DIR/lib/prune.sh"

# ── Step registry ─────────────────────────────────────────────────────────────
# Each entry: "key|label|function_or_block"
# Steps that are pure function calls map directly; compound steps use helpers.

run_marketplaces() {
    register_marketplace "claude-plugins-official" "anthropics/claude-plugins-official"
    register_marketplace "claude-skills"           "anthropics/skills"
    register_marketplace "claude-hud"              "jarrodwatts/claude-hud"
    register_marketplace "context-mode"            "mksglu/context-mode"
    register_marketplace "claude-mem"              "thedotmack/claude-mem"
    register_marketplace "ponytail"                "DietrichGebert/ponytail"
}

run_plugins() {
    # Explicit removals — demote before promoting to enforce desired state
    demote_plugin_from_user_scope "frontend-design@claude-plugins-official"

    promote_plugin_to_user_scope "superpowers@claude-plugins-official"        "superpowers"        "claude-plugins-official"
    promote_plugin_to_user_scope "claude-hud@claude-hud"                      "claude-hud"         "claude-hud"
    # codex-plugin-cc / copilot-plugin-cc removed (dotfiles-linux-dev#147): no plugin by
    # that name exists in claude-plugins-official (verified against all 291
    # published plugins) or any other registered marketplace. Codex CLI is
    # installed as a real binary via ai_clients/codex/ instead (dotfiles-linux-dev#145);
    # no equivalent Copilot or Kimi runtime exists to wire up.
    # LSPs — typescript-lsp covers JS, TS, JSX (.jsx), and TSX (.tsx)
    promote_plugin_to_user_scope "typescript-lsp@claude-plugins-official"     "typescript-lsp"     "claude-plugins-official"
    promote_plugin_to_user_scope "html-lsp@claude-plugins-official"           "html-lsp"           "claude-plugins-official"
    promote_plugin_to_user_scope "css-lsp@claude-plugins-official"            "css-lsp"            "claude-plugins-official"
    promote_plugin_to_user_scope "mssql-lsp@claude-plugins-official"          "mssql-lsp"          "claude-plugins-official"
    promote_plugin_to_user_scope "postgres-lsp@claude-plugins-official"       "postgres-lsp"       "claude-plugins-official"
    promote_plugin_to_user_scope "sqlite-lsp@claude-plugins-official"         "sqlite-lsp"         "claude-plugins-official"
    promote_plugin_to_user_scope "mysql-lsp@claude-plugins-official"          "mysql-lsp"          "claude-plugins-official"
    promote_plugin_to_user_scope "mariadb-lsp@claude-plugins-official"        "mariadb-lsp"        "claude-plugins-official"
    promote_plugin_to_user_scope "mongodb-lsp@claude-plugins-official"        "mongodb-lsp"        "claude-plugins-official"
    promote_plugin_to_user_scope "json-lsp@claude-plugins-official"           "json-lsp"           "claude-plugins-official"
    promote_plugin_to_user_scope "yaml-lsp@claude-plugins-official"           "yaml-lsp"           "claude-plugins-official"
    promote_plugin_to_user_scope "toml-lsp@claude-plugins-official"           "toml-lsp"           "claude-plugins-official"
    # Skills
    promote_plugin_to_user_scope "security-guidance@claude-plugins-official"  "security-guidance"  "claude-plugins-official"
    promote_plugin_to_user_scope "code-review@claude-plugins-official"         "code-review"        "claude-plugins-official"
    promote_plugin_to_user_scope "code-simplifier@claude-plugins-official"     "code-simplifier"    "claude-plugins-official"
    promote_plugin_to_user_scope "feature-dev@claude-plugins-official"         "feature-dev"        "claude-plugins-official"
    promote_plugin_to_user_scope "learning-output-style@claude-plugins-official" "learning-output-style" "claude-plugins-official"
    promote_plugin_to_user_scope "pr-review-toolkit@claude-plugins-official"   "pr-review-toolkit"  "claude-plugins-official"
    promote_plugin_to_user_scope "supabase-postgres-best-practices@claude-plugins-official" "supabase-postgres-best-practices" "claude-plugins-official"
    promote_plugin_to_user_scope "senior-prompt-engineer@claude-plugins-official"           "senior-prompt-engineer"           "claude-plugins-official"
    promote_plugin_to_user_scope "clean-code@claude-plugins-official"                       "clean-code"                       "claude-plugins-official"
    # Context mode — standalone GitHub repo, bootstrapped automatically
    bootstrap_plugin "context-mode@context-mode" "context-mode" "context-mode" "mksglu/context-mode"
    # claude-mem — standalone GitHub repo, bootstrapped automatically
    bootstrap_plugin "claude-mem@claude-mem" "claude-mem" "claude-mem" "thedotmack/claude-mem"
    # ponytail — lazy senior dev mode; standalone GitHub repo, bootstrapped automatically
    bootstrap_plugin "ponytail@ponytail" "ponytail" "ponytail" "DietrichGebert/ponytail"
}

STEPS=(
    "settings|Configure settings.json"
    "hooks|Install hook scripts (SessionStart context, ...)"
    "env|Configure .env (backup path, etc.)"
    "slash_commands|Install custom slash commands"
    "skills|Install user skills"
    "agents|Install pipeline agents"
    "claude_md|Install global CLAUDE.md"
    "shared_agents_md|Install shared agent-agnostic AGENTS.md"
    "rules|Install language rules (python.md, ...)"
    "marketplaces|Register plugin marketplaces"
    "plugins|Promote plugins to user scope"
    "mcp_servers|Install MCP servers"
    "profiles|Install cheap-brain session profiles (deepseek, ...)"
    "claude_mem|Configure claude-mem mode"
    "prune|Prune orphaned artifacts (asks before removing)"
)

dispatch_step() {
    local key="$1"
    case "$key" in
        settings)       configure_settings ;;
        hooks)          install_hooks ;;
        env)            configure_env ;;
        slash_commands) install_slash_commands ;;
        skills)         install_skills ;;
        agents)         install_agents ;;
        claude_md)      install_claude_md ;;
        shared_agents_md) install_shared_agents_md "$CLAUDE_DIR/AGENTS.md" ;;
        rules)          install_rules ;;
        marketplaces)   print_status "section" "REGISTERING MARKETPLACES"    && run_marketplaces ;;
        plugins)        print_status "section" "PROMOTING PLUGINS TO USER SCOPE" && run_plugins ;;
        mcp_servers)    install_mcp_servers ;;
        profiles)       install_profiles ;;
        claude_mem)     configure_claude_mem ;;
        prune)          prune_orphans ;;
        *) print_status "error" "Unknown step: $key"; return 1 ;;
    esac
}

# ── Interactive menu ───────────────────────────────────────────────────────────

show_menu() {
    echo ""
    echo -e "${MAGENTA}========================================${NC}"
    echo -e "${MAGENTA} CLAUDE CODE SETUP — Select steps${NC}"
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
        read -rp "Enter numbers separated by spaces (e.g. 1 3), or a/q: " input || { print_status "info" "No input (stdin closed); exiting."; exit 0; }

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
    print_status "section" "CLAUDE CODE CONFIGURATION SCRIPT"
    print_status "info" "Log: $LOG_FILE"
    print_status "info" "Claude dir: $CLAUDE_DIR"

    check_prerequisites

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
    print_status "success" "Claude Code configuration applied to: $CLAUDE_DIR"
    print_status "info"    "Restart Claude Code for all changes to take effect"
}

main "$@"
