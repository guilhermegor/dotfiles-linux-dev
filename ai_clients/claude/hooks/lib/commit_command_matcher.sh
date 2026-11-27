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
#
# Comments and open quotes (#1147). An UNQUOTED `#` at a word start is a comment to end of line, so
# an apostrophe in `# don't` no longer opens a quote that swallows the next command. A quote still
# open at end of input is a FAIL-CLOSED case: the opening quote is treated as a literal character
# and the rest is tokenized again, so every command after it stays visible to the guards (they
# over-read, never under-read). The shell itself would reject such a command anyway.
_tokenize_segment() {
    local segment="$1" split="${2:-}" char quote='' current='' started=0 i
    local qpos=0 qcur='' qn=0 prefix_words=() gt=0 prev_gt soft_keep=() sidx
    _SEGMENT_WORDS=()
    _SEGMENT_SOFT=()

    for ((i = 0; i < ${#segment}; i++)); do
        char="${segment:i:1}"
        prev_gt=$gt gt=0   # gt: this char is an unquoted, unescaped `>` (set in the last branch)
        if [[ "$quote" == A ]]; then
            # $'..': a backslash escapes the next char, only an unescaped ' closes
            if [[ "$char" == "\\" ]]; then i=$((i + 1)); current+="${segment:i:1}"
            elif [[ "$char" == "'" ]]; then quote=''
            else current+="$char"; fi
        elif [[ -n "$quote" ]]; then
            if [[ "$char" == "$quote" ]]; then quote=''
            elif [[ "$char" == "\\" && "$quote" == '"' && "${segment:i+1:1}" == [\\\"\$\`] ]]; then
                i=$((i + 1)); current+="${segment:i:1}"   # POSIX: \ " $ ` are escapable in "..."
            else current+="$char"; fi
        elif [[ "$char" == "\\" ]]; then
            started=1
            i=$((i + 1))
            [[ "${segment:i:1}" == $'\n' ]] || current+="${segment:i:1}"
        elif [[ "$char" == "'" || "$char" == '"' ]]; then
            quote="$char"
            if [[ "$char" == "'" && "$current" == *'$' ]]; then quote=A; current="${current%?}"; fi
            qpos=$i qcur="$current" qn=${#_SEGMENT_WORDS[@]}
            started=1
        elif [[ "$char" == '#' ]] && ((!started)); then
            while ((i + 1 < ${#segment})) && [[ "${segment:i+1:1}" != $'\n' ]]; do i=$((i + 1)); done
        elif [[ -n "$split" && ( "$char" == [\;\&\|] || "$char" == $'\n' ) ]]; then
            ((started)) && { _SEGMENT_WORDS+=("$current"); current=''; started=0; }
            # A `|` right after an unquoted, unescaped `>` is the clobber redirect `>|`, not a pipe
            # (#1158). It still cuts here, as it always did; where it cut is kept out of band (word
            # index of the boundary) so _for_each_command can put the command back together. The
            # flag, not the word text: a quoted `'a>'|x` is a real pipe.
            [[ "$char" == '|' ]] && ((prev_gt)) && _SEGMENT_SOFT+=("${#_SEGMENT_WORDS[@]}")
            _SEGMENT_WORDS+=("$_BOUNDARY")
        elif [[ "$char" == [[:space:]] ]]; then
            ((started)) && { _SEGMENT_WORDS+=("$current"); current=''; started=0; }
        else
            current+="$char"
            started=1
            [[ "$char" == '>' ]] && gt=1
        fi
    done

    if [[ -n "$quote" ]]; then
        prefix_words=("${_SEGMENT_WORDS[@]:0:qn}")
        for sidx in ${_SEGMENT_SOFT[@]+"${_SEGMENT_SOFT[@]}"}; do ((sidx < qn)) && soft_keep+=("$sidx"); done
        _tokenize_segment "$qcur${segment:qpos+1}" "$split"
        _SEGMENT_WORDS=("${prefix_words[@]}" "${_SEGMENT_WORDS[@]}")
        for sidx in ${_SEGMENT_SOFT[@]+"${_SEGMENT_SOFT[@]}"}; do soft_keep+=("$((sidx + qn))"); done
        _SEGMENT_SOFT=(${soft_keep[@]+"${soft_keep[@]}"})
        return 0
    fi

    ((started)) && _SEGMENT_WORDS+=("$current")
    return 0
}

# _skip_redirections
# Sets `_CCM_REDIR_NEXT` to the index in `_CMD_WORDS` of the first word that is not a leading redirection
# (#1158): `[n]>f`, `[n]>>f`, `<f`, `[n]>&m`, `&>f`, `<<tag`, `<<<word`, `<>f`, `{fd}>f`, each also in
# the separated form (`> f`). A word that is an operator alone eats the next word as its target.
# Over-reading only: a word that merely looks like a redirection is skipped. In split mode the
# tokenizer cuts `>&2` at its `&` (and `2>&1`, `&>f`), so a bare fd word (`2`, `1-`, `-`) opening a
# command is the tail of such a cut and is skipped too; the sed-split reading never cuts there,
# where the same skip is a harmless extra over-read.
_CCM_REDIR_RE='^([0-9]+|\{[A-Za-z_][A-Za-z0-9_]*\}|&)?(>>|>\||>&|>|<<<|<<-|<<|<&|<>|<)(.*)$'
_skip_redirections() {
    local i=0 w
    while w="${_CMD_WORDS[i]:-}"; [[ -n "$w" ]]; do
        if [[ "$w" =~ $_CCM_REDIR_RE ]]; then
            [[ -n "${BASH_REMATCH[3]}" ]] || i=$((i + 1))
        elif [[ ! "$w" =~ ^([0-9]+-?|-)$ ]]; then
            break
        fi
        i=$((i + 1))
    done
    _CCM_REDIR_NEXT=$i
}

# _words_invoke_commit
# Return 0 if the global `_CMD_WORDS` (ONE simple command's words) is a `git commit` invocation: an
# optional `rtk` / `rtk proxy` prefix, the git binary (bare or an absolute path), any run of global
# flags, then the literal subcommand `commit`. On a match, sets COMMIT_COMMAND_GIT_DIR and
# `_COMMIT_ARGS_FROM` (the index of the first word after `commit`).
_words_invoke_commit() {
    local -a words=("${_CMD_WORDS[@]:-}")
    local i=0 dir=''

    # Redirections may come BEFORE the command word (`>/dev/null git commit`, #1158).
    _skip_redirections
    i=$_CCM_REDIR_NEXT

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

# _join_continuations
# stdin -> stdout with each `\<NL>` line continuation removed (#1152): bash joins the lines, so
# `git \<NL> commit` is one command. Only an ODD run of backslashes before the newline continues
# the line; an even run is escaped backslashes and the newline stays a separator.
# ponytail: deliberately quote- and comment-blind. A real lexer here (tried: a comment/quote
# tracker) desynced on $'..', $(..) and multi-line quotes, each hiding a commit. The caller instead
# takes the UNION of this reading and the unjoined one, so the join can never hide what the
# unjoined text shows.
_join_continuations() {
    sed -zE ':a; s/(^|[^\\])((\\\\)*)\\\n/\1\2/; ta'
}

# command_has_git_commit COMMAND
# Return 0 if any segment of COMMAND (split on &&, ||, ; and |) is a git-commit invocation;
# return 1 otherwise. On a match, COMMIT_COMMAND_GIT_DIR holds that invocation's `-C` directory
# (empty when it has none).
# Two readings, a hit on EITHER counts: the text as written, and the text with every `\<NL>`
# joined. Over-reading is the safe direction for a guard (see _join_continuations).
command_has_git_commit() {
    local command="$1" segment reading joined
    joined="$(printf '%s' "$command" | _join_continuations)"

    # Cleared per call so a previous match's directory can never leak into a later one.
    # shellcheck disable=SC2034  # read by the hooks that source this file, invisible to shellcheck
    COMMIT_COMMAND_GIT_DIR=""
    # The last two readings turn the clobber redirect `>|` into `>` (#1158): the `|` of `>|f git
    # commit` is no pipe, but the split below cannot tell. Added to the first two, never instead.
    # readings 3 and 4 also rewrite `>|` inside quotes: fine for this yes/no answer, never reuse
    # them for message extraction.
    local -a readings=("$command" "$joined")
    if [[ "$command" == *'>|'* || "$joined" == *'>|'* ]]; then
        readings+=("${command//>|/>}" "${joined//>|/>}")
    fi
    for reading in "${readings[@]}"; do
        while IFS= read -r segment; do
            _segment_invokes_commit "$segment" && return 0
        done <<< "$(printf '%s' "$reading" | sed -E 's/(&&|\|\||;|\|)/\n/g')"
    done

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
    local w cb="$2" i soft=" "
    local -a all piece_words=() piece_len=()
    _CMD_WORDS=()
    _tokenize_segment "$1" split
    all=("${_SEGMENT_WORDS[@]:-}" "$_BOUNDARY")
    for i in ${_SEGMENT_SOFT[@]+"${_SEGMENT_SOFT[@]}"}; do soft+="$i "; done
    for i in "${!all[@]}"; do
        w="${all[i]}"
        if [[ "$w" != "$_BOUNDARY" ]]; then
            _CMD_WORDS+=("$w")
            continue
        fi
        piece_words+=(${_CMD_WORDS[@]+"${_CMD_WORDS[@]}"})
        piece_len+=("${#_CMD_WORDS[@]}")
        _CMD_WORDS=()
        # A cut at `>|` is no command boundary (#1158): keep gathering. The group fires, in source
        # order and once, at its first real boundary.
        [[ "$soft" == *" $i "* ]] && continue
        _fire_group "$cb"
        piece_words=()
        piece_len=()
    done
}

# _fire_group CALLBACK
# Fire CALLBACK for the commands held in the caller's `piece_words` / `piece_len` (the pieces one
# command was cut into at `>|`). Put back together with their `|`, they are ONE command; when that
# is a `git commit` it fires once and the pieces do not. Otherwise each piece fires as before, so
# whatever the callbacks saw before the rejoining they still see (#1158). The cut positions are
# word indexes kept out of band, so no byte of the input can collide with them.
_fire_group() {
    local cb="$1" k off=0 saved_dir="$COMMIT_COMMAND_GIT_DIR"
    local -a joined=()
    if ((${#piece_len[@]} > 1)); then
        for ((k = 0; k < ${#piece_len[@]}; k++)); do
            joined+=(${piece_words[@]+"${piece_words[@]:off:piece_len[k]}"})
            off=$((off + piece_len[k]))
            if ((k + 1 < ${#piece_len[@]} && piece_len[k] > 0)); then joined[${#joined[@]} - 1]+="|"; fi
        done
        _CMD_WORDS=(${joined[@]+"${joined[@]}"})
        if _words_invoke_commit; then
            COMMIT_COMMAND_GIT_DIR="$saved_dir"
            "$cb"
            _CMD_WORDS=()
            return 0
        fi
        COMMIT_COMMAND_GIT_DIR="$saved_dir"
    fi
    off=0
    for ((k = 0; k < ${#piece_len[@]}; k++)); do
        _CMD_WORDS=(${piece_words[@]+"${piece_words[@]:off:piece_len[k]}"})
        off=$((off + piece_len[k]))
        "$cb"
    done
    _CMD_WORDS=()
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

# commit_cd_dir COMMAND
# Sets COMMIT_CD_OK=1 and COMMIT_CD_DIR to the directory a lone `cd <absolute literal path>` moves
# into BEFORE the commit (empty when no cd precedes it). COMMIT_CD_OK=0 when the working directory
# cannot be known statically: several cds, a relative or expanded path, `cd -`, or a cd between two
# commits. A cd AFTER the last commit cannot change where it ran and is ignored; heredoc bodies are
# data and never scanned.
commit_cd_dir() {
    local saved_dir="$COMMIT_COMMAND_GIT_DIR"
    COMMIT_CD_DIR=''
    COMMIT_CD_OK=1
    _CD_SEEN_COMMIT=0
    _CD_LATE=0
    _note_cd_dir() {
        local first="${_CMD_WORDS[0]:-}" target="${_CMD_WORDS[1]:-}"
        if [[ "$first" != "cd" && "$first" != "pushd" ]]; then
            if _words_invoke_commit; then
                _CD_SEEN_COMMIT=1
                # shellcheck disable=SC2034  # read by the hooks that source this file
                ((_CD_LATE)) && COMMIT_CD_OK=0
            fi
            return 0
        fi
        if ((_CD_SEEN_COMMIT)); then _CD_LATE=1; return 0; fi
        if [[ -n "$COMMIT_CD_DIR" || "$first" == pushd || ${#_CMD_WORDS[@]} -ne 2 \
              || "$target" != /* || "$target" == *'$'* || "$target" == *'`'* ]]; then
            # shellcheck disable=SC2034  # read by the hooks that source this file
            COMMIT_CD_OK=0
        else
            COMMIT_CD_DIR="$target"
        fi
    }
    _for_each_command "$(printf '%s' "$1" | _strip_heredoc_bodies)" _note_cd_dir
    COMMIT_COMMAND_GIT_DIR="$saved_dir"
}

# _strip_heredoc_bodies [FILE]
# Print FILE (or stdin) without the lines between a `<<TAG` opener and its closing TAG (opener line
# kept). The delimiter is any run of characters git/the shell would accept, digits-only included.
_strip_heredoc_bodies() {
    # Quote-aware (#1147): a `<<` inside '..', "..", $'..', $"..", after a backslash or in a #comment
    # is not an opener. Quote state carries across lines. $'..' is its own state ("A"): there a
    # backslash escapes the next char, so `\'` does not close it. Fail closed: a quote still open at
    # end of input means the scan cannot be trusted (a desync may have invented an opener), so the
    # WHOLE input is printed unstripped and the guards read MORE text, never less. The accepted
    # cost: a legitimate heredoc body read as commands can over-block (#1158's fail-closed cases).
    # $(..) (#1148 review): inside it quoting restarts at the top level, so `"$(cat <<EOF` still
    # opens a heredoc; push/pop save the enclosing quote state and the paren depth. `$((..))` is
    # arithmetic (ar): its `<<` is a shift, never an opener. An unbalanced `$(` fails closed too.
    awk '
        function push(i) {
            depth++; sq[depth] = q; spd[depth] = pd; sar[depth] = ar
            q = ""; pd = 1; ar = (substr($0, i + 2, 1) == "(")
        }
        function pop() { q = sq[depth]; pd = spd[depth]; ar = sar[depth]; depth-- }
        # Delimiter word with bash quote removal (#1152): <<"E"OF and <<E"OF" both mean EOF. An
        # unterminated quote cannot be read confidently: dbad fails the whole input closed.
        function delim(s,   n, k, ch, t, e, m, cm, nx) {
            n = length(s); k = 1; t = ""
            while (k <= n) {
                ch = substr(s, k, 1)
                if (ch ~ /[ \t<>|&;()]/) break
                # A backslash that ends the line is a continuation: the delimiter goes on in the next
                # line (#1158), so it cannot be read from this one. Fail the whole input closed.
                if (ch == "\\" && k == n) { bad = 1; break }
                if (ch == "\\") { t = t substr(s, k + 1, 1); k += 2; continue }
                # $".." is a plain quoted word; $'..' is ANSI-C quoting (#1158). An escape in it
                # (\x41, \n, \101) is decoded by bash, and decoding is not done here: fail closed.
                if (ch == "$" && substr(s, k + 1, 1) == "\"") { k++; continue }
                if (ch == "$" && substr(s, k + 1, 1) == "\047") {
                    e = index(substr(s, k + 2), "\047")
                    if (!e || index(substr(s, k + 2, e - 1), "\\")) { bad = 1; break }
                    t = t substr(s, k + 2, e - 1); k += e + 2; continue
                }
                if (ch == "\047") {
                    e = index(substr(s, k + 1), ch)
                    if (!e) { bad = 1; break }
                    t = t substr(s, k + 1, e - 1); k += e + 1; continue
                }
                if (ch == "\"") {   # inside "..": \ before \ " $ ` drops the backslash, else literal
                    m = k + 1
                    while (m <= n && substr(s, m, 1) != "\"") {
                        cm = substr(s, m, 1); nx = substr(s, m + 1, 1)
                        if (cm == "\\" && (nx == "\\" || nx == "\"" || nx == "$" || nx == "`")) { t = t nx; m += 2 }
                        else { t = t cm; m++ }
                    }
                    if (m > n) { bad = 1; break }
                    k = m + 1; continue
                }
                t = t ch; k++
            }
            dlen = k - 1
            return t
        }
        { raw[NR] = $0 }
        pending {
            t = $0; sub(/^\t+/, "", t)
            if (t == tags[ci] && ++ci > nt) { pending = 0; nt = 0 }
            next
        }
        {
            n = length($0); i = 1
            bw = 1   # bw: the previous char was an unescaped, unquoted word boundary
            while (i <= n) {
                c = substr($0, i, 1); pb = bw; bw = 0
                if (q == "\047") { if (c == "\047") q = ""; i++; continue }
                if (q == "A") {
                    if (c == "\\") i++
                    else if (c == "\047") q = ""
                    i++; continue
                }
                if (q != "") {
                    if (c == "\\") i++
                    else if (c == q) q = ""
                    else if (c == "$" && substr($0, i + 1, 1) == "(") { push(i); i++ }
                    i++; continue
                }
                if (c == "$" && substr($0, i + 1, 1) == "(") { push(i); i += 2; continue }
                # Bare ((..)) arithmetic command (#1152): its << is a shift. Skip to the matching ))
                # on this line; none found means the shape is unreadable, so fail closed.
                # ponytail: quote-blind paren count; a subshell spelled ((cmd) | x) is skipped too
                # (over-read only, its heredoc body stays visible).
                if (c == "(" && pb && substr($0, i + 1, 1) == "(") {
                    j = i + 2; dp = 2
                    while (j <= n && dp > 0) {
                        cj = substr($0, j, 1)
                        if (cj == "(") dp++; else if (cj == ")") dp--
                        j++
                    }
                    if (dp > 0) bad = 1
                    i = j; continue
                }
                if (depth > 0 && c == "(") pd++
                if (depth > 0 && c == ")") { pd--; if (pd == 0) pop(); i++; continue }
                if (c ~ /[ \t;&|(]/) bw = 1
                if (c == "\\") { i += 2; continue }
                if (c == "\047" || c == "\"") { q = c; i++; continue }
                if (c == "$" && substr($0, i + 1, 1) ~ /[\047"]/) {
                    q = substr($0, i + 1, 1); if (q == "\047") q = "A"; i += 2; continue
                }
                if (c == "#" && pb) break
                if (c == "<" && ar) { i++; continue }
                if (c == "<" && substr($0, i, 3) == "<<<") { i += 3; continue }
                if (c == "<" && substr($0, i, 2) == "<<") {
                    rest = substr($0, i + 2); match(rest, /^-?[ \t]*/); plen = RLENGTH
                    tg = delim(substr(rest, plen + 1))
                    if (tg != "") tags[++nt] = tg
                    i += 2 + plen + dlen   # several heredocs may share one line (#1152)
                    continue
                }
                i++
            }
        }
        # An odd run of backslashes ends an opener line (#1158): bash joins the next line to it, so the
        # body does not start where this scan thinks. Cannot be read here: fail the input closed.
        { out[++m] = $0; if (nt > 0) { pending = 1; ci = 1; if ($0 ~ /(^|[^\\])(\\\\)*\\$/) bad = 1 } }
        END { if (q != "" || depth > 0 || bad || pending) for (k = 1; k <= NR; k++) print raw[k]; else for (k = 1; k <= m; k++) print out[k] }
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
    COMMIT_SOURCE_FILE=''
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
                COMMIT_SOURCE_FILE="$v"
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

_VALUE_OPTS=' --author --date -C --reuse-message -c --reedit-message -t --template --fixup --squash --cleanup --pathspec-from-file '
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
