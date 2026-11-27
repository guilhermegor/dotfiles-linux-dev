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
    # Only `cd <one literal dir>` is understood: any option word (-P -L -e -@ -- -) or extra
    # argument makes the directory unknown.
    if [[ -z "$target" || ${#_CMD_WORDS[@]} -ne 2 || "$target" == -* ]] || _has_expansion "$target"; then
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

# _cluster_parse SUBCOMMAND WORD: WORD is a short-option cluster (`-am`, `-nm`, `-mx`). Walks the
# letters like git: sets _CL_LETTER to the first value-taking letter ('' when none) and
# _CL_ATTACHED to the rest of the word after it (its own value, `-mx`). On commit, a cluster
# holding `n` before that letter is --no-verify and is refused.
_cluster_parse() {
    local sub="$1" letters="${2#-}" i ch
    _CL_LETTER=''
    _CL_ATTACHED=''
    for ((i = 0; i < ${#letters}; i++)); do
        ch="${letters:i:1}"
        [[ "$sub" == commit && "$ch" == n ]] && block "git commit -n (short for --no-verify)"
        if [[ "$_VO_SHORT" == *"$ch"* ]]; then
            _CL_LETTER="$ch"
            _CL_ATTACHED="${letters:i+1}"
            return 0
        fi
    done
    return 0
}

# _bind_openers: sets _CMD_HD_FIRST/_CMD_HD_LAST to the heredocs (numbered in opener order) that
# the current simple command opens. The quote-aware scanner reports each opener's command ordinal
# (_GB_HD_ORD); this callback's own ordinal comes from the tokenizer. The tokenizer drops quotes,
# so it cannot tell `'<<FAKE'` from a real opener and is NOT used to find them. A bound command
# must hold a word containing `<<`, else the two views drifted: _GB_BIND_BAD makes main() refuse.
_bind_openers() {
    local k seq=$_GB_CMD_SEQ w has=0
    _GB_CMD_SEQ=$((seq + 1))
    _CMD_HD_FIRST=0
    _CMD_HD_LAST=-1
    for ((k = 0; k < ${#_GB_HD_ORD[@]}; k++)); do
        [[ "${_GB_HD_ORD[k]}" == "$seq" ]] || continue
        ((_CMD_HD_LAST < 0)) && _CMD_HD_FIRST=$k
        _CMD_HD_LAST=$k
        _GB_HD_BOUND=$((_GB_HD_BOUND + 1))
    done
    ((_CMD_HD_LAST >= 0)) || return 0
    for w in "${_CMD_WORDS[@]}"; do
        [[ "$w" == *'<<'* ]] && has=1
    done
    ((has)) || _GB_BIND_BAD=1
}

# _record_msg KIND VALUE: remember one message source (m = inline message, f = -F file) of the
# current commit. Filled by the ONE option parse in _scan_words, read by _scan_commit_message.
_record_msg() {
    _MA_KIND+=("$1")
    _MA_VAL+=("$2")
}

# _scan_words: callback for _for_each_command, run on the words of ONE simple command. Words come
# from the shared tokenizer, so quotes are already removed (`"--no-verify"` is `--no-verify`) and
# a quoted commit message stays one word that can never equal a flag. THE single option parse of
# the guard: it skips the values of value-taking options, stops at `--` (pathspecs follow), flags
# bypass options, and records every message source of a commit (-m/--message, -F/--file, in every
# spelling git accepts: abbreviations, clusters, attached values).
_scan_words() {
    local i w name c kind nextw git_at=-1 sub="" skip_at=-1 value_next=0 sub_at=-1 gitdir=''
    _VO_LONG=''
    _VO_SHORT=''
    _MA_KIND=()
    _MA_VAL=()
    _bind_openers
    for ((i = 0; i < ${#_CMD_WORDS[@]}; i++)); do
        w="${_CMD_WORDS[i]}"
        [[ "$w" == '|'* || ( "$w" == '<'* && "$w" != '<<'* ) ]] && _GB_TOK_REDIR=1
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
        nextw="${_CMD_WORDS[i + 1]:-}"
        kind=''
        if [[ "$w" == --* ]]; then
            name="${w%%=*}"
            # git accepts any unambiguous abbreviation; `--no-veri` is the shortest unique one.
            [[ "--no-verify" == "$name"* && ${#name} -ge 9 ]] && block "--no-verify on git $sub"
            if [[ "--message" == "$name"* && ${#name} -ge 3 ]]; then kind=m
            elif [[ "--file" == "$name"* && ${#name} -ge 5 ]]; then kind=f
            fi
            if [[ -n "$kind" ]]; then
                if [[ "$w" == *=* ]]; then _record_msg "$kind" "${w#*=}"; else _record_msg "$kind" "$nextw"; value_next=1; fi
            elif [[ "$w" != *=* && "$_VO_LONG" == *" $w "* ]]; then
                value_next=1
            fi
        elif [[ "$w" == -[a-zA-Z]* ]]; then
            _cluster_parse "$sub" "$w"
            [[ "$_CL_LETTER" == m ]] && kind=m
            [[ "$_CL_LETTER" == F ]] && kind=f
            if [[ -n "$_CL_ATTACHED" ]]; then
                [[ -n "$kind" ]] && _record_msg "$kind" "$_CL_ATTACHED"
            elif [[ -n "$_CL_LETTER" ]]; then
                [[ -n "$kind" ]] && _record_msg "$kind" "$nextw"
                value_next=1
            fi
        fi
    done
    _GB_SUB_AT=-1
    [[ "$sub" == commit ]] && _GB_SUB_AT=$sub_at
    _note_cd
    # Located here, not by the shared matcher, so `env X=1 git commit`, `command git commit` and
    # `sudo git commit` are scanned too.
    if [[ "$sub" == commit ]]; then
        COMMIT_COMMAND_GIT_DIR="$gitdir"
        _scan_commit_message
    fi
    return 0
}

block_desync() {
    {
        echo "BLOCKED: this command contains quoting the guard cannot read reliably, so it cannot"
        echo "rule out a hidden git commit with a bypass token (--no-verify, SKIP=, gate-change-ok)."
        echo
        echo "Remove the unusual quoting (a \$'...' string with an escaped quote, an apostrophe in a"
        echo "# comment, an unterminated quote) or split the command, then re-run it. Bypassing a"
        echo "gate is OWNER-ONLY: the owner runs it with the '!' prefix, which skips this hook:"
        echo
        echo "  ! <command>"
    } >&2
    exit 2
}

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

# The raw-text pass over the command: ONE quote-aware scanner, never a regex over the string.
# It tracks single quotes, double quotes (with backslash escapes), backslash escapes and `#`
# comments across lines, and only outside quotes does it see the heredoc openers (`<<TAG`,
# `<<-TAG`, `<<'TAG'`), the here-string `<<<`, `<(`, a bare `<` and a single `|`. A quoted
# `'<<FAKE'` is therefore not an opener, which the shared _strip_heredoc_bodies (a plain awk
# regex used by other guards too) gets wrong. Modes:
#   skel    the command with the heredoc BODY lines removed (openers stay), for tokenizing
#   bodies  every heredoc body in opener order, each ended by a \036 byte
#   ords    per opener, the ordinal of the simple command it belongs to, counted with the
#           tokenizer's own rule (every unquoted ; & | and newline starts a new command)
#   chunks  how many simple commands the tokenizer must find (same rule, trailing blanks ignored)
#   flags   which of pipe herestr procsub redirect occur outside quotes, plus openquote when a
#           quote is still open at end of input
# `$'...'` (ANSI-C: backslash escapes, only an unescaped ' ends it) and `$"..."` are understood.
read -r -d '' _HD_AWK <<'AWK'
BEGIN { sq = "'"; dq = "\""; q = ""; n = 0; total = 0; cmd = 0; pend = 0; endcmd = 0 }
function scan(line,    i, c, nx, j, c2, k, tag, rest, len) {
    len = length(line)
    for (i = 1; i <= len; i++) {
        c = substr(line, i, 1)
        if (q != "") {
            if (q == "A") { if (c == "\\") i++; else if (c == sq) q = "" }
            else if (c == q) q = ""
            else if (q == dq && c == "\\") i++
            continue
        }
        if (c == "$") {
            nx = substr(line, i + 1, 1)
            if (nx == sq) { q = "A"; i++; continue }
            if (nx == dq) { q = dq; i++; continue }
        }
        if (c == "\\") { i++; continue }
        if (c == sq || c == dq) { q = c; continue }
        if (c == "#" && (i == 1 || substr(line, i - 1, 1) ~ /[ \t;&|(]/)) {
            # A comment holds no openers, but the tokenizer still splits on its ; & | : keep the
            # ordinals comparable.
            for (j = i + 1; j <= len; j++) if (substr(line, j, 1) ~ /[;&|]/) cmd++
            return
        }
        if (c == ";" || c == "&") { cmd++; continue }
        if (c == "|") { if (substr(line, i + 1, 1) == "|") { i++; cmd += 2 } else { pipe = 1; cmd++ } continue }
        if (c != "<") continue
        if (substr(line, i, 3) == "<<<") { herestr = 1; i += 2; continue }
        if (substr(line, i, 2) == "<<") {
            j = i + 2
            if (substr(line, j, 1) == "-") j++
            while (substr(line, j, 1) ~ /[ \t]/) j++
            c2 = substr(line, j, 1)
            if (c2 == sq || c2 == dq) {
                k = index(substr(line, j + 1), c2); tag = substr(line, j + 1, k - 1); i = j + k
            } else {
                rest = substr(line, j); tag = ""
                if (match(rest, /^[^ \t'"<>|&;()]+/)) { tag = substr(rest, 1, RLENGTH); i = j + RLENGTH - 1 } else i = j - 1
            }
            n++; total++; tags[n] = tag
            if (mode == "ords") print cmd
            continue
        }
        if (substr(line, i + 1, 1) == "(") procsub = 1; else redirect = 1
    }
}
{
    if (n > 0) {
        t = $0; sub(/^\t+/, "", t)
        if (t == tags[1]) { if (mode == "bodies") printf "\036"; for (i = 1; i < n; i++) tags[i] = tags[i + 1]; n-- }
        else if (mode == "bodies") print
        next
    }
    if (mode == "skel") print
    if (pend) cmd++
    pend = 1
    scan($0)
    if ($0 != "") endcmd = cmd
}
END {
    if (mode == "chunks") print endcmd + 1
    if (mode == "bodies") for (; n > 0; n--) printf "\036"
    if (mode == "flags") print (pipe ? "pipe " : "") (herestr ? "herestr " : "") (procsub ? "procsub " : "") (redirect ? "redirect " : "") (q != "" ? "openquote" : "")
}
AWK

# _hd_scan MODE: run the scanner above over the raw command.
_hd_scan() {
    printf '%s\n' "$_GB_RAW" | awk -v mode="$1" "$_HD_AWK"
}

# _stdin_has_gate_line FIRST LAST: the commit being scanned reads its message from stdin
# (recognised by the one option parse, so every spelling counts), and its own heredocs are
# numbers FIRST..LAST of the command. FAIL CLOSED: the only accepted source is a plain `<<TAG` /
# `<<-TAG` heredoc opened by THAT command's words. A here-string, a pipeline, `< file`, process
# substitution anywhere in the command (judged by the quote-aware scanner, so `grep 'a|b'` does
# not count), or no heredoc of its own is refused via block_stdin: a plain-text scan of a
# pipeline upstream cannot see a marker built by printf escapes, base64, sed or cat. Heredocs of
# other commands, on the same line or not, are never read. main() cross-checks the scanner's
# opener count against the tokenizer's and refuses on a disagreement.
_stdin_has_gate_line() {
    local first="$1" last="$2" flags k
    local -a bodies
    _GB_STDIN_SEEN=1
    flags="$(_hd_scan flags)"
    [[ "$flags" == *herestr* ]] && block_stdin "here-string"
    [[ "$flags" == *pipe* ]] && block_stdin "pipeline"
    [[ "$flags" == *procsub* ]] && block_stdin "process substitution"
    [[ "$flags" == *redirect* ]] && block_stdin "redirect"
    [[ "$flags" == *openquote* ]] && block_stdin "a quote is left open at the end of the command"
    ((last >= first)) || block_stdin "no heredoc attached to this commit"
    mapfile -d $'\036' -t bodies < <(_hd_scan bodies)
    ((last < ${#bodies[@]})) || block_stdin "cannot match the heredoc to this commit"
    for ((k = first; k <= last; k++)); do
        _msg_has_gate_line "${bodies[k]}" && return 0
    done
    return 1
}

# _scan_commit_message: the message sources of THIS commit, as recorded by the single option parse
# in _scan_words (_MA_KIND/_MA_VAL), are free of a `gate-change-ok:` line.
_scan_commit_message() {
    local k kind v
    for ((k = 0; k < ${#_MA_KIND[@]}; k++)); do
        kind="${_MA_KIND[k]}"
        v="${_MA_VAL[k]}"
        if [[ "$kind" == m ]]; then
            _msg_has_gate_line "$v" && block "gate-change-ok: line in a commit message"
        elif [[ "$v" == - ]]; then
            _stdin_has_gate_line "$_CMD_HD_FIRST" "$_CMD_HD_LAST" && block "gate-change-ok: line in a commit message"
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
    _GB_CMD_SEQ=0
    _GB_HD_BOUND=0
    _GB_BIND_BAD=0
    _GB_TOK_REDIR=0
    _GB_STDIN_SEEN=0

    # A `bash|sh <file>.sh` command runs its commits out of sight: append the script's text.
    command="$(commit_expand_script "$command")"
    _GB_RAW="$command"
    _GB_DIR="$_GB_CWD"
    _GB_DIR_OK=1
    mapfile -t _GB_HD_ORD < <(_hd_scan ords)
    _for_each_command "$(_hd_scan skel)" _scan_words
    # The scanner (bash-faithful quoting) and the tokenizer (shared, no ANSI-C or comment rules)
    # split the command independently. If a commit read stdin and they disagree about where a
    # heredoc belongs, or the tokenizer saw a redirect/pipe word the scanner did not, refuse.
    if ((_GB_STDIN_SEEN)) && { ((_GB_BIND_BAD)) || ((_GB_TOK_REDIR)) || ((_GB_HD_BOUND != ${#_GB_HD_ORD[@]})); }; then
        block_stdin "the raw scan and the tokenizer disagree on where the heredocs belong"
    fi
    # Backstop for everything else: a quote the tokenizer misreads (`$'it\\'s'`, an apostrophe in a
    # comment) can hide a whole `git commit --no-verify` from it. When the two views split the
    # command into a different number of commands, or a quote is left open, and the text mentions
    # git, refuse rather than trust a scan that may have missed it.
    if [[ "$(_hd_scan chunks)" != "$_GB_CMD_SEQ" || "$(_hd_scan flags)" == *openquote* ]] \
        && printf '%s' "$_GB_RAW" | grep -qE '(^|[^[:alnum:]_])git([^[:alnum:]_]|$)'; then
        block_desync
    fi
    exit 0
}

main "$@"
