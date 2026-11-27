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
# Upgrade to a real shell parser only if that ever produces a real miss. Beyond the issue's named
# tokens it also refuses `git commit -n` (the short --no-verify), an unambiguous abbreviation of
# --no-verify (git accepts them) and `-c core.hooksPath=...`, all of which skip the same hooks.

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

# _set_value_options SUBCOMMAND: the options that take their value as the NEXT word, per
# subcommand, from `git <cmd> -h`. They differ: `-o` is --only (no value) on commit but
# --push-option (a value) on push, `-s` is a strategy on merge only. Attached spellings
# (`--message=x`, `-mx`) are single words and need no entry.
_set_value_options() {
    _VO_LONG=''
    _VO_SHORT=''
    case "$1" in
        commit)
            _VO_LONG=' --message --file --reedit-message --reuse-message --fixup --squash --author --date --cleanup --trailer --template --pathspec-from-file '
            _VO_SHORT='mFcCt' ;;
        push)
            _VO_LONG=' --push-option --repo --receive-pack --exec '
            _VO_SHORT='o' ;;
        merge)
            _VO_LONG=' --message --file --strategy --strategy-option --cleanup --into-name '
            _VO_SHORT='mFsX' ;;
    esac
}

# _cluster_takes_next SUBCOMMAND WORD: WORD is a short-option cluster (`-am`, `-nm`). Walk its
# letters like git: the first value-taking letter ends the walk, and the NEXT word is its value
# only when that letter is last (`-mx` carries its own value). On commit, a cluster holding `n`
# is --no-verify and is refused.
_cluster_takes_next() {
    local sub="$1" letters="${2#-}" i ch
    for ((i = 0; i < ${#letters}; i++)); do
        ch="${letters:i:1}"
        [[ "$sub" == commit && "$ch" == n ]] && block "git commit -n (short for --no-verify)"
        if [[ "$_VO_SHORT" == *"$ch"* ]]; then
            ((i == ${#letters} - 1))
            return
        fi
    done
    return 1
}

# _scan_words: callback for _for_each_command, run on the words of ONE simple command. Words come
# from the shared tokenizer, so quotes are already removed (`"--no-verify"` is `--no-verify`) and
# a quoted commit message stays one word that can never equal a flag. The value of a value-taking
# option is skipped, and parsing stops at `--` (what follows are pathspecs).
_scan_words() {
    local i w name c git_at=-1 sub="" skip_at=-1 value_next=0 sub_at=-1 gitdir=''
    _VO_LONG=''
    _VO_SHORT=''
    for ((i = 0; i < ${#_CMD_WORDS[@]}; i++)); do
        w="${_CMD_WORDS[i]}"
        # `-c core.hooksPath=/dev/null` disables every hook without any --no-verify; it is the
        # VALUE of `-c`, so it is checked before values are skipped.
        [[ "${w,,}" == *hookspath=* ]] && block "core.hooksPath override"
        # The word after a value-taking option is its VALUE (`-m "--no-verify"` is a message).
        if ((value_next)); then value_next=0; continue; fi
        [[ "$w" == GATE_CHANGE_OK=* ]] && block "GATE_CHANGE_OK="
        if ((git_at < 0)); then
            [[ "$w" == SKIP=* && $skip_at -lt 0 ]] && skip_at=$i
            if [[ "$w" == git || "$w" == */git ]]; then
                git_at=$i
                ((skip_at >= 0)) && block "SKIP= before git"
            fi
            continue
        fi
        if [[ -z "$sub" ]]; then
            # git's own global options sit between `git` and the subcommand.
            case "$w" in
                -C)
                    # Repeated -C compose in order; an absolute one resets.
                    c="${_CMD_WORDS[i + 1]:-}"
                    if [[ "$c" == /* || -z "$gitdir" ]]; then gitdir="$c"; elif [[ -n "$c" ]]; then gitdir="$gitdir/$c"; fi
                    value_next=1 ;;
                -c | --git-dir | --work-tree | --namespace | --super-prefix | --config-env) value_next=1 ;;
                commit | push | merge) sub="$w"; sub_at=$i; _set_value_options "$w" ;;
            esac
            continue
        fi
        [[ "$w" == -- ]] && break
        if [[ "$w" == --* ]]; then
            name="${w%%=*}"
            # git accepts any unambiguous abbreviation; `--no-veri` is the shortest unique one.
            [[ "--no-verify" == "$name"* && ${#name} -ge 9 ]] && block "--no-verify on git $sub"
            [[ "$w" != *=* && "$_VO_LONG" == *" $w "* ]] && value_next=1
        elif [[ "$w" =~ ^-[a-zA-Z]+$ ]] && _cluster_takes_next "$sub" "$w"; then
            value_next=1
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

# _stdin_has_gate_line: some `-F -` commit of the command reads a gate-change-ok: line from stdin.
# FAIL CLOSED: the only accepted source is a plain `<<TAG` / `<<-TAG` heredoc on the same command
# as the flag. Anything else (here-string `<<<`, a pipeline, `< file`, process substitution, no
# identifiable source) is refused via block_stdin: a plain-text scan of a pipeline upstream cannot
# see a marker built by printf escapes, base64, sed or cat. Every `-F -` command is judged
# (each piece of the command split on && ; ||), and the bodies of ALL heredocs attached to such a
# command are scanned, so a marker in the second of two commits is not missed. Unrelated heredocs
# (attached to a command without `-F -`) are not read.
_stdin_has_gate_line() {
    local skel piece opener rest bodies
    skel="$(printf '%s' "$_GB_RAW" | _strip_heredoc_bodies)"
    bodies=0
    while IFS= read -r piece; do
        [[ -n "$piece" ]] || continue
        bodies=1
        [[ "$piece" == *'<<<'* ]] && block_stdin "here-string"
        [[ "$piece" == *'|'* ]] && block_stdin "pipeline"
        opener="$(printf '%s' "$piece" | grep -oE -- "$(printf '%b' "$_STDIN_OPENER_RE")" | head -n1)"
        [[ -n "$opener" ]] || block_stdin "no heredoc attached to this commit"
        rest="${piece//"$opener"/}"
        [[ "$rest" == *'<'* ]] && block_stdin "redirect or process substitution"
    done < <(printf '%s\n' "$skel" | sed -E 's/(&&|\|\||;)/\n/g' | grep -E -- "$_STDIN_FLAG_RE")
    ((bodies)) || block_stdin "no identifiable source"
    _msg_has_gate_line "$(_flagged_heredoc_bodies)"
}

# _flagged_heredoc_bodies: the bodies of every heredoc opened on a line that carries a `-F -` flag.
# Heredocs queue in order, so several openers on one line, or heredocs on following lines, each
# get their own body; a body belongs to the flag only if its opener line carried the flag.
_flagged_heredoc_bodies() {
    printf '%s\n' "$_GB_RAW" | awk '
        n > 0 {
            t = $0; sub(/^\t+/, "", t)
            if (t == tags[1]) { for (i = 1; i < n; i++) { tags[i] = tags[i + 1]; caps[i] = caps[i + 1] } n-- }
            else if (caps[1]) print
            next
        }
        {
            line = $0; gsub(/<<</, "   ", line)
            flag = (line ~ /(^|[ \t])(-F[ \t]*-|--file([ \t]+|=)-)([ \t]|$)/)
            while (match(line, /<<-?[ \t]*(\047[^\047]*\047|"[^"]*"|[^ \t\047"<>|&;()]+)/)) {
                tag = substr(line, RSTART, RLENGTH); sub(/^<<-?[ \t]*/, "", tag); gsub(/[\047"]/, "", tag)
                n++; tags[n] = tag; caps[n] = flag
                line = substr(line, RSTART + RLENGTH)
            }
        }'
}

# _scan_commit_message: the message of THIS commit (global _CMD_WORDS), from -m values and from a
# -F/--file file, is free of a `gate-change-ok:` line. git takes any unambiguous abbreviation of a
# long option, so `--fil` and `--mess` are read as --file and --message.
_scan_commit_message() {
    local i w v kind name
    for ((i = _COMMIT_ARGS_FROM; i < ${#_CMD_WORDS[@]}; i++)); do
        w="${_CMD_WORDS[i]}"
        [[ "$w" == -- ]] && break
        v=''
        kind=''
        if [[ "$w" == --* ]]; then
            name="${w%%=*}"
            if [[ "--message" == "$name"* && ${#name} -ge 3 ]]; then kind=m
            elif [[ "--file" == "$name"* && ${#name} -ge 5 ]]; then kind=f
            fi
            if [[ "$w" == *=* ]]; then v="${w#*=}"; else v="${_CMD_WORDS[i + 1]:-}"; fi
        else
            case "$w" in
                -m | -[a-zA-Z]*m) kind=m; v="${_CMD_WORDS[i + 1]:-}" ;;
                -F | -[a-zA-Z]*F) kind=f; v="${_CMD_WORDS[i + 1]:-}" ;;
                -m?*) kind=m; v="${w#-m}" ;;
                -F?*) kind=f; v="${w#-F}" ;;
            esac
        fi
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
