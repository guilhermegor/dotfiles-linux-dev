#!/bin/bash
# Shared matcher: "does this Bash command invoke `git commit`?" — extracted from
# commit_title_length_guard.sh, commit_body_wrap.sh and commit_secret_guard.sh (dotfiles-linux-dev#324)
# so the three guards share ONE detection rule instead of drifting apart the way the same shape
# already has three times in this repo (#272, #293, #315).
#
# The old per-hook rule was a single anchored regex:
#
#     ^[[:space:]]*(rtk[[:space:]]+)?git[[:space:]]+commit([[:space:]]|$)
#
# It recognised exactly two shapes, and MISSED four that this repo uses every day. Each miss
# meant all three guards silently no-opped — the failure #324 was filed for:
#
#   1. `rtk proxy git commit` — the raw escape hatch documented in RTK.md ("execute raw command
#      without filtering").
#   2. A commit chained after `&&` / `;` / `|` / `||`. The `^` anchor only looked at the START of
#      the whole command string, so the everyday `git add -A && git commit ...` walked past.
#   3. An absolute path: `/usr/bin/git commit`. The global CLAUDE.md and the `dev-loop` skill both
#      mandate `/usr/bin/git` in the places where the rtk proxy must be bypassed, so this is not a
#      hypothetical spelling — it is the house style for exactly the commands most worth guarding.
#   4. Git's global flags between the binary and the subcommand: `git -C <path> commit`. Also
#      house style, since `cd <dir> &&` is discouraged (global CLAUDE.md, "Avoid `cd &&`").
#
# 3 and 4 compose into `/usr/bin/git -C "$dir" commit -F msg`, which is how commits are actually
# written here — measured on this very repo while landing #324.
#
# Parsing tokens rather than matching one regex is what makes 3 and 4 expressible at all; the
# regex would have needed a fifth and sixth alternation branch each time a new spelling appeared,
# which is the drift this file exists to stop.
#
# The per-segment anchor is preserved (dotfiles-linux-dev#324 is explicit that losing it turns the guard
# into a false-positive machine): the binary must be the FIRST token of its segment, so a mere
# *mention* of "git commit" inside another argument (e.g. --body "run git commit first") never
# matches — it never begins a segment. Token-walking also makes `git commit-graph` a clean miss,
# where the regex needed an explicit trailing-boundary group to exclude it.
#
# ponytail: the split on &&/||/;/| is a regex over the raw string, not a real shell parse — same
# class of heuristic every guard in this repo already uses (see commit_secret_guard.sh's header).
# A chain operator that happens to appear literally inside a quoted argument can still confuse it;
# upgrade to real argv/AST parsing only if that ever produces a real false positive or miss.

set -u

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    echo "commit_command_matcher.sh is meant to be sourced, not executed." >&2
    exit 1
fi

# Git global flags that take their value as a SEPARATE token, so the value must be skipped too
# before the subcommand can be read (`git -C /path commit` → skip `-C` *and* `/path`). The
# `--flag=value` spellings carry their value in one token and need no entry here.
_GIT_VALUE_FLAGS=' -C -c --git-dir --work-tree --namespace --exec-path --super-prefix '

# Set by a successful match to the directory `git -C <dir>` selected, or empty when the command
# targets the caller's own working directory. Callers that run git commands of their own MUST
# honour it, or they inspect a different repository than the one being committed to — see the
# "effective directory" note in the header.
# shellcheck disable=SC2034  # consumed by the hooks that source this file, invisible to shellcheck
COMMIT_COMMAND_GIT_DIR=""

