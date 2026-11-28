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
    local segment="$1" split="${2:-}" nosub="${3:-}" char quote='' current='' started=0 i
    local qpos=0 qcur='' qn=0 prefix_words=() gt=0 prev_gt lt=0 prev_lt soft_keep=() sidx
    local qlead=0 prefix_ql=() curq=0 sd=0 sbt=0 spos=0 scur="" sn=0 rtext rn amp amq=0 prev_amq
    _SEGMENT_WORDS=()
    _SEGMENT_SOFT=()
    _SEGMENT_QLEAD=()

    for ((i = 0; i < ${#segment}; i++)); do
        char="${segment:i:1}"
        prev_amq=$amq amq=0 prev_gt=$gt gt=0 prev_lt=$lt lt=0  # gt: this char is an unquoted, unescaped `>` (set in the last branch)
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
            ((started)) || qlead=1
            started=1 curq=1
            i=$((i + 1))
            [[ "${segment:i:1}" == $'\n' ]] || current+="${segment:i:1}"
        elif [[ "$char" == "'" || "$char" == '"' ]]; then
            quote="$char"
            if [[ "$char" == "'" && "$current" == *'$' ]]; then quote=A; current="${current%?}"; fi
            [[ -z "$current" ]] && qlead=1
            qpos=$i qcur="$current" qn=${#_SEGMENT_WORDS[@]}
            started=1 curq=1
        elif [[ "$char" == '#' ]] && ((!started)); then
            while ((i + 1 < ${#segment})) && [[ "${segment:i+1:1}" != $'\n' ]]; do i=$((i + 1)); done
        elif [[ -n "$split" && "$char" == '&' ]] \
             && { ((prev_gt || prev_lt)) || [[ "${segment:i+1:1}" == '>' ]]; }; then
            # `>&2`, `<&3` and `&>f` are redirections, not a background `&` (#1166): keep the word whole
            current+="$char"
            started=1 amq=1
        elif [[ -n "$split" && ( "$char" == [\;\&\|] || "$char" == $'\n' ) ]]; then
            ((started)) && { _SEGMENT_WORDS+=("$current"); _SEGMENT_QLEAD+=("$qlead"); current=''; started=0; qlead=0; curq=0; }
            sd=0 sbt=0   # a boundary ends any `$(` tracking: what follows is a command again
            # A `|` right after an unquoted, unescaped `>` is the clobber redirect `>|`, not a pipe
            # (#1158). It still cuts here, as it always did; where it cut is kept out of band (word
            # index of the boundary) so _for_each_command can put the command back together. The
            # flag, not the word text: a quoted `'a>'|x` is a real pipe.
            [[ "$char" == '|' ]] && ((prev_gt)) && _SEGMENT_SOFT+=("${#_SEGMENT_WORDS[@]}")
            _SEGMENT_WORDS+=("$_BOUNDARY")
            _SEGMENT_QLEAD+=(0)
        elif [[ "$char" == [\<\>] ]] && ((started && !prev_gt && !prev_lt)) \
             && { ((curq)) || [[ ! "$current" =~ ^([0-9]+|\{[A-Za-z_][A-Za-z0-9_]*\})$ ]]; }; then
            # A redirect glued to the word before it (`git>f commit`, #1173): that word ends here, unless
            # it is an unquoted fd prefix (`2>f`, `{fd}>f`). A quoted empty word (`-C ''>f`) is a word of
            # its own, hence `started`, not a non-empty `current`. A trailing `&` belongs to `&>f`.
            amp=''
            if [[ "$char" == '>' ]] && ((prev_amq)); then current="${current%&}"; amp='&'; fi
            if [[ -n "$current" ]] || ((curq)) || [[ -z "$amp" ]]; then
                _SEGMENT_WORDS+=("$current"); _SEGMENT_QLEAD+=("$qlead")
            fi
            current="$amp$char"; qlead=0; curq=0
            [[ "$char" == '>' ]] && gt=1
            [[ "$char" == '<' ]] && lt=1
        elif [[ "$char" == [[:space:]] ]] && ((!sd && !sbt)); then
            ((started)) && { _SEGMENT_WORDS+=("$current"); _SEGMENT_QLEAD+=("$qlead"); current=''; started=0; qlead=0; curq=0; }
        else
            current+="$char"
            started=1
            [[ "$char" == '>' ]] && gt=1
            [[ "$char" == '<' ]] && lt=1
            [[ "$char" == '&' ]] && amq=1
            # `$(..)` / backticks in an assignment value (`FOO=$(a b) git commit`, #1173): their blanks
            # do not split the word. Only boundaries still cut inside, so a `;` in there stays a
            # command boundary exactly as before. Unbalanced at the end: fail closed, see below.
            if [[ -z "$nosub" ]]; then
                if ((sd > 0)); then
                    [[ "$char" == '(' ]] && sd=$((sd + 1))
                    [[ "$char" == ')' ]] && sd=$((sd - 1))
                elif ((sbt)); then
                    [[ "$char" == '`' ]] && sbt=0
                elif [[ "$char" == '(' && "$current" == *'$(' && "$current" =~ $_CCM_OPEN_ASSIGN_RE ]]; then
                    sd=1 spos=$((i - 1)) scur="${current%??}" sn=${#_SEGMENT_WORDS[@]}
                elif [[ "$char" == '`' && "$current" =~ $_CCM_OPEN_ASSIGN_RE ]]; then
                    sbt=1 spos=$i scur="${current%?}" sn=${#_SEGMENT_WORDS[@]}
                fi
            fi
        fi
    done

    if [[ -n "$quote" ]] || ((sd > 0 || sbt)); then
        # An open quote, or an unclosed `$(` / backtick (#1173): read the rest again with the opener
        # as plain text, so every command after it stays visible.
        if [[ -n "$quote" ]]; then rtext="$qcur${segment:qpos+1}" rn=$qn
        else rtext="$scur${segment:spos}" rn=$sn nosub=1; fi
        prefix_words=("${_SEGMENT_WORDS[@]:0:rn}")
        prefix_ql=("${_SEGMENT_QLEAD[@]:0:rn}")
        for sidx in ${_SEGMENT_SOFT[@]+"${_SEGMENT_SOFT[@]}"}; do ((sidx < rn)) && soft_keep+=("$sidx"); done
        _tokenize_segment "$rtext" "$split" "$nosub"
        _SEGMENT_WORDS=("${prefix_words[@]}" "${_SEGMENT_WORDS[@]}")
        _SEGMENT_QLEAD=("${prefix_ql[@]}" "${_SEGMENT_QLEAD[@]}")
        for sidx in ${_SEGMENT_SOFT[@]+"${_SEGMENT_SOFT[@]}"}; do soft_keep+=("$((sidx + rn))"); done
        _SEGMENT_SOFT=(${soft_keep[@]+"${soft_keep[@]}"})
        return 0
    fi

    ((started)) && { _SEGMENT_WORDS+=("$current"); _SEGMENT_QLEAD+=("$qlead"); }
    return 0
}

# _redir_len I
# Sets `_CCM_RLEN` to how many words the redirection at `_CMD_WORDS[I]` takes: 1 for `>f` / `2>&1`,
# 2 for a bare operator that eats the next word as its target (`> f`); returns 1 (RLEN 0) when the
# word is no redirection. Over-reading only: a word that merely looks like one counts.
_CCM_REDIR_RE='^([0-9]+|\{[A-Za-z_][A-Za-z0-9_]*\}|&)?(>>|>\||>&|>|<<<|<<-|<<|<&|<>|<)(.*)$'
_CCM_LAZY=0
_CCM_OPEN_ASSIGN_RE='^\(*[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?\+?='   # an assignment, maybe after a subshell `(`
_CCM_ASSIGN_RE='^[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?\+?='
_redir_len() {
    local w="${_CMD_WORDS[$1]:-}"
    _CCM_RLEN=0
    # a word whose first character was quoted or escaped (`-C '>d'`) is a value (#1172)
    [[ "${_CMD_QLEAD[$1]:-0}" == 1 ]] && return 1
    [[ -n "$w" && "$w" =~ $_CCM_REDIR_RE ]] || return 1
    if [[ -n "${BASH_REMATCH[3]}" ]]; then _CCM_RLEN=1; else _CCM_RLEN=2; fi
}

# Reserved words (and the `(` / `{` / `!` openers) that may stand in front of a command (#1173).
_CCM_RESERVED=' ! if then do else elif while until { ( '

# _note_wrapper_value WRAPPER OPTION VALUE INDEX OPTION_INDEX
# What a wrapper option's value means for the commit that follows: a directory it moves into
# (`env -C`, `sudo -D` / `-R`) or a command line it re-splits (`env -S`).
# A relative directory resolves against the one an earlier wrapper set; an absolute one replaces it.
# `-S` also records the index of its option word, so the re-split can replace both option and value.
_note_wrapper_value() {
    case "$1:$2" in
        env:-C | env:--chdir | sudo:-D | sudo:--chdir | sudo:-R | sudo:--chroot)
            if [[ "$3" != /* && -n "$_CCM_WDIR" ]]; then _CCM_WDIR="${_CCM_WDIR%/}/$3"; else _CCM_WDIR="$3"; fi ;;
        env:-S | env:--split-string) _CCM_SPLIT_IDX=$4 _CCM_SPLIT_VAL="$3" _CCM_SPLIT_OPT=$5 ;;
    esac
}

# _scan_wrapper_option WRAPPER VALS WORD INDEX
# Read one option word of a wrapper. Sets `_CCM_PENDING` / `_CCM_POPT` when its value is the NEXT word.
# A short bundle is scanned left to right (`sudo -Eu root`): the first value-taking letter ends it, and
# takes the rest of the word as its value, or the next word when nothing follows.
_scan_wrapper_option() {
    local wrap=$1 vals=$2 w=$3 idx=$4 rest ch name
    _CCM_PENDING=0
    if [[ "$w" == --* ]]; then
        name="${w%%=*}"
        if [[ "$w" == *=* ]]; then _note_wrapper_value "$wrap" "$name" "${w#*=}" "$idx" "$idx"
        elif [[ "$vals" == *" $name "* ]]; then _CCM_PENDING=1 _CCM_POPT="$name"; fi
        return 0
    fi
    rest="${w#-}"
    while [[ -n "$rest" ]]; do
        ch="${rest:0:1}"
        rest="${rest:1}"
        [[ "$vals" == *" -$ch "* ]] || continue
        if [[ -n "$rest" ]]; then _note_wrapper_value "$wrap" "-$ch" "$rest" "$idx" "$idx"
        else _CCM_PENDING=1 _CCM_POPT="-$ch"; fi
        return 0
    done
}

# _skip_prefix I
# Sets `_CCM_NEXT` to the index in `_CMD_WORDS`, from I on, of the command word that follows every
# leading redirection (#1158), `NAME=value` assignment, reserved word (`!`, `if`, `{`, #1173) and
# wrapper word with its own options (`env -u X`, `command`, `builtin`, `exec`, `time -p`, `nohup`,
# `sudo -u x`, `nice -n N`, `ionice -c N`, `timeout 10`, `xargs -n 1`, `flock FILE`, ...), in any order
# (#1166). `git` and `rtk` are never skipped, so this only adds hits. A bare fd word (`2`, `1-`, `-`) is
# skipped too, the tail of a `2>&1` that was cut at its `&`. Over-reading only.
# With `_CCM_LAZY=1` a wrapper's option never takes the next word as its value: `sudo -h git commit`
# (`-h` is also "help") reads both ways, see _words_invoke_commit.
# Also sets `_CCM_WDIR` (the directory `env -C` / `sudo -D` moves into), `_CCM_GIT_ENV_DIR` (from
# `GIT_DIR=`) and `_CCM_SPLIT_IDX` / `_CCM_SPLIT_VAL` (an `env -S` value, else -1).
_skip_prefix() {
    local i=$1 w vals wrap='' pending=0 popt='' npos=0 rest git_dir=''
    _CCM_QUERY=0 _CCM_WDIR='' _CCM_GIT_ENV_DIR='' _CCM_SPLIT_IDX=-1 _CCM_SPLIT_VAL='' _CCM_SPLIT_OPT=-1
    while w="${_CMD_WORDS[i]:-}"; [[ -n "$w" ]]; do
        # A redirection never ends a wrapper's option list: `env > f -u X git commit` (#1172)
        if _redir_len "$i"; then i=$((i + _CCM_RLEN)); continue; fi
        if ((pending)); then
            pending=0
            _note_wrapper_value "$wrap" "$popt" "$w" "$i" "$((i - 1))"
            i=$((i + 1))
            continue
        fi
        if [[ -n "$wrap" && "$w" == -* ]]; then
            # `command -v` / `-V` only looks the name up, wherever it sits in the option list
            [[ "$wrap" == command && "$w" != -- && "$w" == *[vV]* ]] && _CCM_QUERY=1
            _scan_wrapper_option "$wrap" "$vals" "$w" "$i"
            if ((_CCM_PENDING && !_CCM_LAZY)); then pending=1 popt="$_CCM_POPT"; fi
            i=$((i + 1))
            continue
        fi
        if ((npos > 0)); then npos=$((npos - 1)); i=$((i + 1)); continue; fi   # timeout's duration
        wrap=''
        if [[ "$w" =~ $_CCM_ASSIGN_RE || "$w" =~ ^([0-9]+-?|-)$ ]]; then
            [[ "$w" == GIT_DIR=* ]] && git_dir="${w#*=}"
            i=$((i + 1))
            continue
        fi
        if [[ "$_CCM_RESERVED" == *" $w "* ]]; then i=$((i + 1)); continue; fi
        if [[ "$w" == '('* ]]; then   # `(git commit)`: the subshell opener glued to the command
            rest="${w#"${w%%[!(]*}"}"
            if [[ -z "$rest" ]]; then i=$((i + 1)); else _CMD_WORDS[i]="$rest"; fi
            continue
        fi
        case "${w##*/}" in
            env) vals=' -u -C -S -a --unset --chdir --split-string --argv0 ' ;;
            sudo) vals=' -u -g -h -p -C -D -R -r -T -t -U --user --group --host --prompt --chdir --chroot --role --type --other-user --close-from --command-timeout --login-class ' ;;
            doas) vals=' -u -C ' ;;
            nice) vals=' -n --adjustment ' ;;
            ionice) vals=' -c -n -p -P -u --class --classdata --pid --pgid --uid ' ;;
            time) vals=' -f -o --format --output ' ;;
            exec) vals=' -a ' ;;
            timeout) vals=' -s -k --signal --kill-after ' npos=1 ;;
            xargs) vals=' -a -d -E -I -L -n -P -s --arg-file --delimiter --max-args --max-procs --max-chars --process-slot-var ' ;;
            stdbuf) vals=' -i -o -e --input --output --error ' ;;
            taskset | chrt) vals='' npos=1 ;;   # the CPU mask / the priority
            flock) vals=' -w -E --timeout --conflict-exit-code ' npos=1 ;;   # the lock file
            strace) vals=' -o -e -p -P -s -u -E -a -b -S -X -O -I --output --trace --attach --string-limit --user --env --signal --abbrev --status --inject --fault ' ;;
            setsid | command | builtin | nohup) vals='' ;;
            *) break ;;
        esac
        wrap="${w##*/}"
        i=$((i + 1))
    done
    _CCM_NEXT=$i
    _CCM_GIT_ENV_DIR="$git_dir"
}

