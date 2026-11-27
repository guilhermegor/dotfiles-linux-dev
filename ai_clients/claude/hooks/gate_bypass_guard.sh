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

# _has_expansion WORD: WORD carries shell expansion or a glob, so its real value is unknowable here.
_has_expansion() {
    [[ "$1" == *[\$\`~*?\[]* ]]
}

# _words_change_dir_unknowably: return 0 when the words of this simple command carry any construct
# that can change the directory other than a plain leading `cd <dir>`: a directory builtin or a
# wrapper (pushd popd builtin command eval exec env source), a shell started with -c, or subshell
# and substitution syntax. Inverted on purpose: anything not understood makes the directory
# unknown, instead of listing every spelling. On a `git commit` only the words BEFORE its
# arguments are read, so a quoted message or option value mentioning "cd" never trips it.
_words_change_dir_unknowably() {
    local n="${#_CMD_WORDS[@]}" i w
    ((_GB_SUB_AT >= 0)) && n=$_GB_SUB_AT
    for ((i = 0; i < n; i++)); do
        w="${_CMD_WORDS[i]}"
        case "$w" in
            *'('* | *')'* | *'{'* | *'}'* | *'`'*) return 0 ;;
            pushd | popd | builtin | command | eval | exec | env | source | sh | bash | zsh | dash | ksh) return 0 ;;
            cd) ((i == 0)) || return 0 ;;
        esac
    done
    return 1
}

# _note_cd: for a `cd` simple command (global _CMD_WORDS), move the tracked directory the way the
# shell will: a literal absolute path replaces it, a literal relative path is appended to it.
# `cd` with no argument, `cd -`, pushd/popd or an expanded path make it unknown until the next
# literal absolute `cd`.
_note_cd() {
    local first="${_CMD_WORDS[0]:-}" target
    if _words_change_dir_unknowably; then
        _GB_DIR_OK=0
        return 0
    fi
    [[ "$first" == cd ]] || return 0
    target="${_CMD_WORDS[1]:-}"
    [[ "$target" == -- ]] && target="${_CMD_WORDS[2]:-}"
    if [[ "$first" != cd || -z "$target" || "$target" == - ]] || _has_expansion "$target"; then
        _GB_DIR_OK=0
    elif [[ "$target" == /* ]]; then
        _GB_DIR="$target"
        _GB_DIR_OK=1
    elif ((_GB_DIR_OK)) && [[ -n "$_GB_DIR" ]]; then
        _GB_DIR="$_GB_DIR/$target"
    else
        _GB_DIR_OK=0
    fi
}

# _commit_file_path FILE: sets _GB_FILE to FILE as this commit resolves it: an absolute path as is,
# a relative one from the tracked directory plus the commit's own `git -C`. Returns 1 when that
# directory cannot be known, so the caller fails closed.
_commit_file_path() {
    local f="$1" d="$_GB_DIR" c="$COMMIT_COMMAND_GIT_DIR"
    _GB_FILE="$f"
    [[ "$f" == /* ]] && return 0
    ((_GB_DIR_OK)) && [[ -n "$d" ]] || return 1
    if [[ -n "$c" ]]; then
        _has_expansion "$c" && return 1
        if [[ "$c" == /* ]]; then d="$c"; else d="$d/$c"; fi
    fi
    _GB_FILE="$d/$f"
}

block_unresolved() {
    {
        echo "BLOCKED: cannot tell which commit message file this git commit reads: $1"
        echo
        echo "The guard must read the file to check it for a gate-change-ok: line, and the path is"
        echo "relative to a directory (cd, pushd, git -C) it cannot resolve statically. Pass an"
        echo "absolute -F path, which never depends on the directory, and re-run the SAME commit."
    } >&2
    exit 2
}

# _scan_words: callback for _for_each_command, run on the words of ONE simple command. Words come
# from the shared tokenizer, so quotes are already removed (`"--no-verify"` is `--no-verify`) and
# a quoted commit message stays one word that can never equal a flag.
_scan_words() {
    local i w git_at=-1 sub="" skip_at=-1 value_next=0 sub_at=-1 gitdir=''
    for ((i = 0; i < ${#_CMD_WORDS[@]}; i++)); do
        w="${_CMD_WORDS[i]}"
        # The word after a value-taking option is its VALUE (`-m "--no-verify"` is a message).
        if ((value_next)); then value_next=0; continue; fi
        if ((git_at >= 0)); then
            [[ "$w" == -C && -z "$sub" ]] && gitdir="${_CMD_WORDS[i + 1]:-}"
            case "$w" in
                -m | --message | -F | --file | -C | -c | --author | --date | --cleanup | --trailer \
                    | -t | --template | -o | --push-option | --repo | --receive-pack | -[a-zA-Z]*m)
                    value_next=1
                    continue
                    ;;
            esac
        fi
        [[ "$w" == GATE_CHANGE_OK=* ]] && block "GATE_CHANGE_OK="
        [[ "$w" == SKIP=* && $skip_at -lt 0 ]] && skip_at=$i
        if ((git_at < 0)) && [[ "$w" == git || "$w" == */git ]]; then
            git_at=$i
            ((skip_at >= 0)) && block "SKIP= before git"
        elif ((git_at >= 0)); then
            case "$w" in
                commit | push | merge) [[ -z "$sub" ]] && { sub="$w"; sub_at=$i; } ;;
                --no-verify) [[ -n "$sub" ]] && block "--no-verify on git $sub" ;;
            esac
        fi
    done
    _GB_SUB_AT=-1
    [[ "$sub" == commit ]] && _GB_SUB_AT=$sub_at
    _note_cd
    # Located here, not by the shared matcher, so `env X=1 git commit`, `command git commit` and
    # `sudo git commit` are scanned too.
    if [[ "$sub" == commit ]]; then
        _COMMIT_ARGS_FROM=$((sub_at + 1))
        COMMIT_COMMAND_GIT_DIR="$gitdir"
        _scan_commit_message
    fi
    return 0
}