# _tokenize_segment SEGMENT
# Split SEGMENT into the global array `_SEGMENT_WORDS`, keeping quoted runs as single tokens so
# `git -C '/tmp/repo with spaces' commit` reads as four words, not six.
#
# ⚠️ Deliberately NOT `eval`/`declare -a` on the raw string. The input is an attacker-adjacent
# command line arriving in a hook payload; evaluating it to read it would execute any `$(...)`
# it contains, in a guard whose entire job is to inspect commands before they run. Only quote
# GROUPING is interpreted here — backslashes, expansions and substitutions stay literal text,
# which is all the matcher needs to find the subcommand and the `-C` value. `read -ra` was the
# first attempt and is wrong: it splits on IFS and ignores quotes entirely.
#
# With a second argument (`split`) the tokenizer also treats an UNQUOTED `;`, `&`, `|` or newline as
# a command boundary and emits `_BOUNDARY` as its own word, so a whole multi-command string (or a
# script body) can be tokenized in one pass with quoted bodies kept intact (#961). Without it the
# behaviour is unchanged: callers pre-split on operators and those characters never reach here.
_BOUNDARY=$'\x1f'
_tokenize_segment() {
    local segment="$1" split="${2:-}" char quote='' current='' started=0 i
    _SEGMENT_WORDS=()

    for ((i = 0; i < ${#segment}; i++)); do
        char="${segment:i:1}"
        if [[ -n "$quote" ]]; then
            if [[ "$char" == "$quote" ]]; then quote=''; else current+="$char"; fi
        elif [[ "$char" == "'" || "$char" == '"' ]]; then
            quote="$char"
            started=1
        elif [[ -n "$split" && ( "$char" == [\;\&\|] || "$char" == $'\n' ) ]]; then
            ((started)) && { _SEGMENT_WORDS+=("$current"); current=''; started=0; }
            _SEGMENT_WORDS+=("$_BOUNDARY")
        elif [[ "$char" == [[:space:]] ]]; then
            ((started)) && { _SEGMENT_WORDS+=("$current"); current=''; started=0; }
        else
            current+="$char"
            started=1
        fi
    done

    ((started)) && _SEGMENT_WORDS+=("$current")
    return 0
}

# _words_invoke_commit
# Return 0 if the global `_CMD_WORDS` (ONE simple command's words) is a `git commit` invocation: an
# optional `rtk` / `rtk proxy` prefix, the git binary (bare or an absolute path), any run of global
# flags, then the literal subcommand `commit`. On a match, sets COMMIT_COMMAND_GIT_DIR and
# `_COMMIT_ARGS_FROM` (the index of the first word after `commit`).
_words_invoke_commit() {
    local -a words=("${_CMD_WORDS[@]:-}")
    local i=0 dir=''

    # `rtk` / `rtk proxy` prefix (RTK.md's proxy and its raw escape hatch).
    if [[ "${words[i]:-}" && "${words[i]##*/}" == "rtk" ]]; then
        i=$((i + 1))
        [[ "${words[i]:-}" == "proxy" ]] && i=$((i + 1))
    fi

    # The binary itself: `git` or any path ending in `/git`.
    [[ "${words[i]:-}" && "${words[i]##*/}" == "git" ]] || return 1
    i=$((i + 1))

    # Global flags sit between the binary and the subcommand. `-C` is captured rather than merely
    # skipped, because it changes WHICH repository the commit lands in.
    while [[ "${words[i]:-}" == -* ]]; do
        [[ "${words[i]}" == "-C" ]] && dir="${words[i + 1]:-}"
        [[ "$_GIT_VALUE_FLAGS" == *" ${words[i]} "* ]] && i=$((i + 1))
        i=$((i + 1))
    done

    [[ "${words[i]:-}" == "commit" ]] || return 1

    COMMIT_COMMAND_GIT_DIR="$dir"
    _COMMIT_ARGS_FROM=$((i + 1))
    return 0
}

# _segment_invokes_commit SEGMENT
# Return 0 if SEGMENT is a `git commit` invocation anchored at its own start (see
# _words_invoke_commit). On a match, sets COMMIT_COMMAND_GIT_DIR.
_segment_invokes_commit() {
    _tokenize_segment "$1"
    _CMD_WORDS=("${_SEGMENT_WORDS[@]:-}")
    _words_invoke_commit
}

# command_has_git_commit COMMAND
# Return 0 if any segment of COMMAND (split on &&, ||, ; and |) is a git-commit invocation;
# return 1 otherwise. On a match, COMMIT_COMMAND_GIT_DIR holds that invocation's `-C` directory
# (empty when it has none).
command_has_git_commit() {
    local command="$1" segment

    # Cleared per call so a previous match's directory can never leak into a later one.
    # shellcheck disable=SC2034  # read by the hooks that source this file, invisible to shellcheck
    COMMIT_COMMAND_GIT_DIR=""
    while IFS= read -r segment; do
        _segment_invokes_commit "$segment" && return 0
    done <<< "$(printf '%s' "$command" | sed -E 's/(&&|\|\||;|\|)/\n/g')"

    return 1
}

# --- inline `-m` messages and script bodies (dotfiles-linux-dev#961) -----------------------------
#
# commit_body_wrap.sh and commit_title_length_guard.sh were blind to two shapes that still reach
# gitlint's B1/T1 after the whole pre-commit gate: a `git commit -m <title> -m <long body>` (more
# than one -m) and a commit run inside `bash <file>.sh`, where the PreToolUse payload is just
# `bash <file>` and never matches the segment anchor above.

_MSG_SEP=$'\x1f'

# _for_each_command COMMAND CALLBACK
# Tokenize COMMAND once with the quote-aware split mode and call CALLBACK with `_CMD_WORDS` set to
# each simple command in turn. Quoted `;`/`&`/`|` never split, and nothing is evaluated.
_for_each_command() {
    local w cb="$2"
    local -a all
    _CMD_WORDS=()
    _tokenize_segment "$1" split
    all=("${_SEGMENT_WORDS[@]:-}")
    for w in "${all[@]}" "$_BOUNDARY"; do
        if [[ "$w" == "$_BOUNDARY" ]]; then
            "$cb"
            _CMD_WORDS=()
        else
            _CMD_WORDS+=("$w")
        fi
    done
}

# command_has_cd COMMAND
# Return 0 if any simple command of COMMAND is `cd` or `pushd`: a relative path in it can no longer
# be trusted to resolve against the hook's own working directory, so callers fail open.
command_has_cd() {
    _HAS_CD=0
    _note_cd() { [[ "${_CMD_WORDS[0]:-}" == "cd" || "${_CMD_WORDS[0]:-}" == "pushd" ]] && _HAS_CD=1; return 0; }
    _for_each_command "$1" _note_cd
    ((_HAS_CD))
}

# _strip_heredoc_bodies [FILE]
# Print FILE (or stdin) without the lines between a `<<TAG` opener and its closing TAG (opener line
# kept). The delimiter is any run of characters git/the shell would accept, digits-only included.
_strip_heredoc_bodies() {
    awk '
        tag != "" { t = $0; sub(/^\t+/, "", t); if (t == tag) tag = ""; next }
        match($0, /<<-?[ \t]*(\047[^\047]*\047|"[^"]*")/) {
            tag = substr($0, RSTART, RLENGTH); sub(/^<<-?[ \t]*./, "", tag); sub(/.$/, "", tag)
        }
        tag == "" && match($0, /<<-?[ \t]*[^ \t\047"<>|&;()]+/) {
            tag = substr($0, RSTART, RLENGTH); sub(/^<<-?[ \t]*/, "", tag)
        }
        { print }
    ' "${1:--}"
}

# commit_expand_script COMMAND
# Echo COMMAND; when a simple command of it runs `bash|sh [flags] <file>.sh` and that file is a
# readable regular file of at most 256 KiB, append the file's text so the caller can scan the
# commits inside. One level only, no recursion. Skipped (fail open, the caller sees the original
# command): syntax-only runs (`-n`), a relative path after a preceding `cd`, a path built from
# expansion, and an unreadable or oversized file. Heredoc bodies are KEPT here (the title guard reads
# a `-F-` heredoc title from them); commit_inline_messages() drops them before parsing commands.
commit_expand_script() {
    _EXPANDED="$1"
    _seen_cd=0
    _expand_one() {
        local file='' w syntax_only=0 first="${_CMD_WORDS[0]:-}"
        if [[ "$first" == "cd" || "$first" == "pushd" ]]; then _seen_cd=1; return 0; fi
        [[ "${first##*/}" == "bash" || "${first##*/}" == "sh" ]] || return 0
        for w in "${_CMD_WORDS[@]:1}"; do
            if [[ "$w" == -* ]]; then
                [[ "$w" != --* && "$w" == *n* ]] && syntax_only=1
                continue
            fi
            file="$w"
            break
        done
        ((syntax_only)) && return 0
        [[ "$file" == *.sh && "$file" != *'$'* && "$file" != *'`'* ]] || return 0
        ((_seen_cd)) && [[ "$file" != /* ]] && return 0
        [[ -f "$file" && -r "$file" ]] || return 0
        (($(wc -c < "$file") <= 262144)) || return 0
        _EXPANDED+=$'\n'"$(cat "$file")"
    }
    _for_each_command "$1" _expand_one
    printf '%s' "$_EXPANDED"
}

# commit_source_dir COMMAND MODE
# MODE is `file` (a `-F <path>` commit) or `stdin` (a `-F -` commit). Sets COMMIT_SOURCE_DIR to the
# `git -C` directory of the commit that carries that flag, and COMMIT_SOURCE_FOUND=1; when no
# commit carries it (or the flag is spelled in a form this does not read) COMMIT_SOURCE_FOUND=0 and
# the caller must fail open: the link between the message source and its commit is uncertain.
commit_source_dir() {
    COMMIT_SOURCE_DIR=''
    COMMIT_SOURCE_FOUND=0
    _SRC_MODE="$2"
    _SRC_SEEN=0
    _SRC_AMBIGUOUS=0
    _find_source() {
        local i w v
        ((_SRC_AMBIGUOUS)) && return 0
        _words_invoke_commit || return 0
        for ((i = _COMMIT_ARGS_FROM; i < ${#_CMD_WORDS[@]}; i++)); do
            w="${_CMD_WORDS[i]}"
            case "$w" in
                -F | --file) v="${_CMD_WORDS[i + 1]:-}" ;;
                --file=*) v="${w#--file=}" ;;
                -F?*) v="${w#-F}" ;;
                *) continue ;;
            esac
            if [[ ( "$_SRC_MODE" == stdin && "$v" == "-" ) || ( "$_SRC_MODE" == file && "$v" != "-" ) ]]; then
                # A second matching commit makes the association with the heredoc ambiguous: fail open.
                if ((_SRC_SEEN)); then COMMIT_SOURCE_FOUND=0; _SRC_AMBIGUOUS=1; return 0; fi
                _SRC_SEEN=1
                # shellcheck disable=SC2034  # read by the hooks that source this file
                COMMIT_SOURCE_DIR="$COMMIT_COMMAND_GIT_DIR"
                # shellcheck disable=SC2034  # read by the hooks that source this file
                COMMIT_SOURCE_FOUND=1
                # shellcheck disable=SC2034  # read by the hooks that source this file
                COMMIT_SOURCE_HAS_M=0
                for v in "${_CMD_WORDS[@]:_COMMIT_ARGS_FROM}"; do
                    # shellcheck disable=SC2034  # read by the title guard
                    [[ "$v" == -m || "$v" == --message || "$v" == --message=* || "$v" == -m?* ]] && COMMIT_SOURCE_HAS_M=1
                done
                return 0
            fi
        done
    }
    _for_each_command "$(printf '%s' "$1" | _strip_heredoc_bodies)" _find_source
}

# _collect_commit_messages
# For the global `_CMD_WORDS`: when it is a `git commit` with inline messages, append one element to
# COMMIT_MESSAGE_SETS holding its -m / --message values joined by `_MSG_SEP`, and that commit's
# `git -C` directory to COMMIT_MESSAGE_DIRS. A commit that also reads a message from a file
# (-F/--file) is skipped: its source is ambiguous. Option parsing stops at `--`, and the value of a
# non-message option that takes one (`--author -mx`) is consumed, not read as a message. A literal
# empty message is dropped (git ignores it when choosing the subject); one built from shell
# expansion cannot be measured statically, so it is recorded as empty (fail open for that
# paragraph only, never counting the literal `$(...)` text).
# _short_cluster_message WORD NEXT
# Read a short-option cluster such as -am, -amTEXT or -sm. Walks the letters like git's parser:
# boolean flags are skipped, `m` takes the rest of the word as its value (`-am'long title'` reaches
# here as `-amlong title`) or, when nothing follows it, the NEXT word. Sets _CLUSTER_VAL and
# _CLUSTER_EATS (1 when NEXT was consumed). Returns 1 when the cluster carries no message, or when
# a value-taking letter other than `m` comes first (its value hides everything after it).
_short_cluster_message() {
    local rest="${1#-}" ch
    _CLUSTER_VAL=''
    _CLUSTER_EATS=0
    while [[ -n "$rest" ]]; do
        ch="${rest:0:1}"
        rest="${rest:1}"
        case "$ch" in
            m)
                if [[ -n "$rest" ]]; then _CLUSTER_VAL="$rest"; else _CLUSTER_VAL="$2"; _CLUSTER_EATS=1; fi
                return 0 ;;
            C | c | t | S) return 1 ;;
        esac
    done
    return 1
}

_VALUE_OPTS=' --author --date -C --reuse-message -c --reedit-message -t --template --fixup --squash --cleanup --pathspec-from-file -S '
_collect_commit_messages() {
    local i w val skip=0
    local -a msgs=()

    _words_invoke_commit || return 0
    for ((i = _COMMIT_ARGS_FROM; i < ${#_CMD_WORDS[@]}; i++)); do
        w="${_CMD_WORDS[i]}"
        val=''
        [[ "$w" == "--" ]] && break
        if [[ "$_VALUE_OPTS" == *" $w "* ]]; then i=$((i + 1)); continue; fi
        case "$w" in
            -F | --file | --file=* | -F?*) skip=1; continue ;;
            -m | --message) val="${_CMD_WORDS[i + 1]:-}"; i=$((i + 1)) ;;
            --message=*) val="${w#--message=}" ;;
            --*) continue ;;
            -?*) _short_cluster_message "$w" "${_CMD_WORDS[i + 1]:-}" || continue
                 val="$_CLUSTER_VAL"; i=$((i + _CLUSTER_EATS)) ;;
            *) continue ;;
        esac
        [[ -n "$val" ]] || continue
        [[ "$val" == *'$'* || "$val" == *'`'* ]] && val=''
        msgs+=("$val")
    done

    ((skip)) && return 0
    ((${#msgs[@]})) || return 0
    COMMIT_MESSAGE_SETS+=("$(IFS="$_MSG_SEP"; printf '%s' "${msgs[*]}")")
    COMMIT_MESSAGE_DIRS+=("$COMMIT_COMMAND_GIT_DIR")
}

# commit_inline_messages COMMAND
# Heredoc bodies are data, never commands, so they are dropped before parsing.
# Fill the global array COMMIT_MESSAGE_SETS with one element per `git commit` in COMMAND (a script
# body included) that carries inline -m messages: the messages joined by `_MSG_SEP` (\x1f). The
# first message is the title, the rest are body paragraphs. COMMIT_MESSAGE_DIRS holds each commit's
# `git -C` directory in the same order; COMMIT_COMMAND_GIT_DIR is preserved.
commit_inline_messages() {
    local saved_dir="$COMMIT_COMMAND_GIT_DIR"
    COMMIT_MESSAGE_SETS=()
    COMMIT_MESSAGE_DIRS=()
    _for_each_command "$(printf '%s' "$1" | _strip_heredoc_bodies)" _collect_commit_messages
    COMMIT_COMMAND_GIT_DIR="$saved_dir"
    return 0
}