# _words_invoke_commit
# Return 0 if the global `_CMD_WORDS` (ONE simple command's words) is a `git commit` invocation: any
# leading redirections, assignments and wrapper words (_skip_prefix), an optional `rtk` / `rtk
# proxy` prefix, the git binary (bare or an absolute path), any run of global flags, then the
# literal subcommand `commit`, with redirections allowed between all of these (#1166). On a match,
# sets COMMIT_COMMAND_GIT_DIR and `_COMMIT_ARGS_FROM` (the index of the first word after `commit`).
# Read up to three ways, a hit on any one counts (#1173): as written, with no wrapper option taking a
# value (`sudo -h git commit`: `-h` may be "help"), and with an `env -S` value re-split into words.
_words_invoke_commit() {
    local lazy split_idx=-1 split_val='' split_opt=-1 k
    local -a saved_w saved_q head_w head_q tail_w tail_q new_w new_q seg_w seg_q seg_s
    for lazy in 0 1; do
        _CCM_LAZY=$lazy
        if _words_invoke_commit_once; then _CCM_LAZY=0; return 0; fi
        if ((!lazy)); then split_idx=$_CCM_SPLIT_IDX split_val="$_CCM_SPLIT_VAL" split_opt=$_CCM_SPLIT_OPT; fi
    done
    _CCM_LAZY=0
    ((split_idx >= 0 && split_opt >= 0)) || return 1
    saved_w=(${_CMD_WORDS[@]+"${_CMD_WORDS[@]}"})
    saved_q=(${_CMD_QLEAD[@]+"${_CMD_QLEAD[@]}"})
    head_w=("${_CMD_WORDS[@]:0:split_opt}")
    head_q=("${_CMD_QLEAD[@]:0:split_opt}")
    tail_w=("${_CMD_WORDS[@]:split_idx+1}")
    tail_q=("${_CMD_QLEAD[@]:split_idx+1}")
    # The nested tokenize must leave the caller's arrays alone: _for_each_command is still reading
    # _SEGMENT_QLEAD / _SEGMENT_SOFT for the words after this command (#1174).
    seg_w=(${_SEGMENT_WORDS[@]+"${_SEGMENT_WORDS[@]}"})
    seg_q=(${_SEGMENT_QLEAD[@]+"${_SEGMENT_QLEAD[@]}"})
    seg_s=(${_SEGMENT_SOFT[@]+"${_SEGMENT_SOFT[@]}"})
    _tokenize_segment "$split_val"
    new_w=(${head_w[@]+"${head_w[@]}"} ${_SEGMENT_WORDS[@]+"${_SEGMENT_WORDS[@]}"} ${tail_w[@]+"${tail_w[@]}"})
    new_q=(${head_q[@]+"${head_q[@]}"} ${_SEGMENT_QLEAD[@]+"${_SEGMENT_QLEAD[@]}"} ${tail_q[@]+"${tail_q[@]}"})
    k=${#_SEGMENT_WORDS[@]}
    _SEGMENT_WORDS=(${seg_w[@]+"${seg_w[@]}"})
    _SEGMENT_QLEAD=(${seg_q[@]+"${seg_q[@]}"})
    _SEGMENT_SOFT=(${seg_s[@]+"${seg_s[@]}"})
    _CMD_WORDS=(${new_w[@]+"${new_w[@]}"})
    _CMD_QLEAD=(${new_q[@]+"${new_q[@]}"})
    ((k)) && _words_invoke_commit && return 0
    _CMD_WORDS=(${saved_w[@]+"${saved_w[@]}"})
    _CMD_QLEAD=(${saved_q[@]+"${saved_q[@]}"})
    return 1
}

_words_invoke_commit_once() {
    local -a words
    local i=0 dir='' flag

    _skip_prefix 0
    ((_CCM_QUERY)) && return 1   # `command -v git commit` only looks git up
    i=$_CCM_NEXT
    words=("${_CMD_WORDS[@]:-}")   # after _skip_prefix: it may have peeled a `(` off a word

    # `rtk` / `rtk proxy` prefix (RTK.md's proxy and its raw escape hatch).
    if [[ "${words[i]:-}" && "${words[i]##*/}" == "rtk" ]]; then
        i=$((i + 1))
        while _redir_len "$i"; do i=$((i + _CCM_RLEN)); done
        if [[ "${words[i]:-}" == "proxy" ]]; then
            i=$((i + 1))
            while _redir_len "$i"; do i=$((i + _CCM_RLEN)); done
        fi
    fi

    # The binary itself: `git` or any path ending in `/git`.
    [[ "${words[i]:-}" && "${words[i]##*/}" == "git" ]] || return 1
    i=$((i + 1))

    # Global flags sit between the binary and the subcommand. `-C` is captured rather than merely
    # skipped, because it changes WHICH repository the commit lands in.
    while :; do
        while _redir_len "$i"; do i=$((i + _CCM_RLEN)); done
        [[ "${words[i]:-}" == -* ]] || break
        flag="${words[i]}"
        i=$((i + 1))
        if [[ "$_GIT_VALUE_FLAGS" == *" $flag "* ]]; then
            # a redirection may sit between the option and its value: `git -C > f /tmp commit`
            while _redir_len "$i"; do i=$((i + _CCM_RLEN)); done
            [[ "$flag" == "-C" ]] && dir="${words[i]:-}"
            i=$((i + 1))
        fi
    done

    # `(git commit)` leaves the `)` glued to the subcommand word
    [[ "${words[i]:-}" == commit || "${words[i]:-}" =~ ^commit\)+$ ]] || return 1

    # The directory the commit lands in: `git -C` (under an `env -C` / `sudo -D` move when relative),
    # else that move itself, else `GIT_DIR=` (#1173; `GIT_WORK_TREE=` never selects the repository).
    if [[ -n "$dir" && "$dir" != /* && -n "$_CCM_WDIR" ]]; then dir="${_CCM_WDIR%/}/$dir"
    elif [[ -z "$dir" ]]; then dir="${_CCM_WDIR:-$_CCM_GIT_ENV_DIR}"; fi
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
    _CMD_QLEAD=("${_SEGMENT_QLEAD[@]:-}")
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
        done <<< "$(printf '%s' "$reading" | sed -E 's/(&&|\|\||\|&|;|\|)/\n/g')"
    done

    # Last reading, only for a command with `>|`: the quote-aware split reader, which knows a
    # `>|` from a pipe by what the tokenizer saw (the rewrites above cannot tell `a\>|` from `>|`).
    if [[ "$command" == *'>|'* ]]; then
        _CCM_HIT=0
        _for_each_command "$command" _note_commit_hit
        ((_CCM_HIT)) && return 0
    fi

    return 1
}

_note_commit_hit() { _words_invoke_commit && _CCM_HIT=1; return 0; }

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
    local -a all piece_words=() piece_len=() piece_ql=()
    _CMD_WORDS=()
    _CMD_QLEAD=()
    _tokenize_segment "$1" split
    all=("${_SEGMENT_WORDS[@]:-}" "$_BOUNDARY")
    for i in ${_SEGMENT_SOFT[@]+"${_SEGMENT_SOFT[@]}"}; do soft+="$i "; done
    for i in "${!all[@]}"; do
        w="${all[i]}"
        if [[ "$w" != "$_BOUNDARY" ]]; then
            _CMD_WORDS+=("$w")
            _CMD_QLEAD+=("${_SEGMENT_QLEAD[i]:-0}")
            continue
        fi
        piece_words+=(${_CMD_WORDS[@]+"${_CMD_WORDS[@]}"})
        piece_ql+=(${_CMD_QLEAD[@]+"${_CMD_QLEAD[@]}"})
        piece_len+=("${#_CMD_WORDS[@]}")
        _CMD_WORDS=()
        _CMD_QLEAD=()
        # A cut at `>|` is no command boundary (#1158): keep gathering. The group fires, in source
        # order and once, at its first real boundary.
        [[ "$soft" == *" $i "* ]] && continue
        _fire_group "$cb"
        piece_words=()
        piece_ql=()
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
    local -a joined=() joined_ql=()
    if ((${#piece_len[@]} > 1)); then
        for ((k = 0; k < ${#piece_len[@]}; k++)); do
            joined+=(${piece_words[@]+"${piece_words[@]:off:piece_len[k]}"})
            joined_ql+=(${piece_ql[@]+"${piece_ql[@]:off:piece_len[k]}"})
            off=$((off + piece_len[k]))
            if ((k + 1 < ${#piece_len[@]} && piece_len[k] > 0)); then joined[${#joined[@]} - 1]+="|"; fi
        done
        _CMD_WORDS=(${joined[@]+"${joined[@]}"})
        _CMD_QLEAD=(${joined_ql[@]+"${joined_ql[@]}"})
        if _words_invoke_commit; then
            COMMIT_COMMAND_GIT_DIR="$saved_dir"
            "$cb"
            _CMD_WORDS=()
            _CMD_QLEAD=()
            return 0
        fi
        COMMIT_COMMAND_GIT_DIR="$saved_dir"
    fi
    off=0
    for ((k = 0; k < ${#piece_len[@]}; k++)); do
        _CMD_WORDS=(${piece_words[@]+"${piece_words[@]:off:piece_len[k]}"})
        _CMD_QLEAD=(${piece_ql[@]+"${piece_ql[@]:off:piece_len[k]}"})
        off=$((off + piece_len[k]))
        "$cb"
    done
    _CMD_WORDS=()
    _CMD_QLEAD=()
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
            n = length(s); k = 1; t = ""; dqf = 0   # dqf: any quoting seen, so the body joins nothing
            while (k <= n) {
                ch = substr(s, k, 1)
                if (ch ~ /[ \t<>|&;()]/) break
                if (ch ~ /[\\\047"]/ || (ch == "$" && substr(s, k + 1, 1) ~ /[\047"]/)) dqf = 1
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
        # Body line of an UNQUOTED heredoc (#1168): bash joins `\<NL>` before comparing a line with
        # the delimiter, so `EO\` + `F` is the delimiter EOF. Join exactly the way the matcher does
        # for commands (an odd backslash run continues). A quoted delimiter joins nothing.
        pending {
            buf = buf $0
            if (!tq[ci] && buf ~ /(^|[^\\])(\\\\)*\\$/) { sub(/\\$/, "", buf); next }
            t = buf; buf = ""
            if (td[ci]) sub(/^\t+/, "", t)   # leading tabs go only for <<-, never for a plain <<
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
                    if (tg != "") { tags[++nt] = tg; tq[nt] = dqf; td[nt] = (substr(rest, 1, 1) == "-") }
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