_STDIN_FLAG_RE='(^|[[:space:]])(-F[[:space:]]*-|--file([[:space:]]+|=)-)([[:space:]]|$)'
_STDIN_OPENER_RE='<<-?[[:space:]]*[\x27"]?[^[:space:]\x27"<>|&;()]+[\x27"]?'

block_stdin() {
    {
        echo "BLOCKED: cannot read the commit message this git commit takes from stdin: $1"
        echo
        echo "The guard must read the message to check it for a gate-change-ok: line. The only stdin"
        echo "source it can read is a plain <<TAG or <<-TAG heredoc attached to this commit. A"
        echo "here-string, a pipeline, a < redirect or process substitution cannot be read, since the"
        echo "text can be transformed on the way in. Write the message to a file and pass"
        echo "-F <absolute file> instead, then re-run the SAME commit."
    } >&2
    exit 2
}

# _stdin_has_gate_line: the message a `-F -` commit reads from stdin holds a gate-change-ok: line.
# FAIL CLOSED: the only accepted source is a plain `<<TAG` / `<<-TAG` heredoc on the same command
# as the flag, whose body is parsed and scanned here. Anything else (here-string `<<<`, a pipeline,
# `< file`, process substitution, no identifiable source) is refused via block_stdin: a plain-text
# scan of a pipeline upstream cannot see a marker built by printf escapes, base64, sed or cat.
# Commands chained with && ; || and unrelated heredocs are not read.
_stdin_has_gate_line() {
    local skel piece opener tag body rest
    skel="$(printf '%s' "$_GB_RAW" | _strip_heredoc_bodies)"
    piece="$(printf '%s\n' "$skel" | sed -E 's/(&&|\|\||;)/\n/g' | grep -E -- "$_STDIN_FLAG_RE" | head -n1)"
    [[ -n "$piece" ]] || block_stdin "no identifiable source"
    [[ "$piece" == *'<<<'* ]] && block_stdin "here-string"
    [[ "$piece" == *'|'* ]] && block_stdin "pipeline"
    opener="$(printf '%s' "$piece" | grep -oE -- "$(printf '%b' "$_STDIN_OPENER_RE")" | head -n1)"
    [[ -n "$opener" ]] || block_stdin "no heredoc attached to this commit"
    rest="${piece//"$opener"/}"
    [[ "$rest" == *'<'* ]] && block_stdin "redirect or process substitution"
    tag="${opener#<<}"; tag="${tag#-}"; tag="${tag//[[:space:]\'\"]/}"
    body="$(printf '%s\n' "$_GB_RAW" | awk -v tag="$tag" \
        'go { t = $0; sub(/^\t+/, "", t); if (t == tag) exit; print } index($0, "<<") && index($0, tag) && !go { go = 1 }')"
    _msg_has_gate_line "$body"
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
            _stdin_has_gate_line && block "gate-change-ok: line in a commit message"
        elif [[ "$v" == /* ]]; then
            _file_has_gate_line "$v" && block "gate-change-ok: line in commit message file $v"
        else
            _has_expansion "$v" && block_unresolved "$v"
            _commit_file_path "$v" || block_unresolved "$v"
            [[ -f "$_GB_FILE" && -r "$_GB_FILE" ]] || block_unresolved "$v ($_GB_FILE is not a readable file)"
            _file_has_gate_line "$_GB_FILE" && block "gate-change-ok: line in commit message file $_GB_FILE"
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
    _GB_DIR="$_GB_CWD"
    _GB_DIR_OK=1
    _for_each_command "$(printf '%s' "$command" | _strip_heredoc_bodies)" _scan_words
    exit 0
}

main "$@"
