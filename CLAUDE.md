# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A Bash-based Linux dotfiles and system-setup toolkit. Everything is orchestrated through `make`. Scripts are organised by concern under `distro_config/`, `drivers/`, `storage/`, `os/`, `code_editors/`, `espanso/`, and `ai_clients/`.

## Common commands

```bash
make help                  # Show all targets
make run                   # Full first-time setup (recommended entry point)
make permissions           # chmod +x all *.sh scripts
make ai_clients            # Interactive AI clients menu (Claude Code, ...)
make install_espanso_packages  # Copy espanso/ packages to ~/.config/espanso/packages/
make editors_setup         # VS Code + AI clients
make check_status          # Show distribution info and executable scripts
make clean                 # Remove *.log, *.tmp, *~ files
make test                  # Run the bats unit test suite (tests/) — local parity with CI
```

No build step. Scripts are run directly. There is a bats unit-test suite under `tests/`
(run with `make test`, or install bats via the `install_bats` step of `make install_coding`);
CI runs the same suite plus shellcheck, actionlint, yamllint, and gitlint.

## ai_clients architecture

Two-level menu system:

```
ai_clients/main.sh              ← top-level router; auto-discovers ai_clients/*/main.sh
ai_clients/lib/utils.sh         ← shared print_status(), colour vars, LOG_FILE
ai_clients/lib/shared_agents_md.sh ← install_shared_agents_md(dest) — copies ai_clients/shared/AGENTS.md
                                      to any client's live path; every client below calls it
ai_clients/claude/main.sh       ← Claude Code orchestrator with STEPS registry (the full model)
ai_clients/claude/lib/          ← one file per step:
    prerequisites.sh            ← checks for claude CLI, jq, python3, node
    settings.sh                 ← merges settings.json into ~/.claude/settings.json
    marketplaces.sh             ← register_marketplace()
    plugins.sh                  ← promote_plugin_to_user_scope()
    slash_commands.sh           ← installs custom slash commands
    claude_md.sh                ← installs global CLAUDE.md to ~/.claude/
    rules.sh                    ← installs language rules (python.md, …)
    mcp_servers.sh              ← installs MCP servers
    integrations.sh             ← runs /terminal-setup, /install-github-app, /install-slack-app
    prune.sh                    ← removes ~/.claude artifacts absent from source (asks first)
ai_clients/codex/main.sh        ← OpenAI Codex CLI orchestrator (the small model: 2 steps)
ai_clients/qwen/main.sh         ← Qwen Code orchestrator (1 step: shared AGENTS.md → ~/.qwen/)
ai_clients/copilot/main.sh      ← GitHub Copilot CLI orchestrator (1 step: shared AGENTS.md →
                                    copilot-instructions.md — Copilot does not read AGENTS.md)
ai_clients/kimi/main.sh         ← Kimi Code CLI orchestrator (1 step; NOT installed on this
                                    machine, config path verified only against upstream docs)
```

`STEPS` array in each client's `main.sh` uses `"key|label"` pairs. `dispatch_step "$key"` routes each key to its lib function (or, for the smaller clients, directly to a shared helper). To add a new step: add an entry to `STEPS`, add a `case` branch in `dispatch_step`, and create the lib function.

`ai_clients/main.sh` discovers client subdirectories at runtime — adding a new AI client only requires creating `ai_clients/<name>/main.sh`. Only durable config is versioned per client; credentials, caches, session history, and other machine-local state living in a client's real config dir are deliberately left out (see `ai_clients/CLAUDE.md`'s "Agent-agnostic bridge" section).

## Specs (`.specs/`)

Work-in-flight feature specs and plans (what `s:brainstorming` /
`s:writing-plans` produce) live under `.specs/features/<feature-name>/`. See
`.specs/CLAUDE.md` for what belongs there, what doesn't, and the out-of-repo
rule for projects this doesn't apply to (dotfiles-linux-dev#303). The pre-existing
`docs/superpowers/{plans,specs}/` files have been migrated into
`.specs/features/<feature-name>/{plan.md,design.md}` (dotfiles-linux-dev#375,
answering #302 Q-2: everything migrates); `docs/superpowers/` no longer
exists.

## Espanso packages

Each package lives under `espanso/<name>/` and must contain `package.yml`. The optional `setup.sh` inside each package runs after the copy step in `make install_espanso_packages`. Packages are copied verbatim to `~/.config/espanso/packages/<name>/`.

## Claude Code settings

`ai_clients/claude/settings.json` is the base config merged into `~/.claude/settings.json`. Merge strategy: `current * base_settings` (base takes priority). The `statusLine` key is injected conditionally only when the claude-hud plugin cache exists.

Plugins are promoted from project scope to user scope by writing entries directly into `~/.claude/plugins/installed_plugins.json`. Plugins must already be installed inside Claude Code (`/plugin install <name>`) before `promote_plugin_to_user_scope` can find their cache.

**Installing a plugin does not activate it — you must also enable it.** Registering the marketplace + bootstrapping/promoting the install (`register_marketplace`, `bootstrap_plugin`, `promote_plugin_to_user_scope`) only populates the cache, `installed_plugins.json`, and `known_marketplaces.json`. A plugin's skills/commands/hooks/MCP server load at session start **only** when its `"<name>@<marketplace>": true` entry exists in the `enabledPlugins` map of `ai_clients/claude/settings.json`. When adding a new plugin, always add **both**: the install wiring in `main.sh` **and** the `enabledPlugins` entry in `settings.json`. Verify with `/context` (enabled plugins appear; installed-but-disabled ones do not).
