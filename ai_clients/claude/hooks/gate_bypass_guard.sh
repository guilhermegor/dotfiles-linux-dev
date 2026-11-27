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
# ponytail: the shared quote-aware tokenizer of lib/commit_command_matcher.sh, not a full shell
# parse. Each simple command is judged on its own words, so a quoted message or grep pattern
# mentioning `--no-verify` is one word and never trips it, while a quoted flag is seen. A token
# built by shell expansion or a `cd` that is not one absolute literal path can still slip through.
# Upgrade to a real shell parser only if that ever produces a real miss. `git commit -n` (the
# short spelling of --no-verify) is not covered — the issue names the long flag only.

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

# _msg_has_gate_line TEXT: a `gate-change-ok:` at the start of any line of TEXT.
_msg_has_gate_line() {
    printf '%s\n' "$1" | grep -qiE '^[[:space:]]*gate-change-ok:'
}

# _file_has_gate_line FILE: FILE is a readable message file holding such a line.
_file_has_gate_line() {
    [[ -f "$1" && -r "$1" ]] && grep -qiE '^[[:space:]]*gate-change-ok:' "$1"
}

# _commit_file_path FILE: FILE as the commit would resolve it, from its own `git -C` directory
# and a preceding absolute `cd`, falling back to the payload cwd.
_commit_file_path() {
    local f="$1" d="$COMMIT_COMMAND_GIT_DIR" base="${COMMIT_CD_DIR:-$_GB_CWD}"
    [[ "$f" == /* ]] && { printf '%s' "$f"; return; }
    [[ -z "$d" ]] && d="$base"
    [[ "$d" == /* || -z "$base" ]] || d="$base/$d"
    printf '%s/%s' "$d" "$f"
}

# _scan_words: callback for _for_each_command, run on the words of ONE simple command. Words come
# from the shared tokenizer, so quotes are already removed (`"--no-verify"` is `--no-verify`) and
# a quoted commit message stays one word that can never equal a flag.
_scan_words() {
    local i w git_at=-1 sub="" skip_at=-1
    for ((i = 0; i < ${#_CMD_WORDS[@]}; i++)); do
        w="${_CMD_WORDS[i]}"
        [[ "$w" == GATE_CHANGE_OK=* ]] && block "GATE_CHANGE_OK="
        [[ "$w" == SKIP=* && $skip_at -lt 0 ]] && skip_at=$i
        if ((git_at < 0)) && [[ "$w" == git || "$w" == */git ]]; then
            git_at=$i
            ((skip_at >= 0)) && block "SKIP= before git"
        elif ((git_at >= 0)); then
            case "$w" in
                commit | push | merge) [[ -z "$sub" ]] && sub="$w" ;;
                --no-verify) [[ -n "$sub" ]] && block "--no-verify on git $sub" ;;
            esac
        fi
    done
    ((git_at >= 0)) && [[ "$sub" == commit ]] && _words_invoke_commit && _scan_commit_message
    return 0
}

# _scan_commit_message: the message of THIS commit (global _CMD_WORDS), from -m values and from a
# -F/--file file, is free of a `gate-change-ok:` line.
_scan_commit_message() {
    local i w v kind
    for ((i = _COMMIT_ARGS_FROM; i < ${#_CMD_WORDS[@]}; i++)); do
        w="${_CMD_WORDS[i]}"
        v=''
        kind=''
        case "$w" in
            -m | --message) kind=m; v="${_CMD_WORDS[i + 1]:-}" ;;
            -[a-zA-Z]*m) kind=m; v="${_CMD_WORDS[i + 1]:-}" ;;
            --message=*) kind=m; v="${w#--message=}" ;;
            -m?*) kind=m; v="${w#-m}" ;;
            -F | --file) kind=f; v="${_CMD_WORDS[i + 1]:-}" ;;
            --file=*) kind=f; v="${w#--file=}" ;;
            -F?*) kind=f; v="${w#-F}" ;;
        esac
        if [[ "$kind" == m ]] && _msg_has_gate_line "$v"; then
            block "gate-change-ok: line in a commit message"
        fi
        [[ "$kind" == f ]] || continue
        if [[ "$v" == - ]]; then
            # `-F -`: the heredoc body was stripped from the parse; scan the raw command.
            _msg_has_gate_line "$_GB_RAW" && block "gate-change-ok: line in a commit message"
        elif [[ -n "$v" && "$v" != *'$'* && "$v" != *'`'* ]]; then
            v="$(_commit_file_path "$v")"
            _file_has_gate_line "$v" && block "gate-change-ok: line in commit message file $v"
        fi
    done
    return 0
}

main() {
    local payload command

    payload="$(cat)"
    [[ "$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null)" == "Bash" ]] || exit 0
    command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)"
    [[ -n "$command" ]] || exit 0
    _GB_CWD="$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null)"
    _GB_RAW="$command"

    # A `bash|sh <file>.sh` command runs its commits out of sight: append the script's text.
    command="$(commit_expand_script "$command")"
    commit_cd_dir "$command"
    _for_each_command "$(printf '%s' "$command" | _strip_heredoc_bodies)" _scan_words
    exit 0
}

main "$@"
