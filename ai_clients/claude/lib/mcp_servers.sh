#!/bin/bash
# Installs user-scoped MCP servers for Claude Code.
# Reads API keys from the project root .env file.

install_mcp_servers() {
    print_status "section" "INSTALLING MCP SERVERS"

    local project_root
    project_root="$(cd "$SCRIPT_DIR/../.." && pwd)"
    local env_file="$project_root/.env"

    if [ ! -f "$env_file" ]; then
        print_status "error" "No .env file found at: $env_file — skipping MCP server setup"
        return 1
    fi

    _install_context7 "$env_file"
    _install_tavily "$env_file"
    _install_playwright_mcp
    _install_notesnook "$env_file"
    _install_linear
    _install_notion
    _install_axiom
}

_install_linear() {
    # Linear ships a hosted remote MCP server authenticated via OAuth (dynamic
    # client registration) — no API key, so nothing is read from .env. The
    # browser OAuth flow runs on first use inside Claude Code (`/mcp` → Linear
    # → authenticate).
    if claude mcp list 2>/dev/null | grep -q '^linear'; then
        print_status "info" "linear MCP already registered — skipping"
        return 0
    fi

    claude mcp add --scope user \
        --transport sse \
        linear \
        "https://mcp.linear.app/sse"

    print_status "success" "linear MCP registered (SSE transport, user scope)"
    print_status "info" "Run /mcp in Claude Code to complete Linear OAuth login"
}

_install_notion() {
    # Notion ships a hosted remote MCP server authenticated via OAuth — no API
    # key, so nothing is read from .env. Same shape as _install_linear. Notion's
    # docs (developers.notion.com/guides/mcp/build-mcp-client) recommend
    # Streamable HTTP as primary with SSE as fallback; we use SSE here to match
    # the transport already proven by _install_linear. The browser OAuth flow
    # runs on first use inside Claude Code (`/mcp` → notion → authenticate).
    if claude mcp list 2>/dev/null | grep -q '^notion'; then
        print_status "info" "notion MCP already registered — skipping"
        return 0
    fi

    claude mcp add --scope user \
        --transport sse \
        notion \
        "https://mcp.notion.com/sse"

    print_status "success" "notion MCP registered (SSE transport, user scope)"
    print_status "info" "Run /mcp in Claude Code to complete Notion OAuth login"
}

_install_axiom() {
    # Axiom ships a hosted remote MCP server authenticated via OAuth — no API
    # key, so nothing is read from .env. Same shape as _install_linear /
    # _install_notion, but HTTP transport like _install_context7 (Axiom's docs,
    # axiom.co/docs/llms/mcp-server, give the streamable-HTTP endpoint as
    # primary and SSE at mcp.axiom.co/sse as legacy fallback). The old
    # axiomhq/mcp-server-axiom GitHub repo is deprecated — do not install it.
    if claude mcp list 2>/dev/null | grep -q '^axiom'; then
        print_status "info" "axiom MCP already registered — skipping"
        return 0
    fi

    claude mcp add --scope user \
        --transport http \
        axiom \
        "https://mcp.axiom.co/mcp"

    print_status "success" "axiom MCP registered (HTTP transport, user scope)"
    print_status "info" "Run /mcp in Claude Code to complete Axiom OAuth login"
}

_install_tavily() {
    local env_file="$1"

    local tavily_key
    tavily_key=$(grep -E '^TAVILY_API_KEY=' "$env_file" | head -1 | cut -d'=' -f2-)

    if [ -z "$tavily_key" ]; then
        print_status "warning" "TAVILY_API_KEY not found in .env — skipping tavily"
        return 0
    fi

    if claude mcp list 2>/dev/null | grep -q '^tavily'; then
        print_status "info" "tavily MCP already registered — skipping"
        return 0
    fi

    claude mcp add --scope user \
        --transport http \
        tavily \
        "https://mcp.tavily.com/mcp/?tavilyApiKey=${tavily_key}"

    print_status "success" "tavily MCP registered (HTTP transport, user scope)"
}

_install_playwright_mcp() {
    if claude mcp list 2>/dev/null | grep -q '^playwright'; then
        print_status "info" "playwright MCP already registered — skipping"
        return 0
    fi

    claude mcp add --scope user \
        playwright \
        npx @playwright/mcp@latest

    print_status "success" "playwright MCP registered (stdio transport, user scope)"
}

