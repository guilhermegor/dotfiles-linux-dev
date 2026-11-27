#!/bin/bash
# PreToolUse (Bash matcher) hook: refuse an agent Bash command that carries a gate-bypass token
# (dotfiles-linux-dev#1143).
#
# Why this exists: a repository gate (pre-commit hooks, check_gate_integrity.py) can be weakened
# only with the OWNER's justification. Nothing but prose stopped an agent from typing that
# justification itself (`gate-change-ok:` commit line, `GATE_CHANGE_OK=`) or skipping the hooks
# (`--no-verify`, `SKIP=`) — reproduced on blueprintx main (blueprintx#1333). The owner's own
# `! <command>` prompt line does not go through PreToolUse, so this hook only binds agents.
#
# Refused tokens:
#   - `--no-verify` on `git commit` / `git push` / `git merge`
#   - `GATE_CHANGE_OK=`
#   - `SKIP=` placed before `git` (pre-commit's hook-skip variable)
#   - a `gate-change-ok:` line in a `git commit` message — inline `-m` text, a heredoc, or a
#     `-F`/`--file` file the hook can read
#
# Hook I/O contract (same as commit_title_length_guard.sh): silent on stdout, speaks only through
# exit code + stderr (2 = block). Fails OPEN when it cannot parse (no jq, unreadable -F file).
#
# ponytail: a regex scan of the raw command string, not a shell parse. Quoted runs are blanked
# before the token scan so a quoted commit message or grep pattern mentioning `--no-verify` does
# not trip it; an unbalanced quote or a token built by shell expansion can still slip through.
# Upgrade to real argv parsing only if that ever produces a real miss. `git commit -n` (the short
# spelling of --no-verify) is not covered — the issue names the long flag only.

set -u

command -v jq >/dev/null 2>&1 || exit 0

# shellcheck source=lib/commit_command_matcher.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/commit_command_matcher.sh"

block() {
    {
        echo "BLOCKED: gate-bypass token in this command: $1"
        echo
        echo "Bypassing a repository gate (--no-verify, SKIP=, GATE_CHANGE_OK=, a gate-change-ok:"
        echo "commit line) is OWNER-ONLY. An agent must not type it, even when the gate looks wrong."
        echo "Fix what the gate flagged, or ask the owner. If the owner approves, they run the"
        echo "command themselves from the prompt with the '!' prefix, which skips this hook:"
        echo
        echo "  ! <command>"
    } >&2
    exit 2
}

main() {
    local payload command cwd stripped seg file

    payload="$(cat)"
    [[ "$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null)" == "Bash" ]] || exit 0
    command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)"
    [[ -n "$command" ]] || exit 0
    cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null)"

    # Blank quoted runs (one alternation, so the leftmost opener wins) before token scanning.
    stripped="$(printf '%s' "$command" | sed -E -z "s/\"[^\"]*\"|'[^']*'//g")"

    if printf '%s' "$stripped" | grep -qE '(^|[[:space:];&|(])(export[[:space:]]+)?GATE_CHANGE_OK='; then
        block "GATE_CHANGE_OK="
    fi

    # Per simple command: SKIP=... before git, and --no-verify on commit/push/merge.
    while IFS= read -r seg; do
        if printf '%s' "$seg" | grep -qE '(^|[[:space:]])SKIP=[^[:space:]]*[[:space:]]+([^[:space:]=]+=[^[:space:]]*[[:space:]]+)*(rtk[[:space:]]+(proxy[[:space:]]+)?)?([^[:space:]]*/)?git([[:space:]]|$)'; then
            block "SKIP= before git"
        fi
        if printf '%s' "$seg" | grep -qE '(^|[[:space:]/])git[[:space:]]([^[:space:]]+[[:space:]]+)*(commit|push|merge)[[:space:]]([^[:space:]]+[[:space:]]+)*--no-verify([[:space:]=]|$)'; then
            block "--no-verify on git commit/push/merge"
        fi
    done < <(printf '%s\n' "$stripped" | sed -E 's/(&&|\|\||;|\||\n)/\n/g')

    # gate-change-ok: only matters inside a commit message.
    command_has_git_commit "$command" || exit 0
    if printf '%s' "$command" | grep -qiE "(^|[\"'[:space:]])gate-change-ok:" \
        && printf '%s\n' "$command" | grep -qiE "(^|[\"'])[[:space:]]*gate-change-ok:|^[[:space:]]*gate-change-ok:"; then
        block "gate-change-ok: line in a commit message"
    fi
    file="$(printf '%s' "$command" | grep -oE -- '(^|[[:space:]])(-F[[:space:]]*|--file[=[:space:]]+)[^[:space:]|&;]+' | head -n1 \
        | sed -E 's/^[[:space:]]*(-F[[:space:]]*|--file[=[:space:]]+)//; s/^["'"'"']//; s/["'"'"']$//')"
    if [[ -n "$file" && "$file" != - && "$file" != *'$'* && "$file" != *'`'* ]]; then
        [[ "$file" == /* || -z "$cwd" ]] || file="$cwd/$file"
        if [[ -f "$file" && -r "$file" ]] && grep -qiE '^[[:space:]]*gate-change-ok:' "$file"; then
            block "gate-change-ok: line in commit message file $file"
        fi
    fi
    exit 0
}

main "$@"
