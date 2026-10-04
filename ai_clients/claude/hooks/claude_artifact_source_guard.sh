#!/bin/bash
# PreToolUse (Write|Edit matcher) hook: block authoring a durable AI-client artifact directly into a
# live config dir (~/.claude, and the adopted clients' own live dirs), steering the edit to the
# version-controlled source under dotfiles-dev.
#
# Why this exists: these dirs are machine-local and non-symlinked — a command / skill / agent / rule /
# hook / global CLAUDE.md / shared AGENTS.md written there is lost on the next OS install and never
# reproduced by the installer. The "author in dotfiles-dev" rule is only advisory in CLAUDE.md; this
# hook makes it deterministic by refusing the Write/Edit and naming the correct source path.
#
# Hook I/O contract (same as commit_title_length_guard.sh): silent on stdout, speaks only through
# exit code + stderr — no lib/common.sh / print_status. It fails OPEN: no jq, no file_path, or a path
# that is not one of the guarded durable-artifact locations exits 0 and lets the write proceed.
#
# Deliberately NOT guarded in ~/.claude/ (meant to be written live, per the rule's exemptions):
#   * ~/.claude/projects/**  (project memory)   * ~/.claude/tasks/**  (lessons.md)
#   * ~/.claude/plans/**                          * settings*.json     * a project's own .claude/
# Only Write/Edit *tool* calls are caught; the correct deploy step (`cp` via Bash) is not, so
# "edit source, then cp into place" keeps working.
#
# Other clients (dotfiles-linux-dev#346): Qwen, Copilot and Kimi Code each get exactly one guarded file —
# the shared AGENTS.md delivered by ai_clients/lib/shared_agents_md.sh, at whatever filename that CLI
# actually reads (copilot-instructions.md for Copilot; AGENTS.md for the rest). Everything else in
# those clients' live dirs (credentials, caches, session history, IDE locks) is unversioned machine
# state on purpose and stays unguarded. Kimi Code is not installed on this machine — its dir and
# override env var are unverified against a real install (see ai_clients/kimi/main.sh).

set -u

command -v jq >/dev/null 2>&1 || exit 0

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
QWEN_DIR="$HOME/.qwen"
COPILOT_DIR="${COPILOT_HOME:-$HOME/.copilot}"
KIMI_DIR="${KIMI_CODE_HOME:-$HOME/.kimi-code}"

# Lexically normalize a path: collapse repeated separators, drop "." components, and fold ".."
# against what precedes it. No filesystem access and no symlink resolution — the hook must decide
# identically whether or not the target exists yet, which is the usual case for a Write.
# Without this the routing below reads `~/.qwen/./AGENTS.md` as rel `./AGENTS.md`, misses the
# allowlist and exits 0 — the write then lands on the real file (measured, every client branch).
normalize_path() {
	local path="$1" lead="" comp out=() parts=()
	[[ "$path" == /* ]] && lead=/
	IFS=/ read -r -a parts <<<"$path"
	for comp in "${parts[@]}"; do
		case "$comp" in
		'' | .) ;;
		..) [[ "${#out[@]}" -gt 0 ]] && unset 'out[-1]' ;;
		*) out+=("$comp") ;;
		esac
	done
	local IFS=/
	printf '%s%s' "$lead" "${out[*]}"
}

main() {
    local payload tool path

    payload="$(cat)"
    tool="$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null)"
    case "$tool" in
        Write | Edit) ;;
        *) exit 0 ;;
    esac

    path="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // empty' 2>/dev/null)"
    [[ -n "$path" ]] || exit 0
    path="$(normalize_path "$path")"

    # Only paths inside a guarded live client dir are candidates. Each branch strips its own dir's
    # prefix and maps the remaining relative path to its source, or exits 0 (fail open) if the
    # relative path is not one of that client's guarded files.
    local live_dir rel src
    case "$path" in
        "$CLAUDE_DIR"/*)
            live_dir="$CLAUDE_DIR"; rel="${path#"$CLAUDE_DIR"/}"
            # ponytail: prefix match on the durable-artifact subdirs + the global CLAUDE.md/AGENTS.md.
            # Anything else under ~/.claude/ (projects/, tasks/, plans/, settings*.json) is allowed.
            case "$rel" in
                commands/* | skills/* | agents/* | rules/* | hooks/*) src="ai_clients/claude/$rel" ;;
                CLAUDE.md) src="ai_clients/claude/config/CLAUDE.md" ;;
                AGENTS.md) src="ai_clients/shared/AGENTS.md" ;;
                *) exit 0 ;;
            esac
            ;;
        "$QWEN_DIR"/*)
            live_dir="$QWEN_DIR"; rel="${path#"$QWEN_DIR"/}"
            case "$rel" in
                AGENTS.md) src="ai_clients/shared/AGENTS.md" ;;
                *) exit 0 ;;
            esac
            ;;
        "$COPILOT_DIR"/*)
            live_dir="$COPILOT_DIR"; rel="${path#"$COPILOT_DIR"/}"
            case "$rel" in
                copilot-instructions.md) src="ai_clients/shared/AGENTS.md" ;;
                *) exit 0 ;;
            esac
            ;;
        "$KIMI_DIR"/*)
            live_dir="$KIMI_DIR"; rel="${path#"$KIMI_DIR"/}"
            case "$rel" in
                AGENTS.md) src="ai_clients/shared/AGENTS.md" ;;
                *) exit 0 ;;
            esac
            ;;
        *) exit 0 ;;
    esac

    {
        echo "BLOCKED: refusing to author a durable AI-client artifact directly in ${live_dir}/."
        echo
        echo "  Target: ${path}"
        echo
        echo "${live_dir}/ is machine-local and non-symlinked — this file is lost on the next OS"
        echo "install and never recreated by the installer. Edit the version-controlled source instead:"
        echo
        echo "  ~/github/dotfiles-dev/${src}"
        echo
        echo "then run 'make ai_clients' (or cp it into place) to deploy. See the \"Author Claude"
        echo "artifacts in dotfiles-dev\" rule in CLAUDE.md."
    } >&2
    exit 2
}

main "$@"