_install_notesnook() {
    # Notesnook is a local HTTP/SSE daemon (port 3457), not a hosted URL or an
    # npx package. We deliberately do NOT run upstream's install.sh: its final
    # step launches the server in the FOREGROUND ("first-run wizard"), which
    # never returns and would hang this orchestrator. Instead we drive the
    # non-blocking steps ourselves while still sourcing the build scripts and
    # the systemd unit template from upstream. Runtime prereq: Notesnook desktop.
    local env_file="$1"
    local repo_url="https://github.com/johnfire/openclaw-notesnook-mcp.git"
    local install_dir="$HOME/.local/share/notesnook-mcp"
    local sse_url="http://localhost:3457/sse"

    if claude mcp list 2>/dev/null | grep -q '^notesnook'; then
        print_status "info" "notesnook MCP already registered — skipping"
        return 0
    fi

    if ! command -v git &>/dev/null; then
        print_status "warning" "git not found — skipping notesnook"
        return 0
    fi

    local node_major
    node_major=$(node --version 2>/dev/null | sed 's/v//' | cut -d. -f1)
    if [ -z "$node_major" ] || [ "$node_major" -lt 22 ]; then
        print_status "warning" "Node.js >= 22 required — skipping notesnook"
        return 0
    fi

    # Resolve the sync folder: prefer .env (non-interactive), else prompt.
    local sync_root=""
    if [ -f "$env_file" ]; then
        sync_root=$(grep -E '^NOTESNOOK_SYNC_ROOT=' "$env_file" | head -1 | cut -d'=' -f2-)
    fi
    if [ -z "$sync_root" ]; then
        # Resolve the localized XDG Documents dir (e.g. Documentos on pt-BR)
        # so we don't create an English "Documents" alongside the real one.
        # Fall back to ~/Documents when xdg-user-dir is missing or unset ($HOME).
        local docs_dir=""
        if command -v xdg-user-dir &>/dev/null; then
            docs_dir=$(xdg-user-dir DOCUMENTS 2>/dev/null)
        fi
        if [ -z "$docs_dir" ] || [ "$docs_dir" = "$HOME" ]; then
            docs_dir="$HOME/Documents"
        fi
        local default_sync_root="$docs_dir/Notesnook"
        read -rp "Notesnook sync folder [$default_sync_root]: " sync_root || sync_root=""
        sync_root="${sync_root:-$default_sync_root}"
    fi
    sync_root="${sync_root/#\~/$HOME}"

    if [ ! -d "$install_dir" ]; then
        print_status "info" "Cloning notesnook MCP to $install_dir..."
        if ! git clone --depth=1 --quiet "$repo_url" "$install_dir"; then
            print_status "error" "git clone failed — skipping notesnook"
            return 1
        fi
    fi

    print_status "info" "Building notesnook MCP (npm install + build)..."
    if ! (cd "$install_dir" && npm install --no-fund --no-audit && npm run build); then
        print_status "error" "notesnook build failed — skipping notesnook"
        return 1
    fi
    if [ ! -f "$install_dir/dist/index.js" ]; then
        print_status "error" "notesnook build incomplete (no dist/index.js) — skipping"
        return 1
    fi

    mkdir -p "$sync_root/export" "$sync_root/import"

    # Install the systemd user service from upstream's unit template, then
    # enable+start it in the background (systemctl returns immediately, unlike
    # the foreground `node` invocation in upstream's wizard).
    local template="$install_dir/notesnook-mcp.service"
    if command -v systemctl &>/dev/null && [ -f "$template" ]; then
        local service_dir="$HOME/.config/systemd/user"
        mkdir -p "$service_dir"
        # Upstream's unit hardcodes /usr/bin/node, which is absent on version-
        # manager setups (asdf/nvm). Substitute the resolved node path so the
        # service can actually start under systemd's minimal environment.
        local node_bin
        node_bin=$(command -v node)
        sed \
            -e "s|/usr/bin/node|$node_bin|g" \
            -e "s|INSTALL_DIR|$install_dir|g" \
            -e "s|SYNC_ROOT_PATH|$sync_root|g" \
            "$template" > "$service_dir/notesnook-mcp.service"
        systemctl --user daemon-reload
        if systemctl --user enable --now notesnook-mcp 2>/dev/null; then
            print_status "success" "notesnook-mcp systemd user service started"
        else
            print_status "warning" "notesnook-mcp service installed but could not start"
        fi
    else
        print_status "warning" "systemctl unavailable — start the server manually"
    fi

    claude mcp add --scope user \
        --transport sse \
        notesnook \
        "$sse_url"

    print_status "success" "notesnook MCP registered (SSE transport, user scope)"
    print_status "info" "Export notes from Notesnook desktop into: $sync_root/export"
}

_install_context7() {
    local env_file="$1"

    local context7_key
    context7_key=$(grep -E '^CONTEXT7_API_KEY=' "$env_file" | head -1 | cut -d'=' -f2-)

    if [ -z "$context7_key" ]; then
        print_status "warning" "CONTEXT7_API_KEY not found in .env — skipping context7"
        return 0
    fi

    if claude mcp list 2>/dev/null | grep -q '^context7'; then
        print_status "info" "context7 MCP already registered — skipping"
        return 0
    fi

    claude mcp add --scope user \
        --transport http \
        context7 \
        https://mcp.context7.com/mcp \
        --header "CONTEXT7_API_KEY: $context7_key"

    print_status "success" "context7 MCP registered (HTTP transport, user scope)"
}
