#!/bin/bash
# PreToolUse (Bash matcher) hook: block a `git commit` / `git push` while HEAD is on a protected
# branch (master or main), forcing a feature-branch-first workflow.
#
# Why this exists: every user repo protects master/main — direct commits/pushes must go through
# pull -> branch -> PR. A memory note or CLAUDE.md rule ("branch first") is only advisory: nothing
# runs it before the commit. This hook is harness-run, so it turns "oops, committed on master" into
# an instant pre-commit block with a one-line remedy.
#
# Hook I/O contract (same as commit_title_length_guard.sh): silent on stdout, speaks only through
# exit code + stderr — so there is intentionally no lib/common.sh / print_status here. It fails OPEN:
# not a git repo, a detached HEAD, or any state the guard cannot resolve to a protected branch name
# exits 0 and lets the command proceed. Better to miss than to false-block a valid command.

set -u

# jq parses the hook payload; without it we cannot inspect the command, so fail CLOSED (#1162).
command -v jq >/dev/null 2>&1 || { echo "BLOCKED: jq not found in PATH - guard fails closed (#1162). Install jq from a terminal outside this session (e.g. sudo apt install jq)." >&2; exit 2; }

# shellcheck source=lib/commit_command_matcher.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/commit_command_matcher.sh" || { echo "BLOCKED: cannot source lib/commit_command_matcher.sh (missing or unreadable) - guard fails closed (#1160)" >&2; exit 2; }

# ponytail: two literal names cover every user repo today (memory: main/master protected
# everywhere). Make this a .git-config / env list only if a repo ever protects a differently-named
# default branch.
PROTECTED_BRANCHES='^(master|main)$'

# Parse ONE statement as a `git commit`/`git push` invocation (optionally rtk-prefixed) AND
# resolve which repo it actually targets — the root-cause fix for issue #97, folded into a single
# function per the issue's ask (a third instance of "the guard decided on the SESSION, not the
# ACTION's target" in this hook family; extract once, not another point patch).
#
# Two things a naive `grep '^git[[:space:]]+commit'` gets wrong, both fixed by tokenizing instead:
#   1. Verb detection: `git -C <path> commit` has flags BETWEEN `git` and `commit` — an anchored
#      regex never matches it, silently failing OPEN on exactly the commands #97 is about.
#   2. Target: `-C <path>` / `--git-dir=` / `--work-tree=` redirect git at a different repo than
#      the hook's own $PWD (the session's checkout) — the ONLY thing prior code ever inspected.
#
# `-C`/`--git-dir`/`--work-tree` always win (git honors them regardless of $PWD); otherwise the
# target is `tracked_dir` (the last `cd` seen so far in this command, from split_statements'
# caller), or "" to mean "the hook's own $PWD" — the session repo, still correct when nothing
# redirected the command. Prints "<verb> <target>" on a match; returns 1 if this statement isn't a
# `git commit`/`git push` at all (mirrors old behaviour: git as anything but the FIRST token is a
# mere mention, not a command, and is ignored).
parse_git_statement() {
    local stmt="$1" tracked_dir="$2"
    local -a toks
    read -ra toks <<< "$stmt"                           # split on IFS without globbing
    local i=0 tok target="$tracked_dir" verb=""

    [[ "${toks[0]:-}" == "rtk" ]] && i=1
    [[ "${toks[i]:-}" == "git" ]] || return 1
    (( i++ ))

    for (( ; i < ${#toks[@]}; i++ )); do
        tok="${toks[i]}"
        case "$tok" in
            -C)            target="${toks[i+1]:-}"; (( i++ )) ;;
            -C?*)          target="${tok#-C}" ;;
            --git-dir=*)   target="${tok#--git-dir=}" ;;
            --git-dir)     target="${toks[i+1]:-}"; (( i++ )) ;;
            --work-tree=*) target="${tok#--work-tree=}" ;;
            --work-tree)   target="${toks[i+1]:-}"; (( i++ )) ;;
            -c)            (( i++ )) ;;                 # `-c key=val` takes a value; skip it
            -*)            ;;                            # some other global flag we don't track
            *)             verb="$tok"; break ;;         # first non-flag token IS the subcommand
        esac
    done

    [[ "$verb" == "commit" || "$verb" == "push" ]] || return 1
    printf '%s %s' "$verb" "$target"
}

# Split one physical line into `&&`/`;`-separated statements so a single-line `cd <path> && git
# commit` is judged as two statements (cd updates the tracked dir, THEN git runs in it) instead of
# missing the verb because "git" isn't the first token on the line.
# ponytail: a literal && or ; inside a quoted string (e.g. a commit message) mis-splits here — same
# heuristic-scan ceiling strip_heredoc_bodies already accepts for this hook. Upgrade path: a real
# shell tokenizer if that ever produces a false split in practice.
split_statements() {
    local line="$1"
    line="${line//&&/$'\n'}"
    line="${line//;/$'\n'}"
    printf '%s\n' "$line"
}

# Return 0 iff a `git push` ONLY deletes non-protected ref(s) — safe even on a protected branch,
# because it writes nothing there (it is the normal post-merge cleanup, always run from main).
# Decide on the TARGET refspec, never on "we happen to be on a protected branch".
push_is_safe_deletion() {
    local cmd="$1" tok ref is_del=0
    local -a toks
    read -ra toks <<< "$cmd"                            # split on IFS without globbing
    for tok in "${toks[@]}"; do
        case "$tok" in
            --delete|-d) is_del=1 ;;
            :?*|+:?*)    is_del=1 ;;                     # empty-source refspec (`:dst`) == delete dst
        esac
    done
    (( is_del )) || return 1                            # a normal push (writes a ref) -> block
    for tok in "${toks[@]}"; do
        ref="${tok#+}"; ref="${ref#:}"; ref="${ref%:}"; ref="${ref#refs/heads/}"
        [[ "$ref" =~ ^(master|main)$ ]] && return 1     # a target IS protected -> block
    done
    return 0                                            # deletes only non-protected refs -> allow
}

main() {
    local payload tool command line stmt verb branch target_dir parsed

    payload="$(cat)"
    tool="$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null)"
    [[ "$tool" == "Bash" ]] || exit 0

    command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)"
    [[ -n "$command" ]] || exit 0

    # A `git push`/`git commit` inside a heredoc body is prose, not a command — strip bodies first.
    command="$(printf '%s\n' "$command" | _strip_heredoc_bodies)"

    # Join `\`-newline shell line continuations BEFORE splitting into lines/statements (issue #141):
    # a `rtk git push origin \`<newline>`--delete <ref>` is ONE logical statement, but the per-line
    # loop below treats every physical line as a statement boundary. Without this join, verb
    # detection sees only line 1 (finds `push`, no `--delete`) and push_is_safe_deletion — reading
    # the SAME truncated statement — never sees the flag/ref on the continuation line, so a safe
    # multi-line delete is falsely BLOCKED. Removing the literal `\<newline>` mirrors real shell
    # continuation semantics (which discard both bytes) and keeps every downstream check reading
    # identical text.
    command="${command//$'\\\n'/}"

    # cwd tracks the directory a `cd` earlier IN THIS SAME COMMAND leaves us in (issue #97): a
    # multi-line/`&&`-chained Bash command runs sequentially in one shell, so a `cd /other/repo`
    # two statements up is still in effect when `git commit` runs. "" means "no cd seen yet" ->
    # parse_git_statement falls back to the hook's own $PWD (the session repo).
    local cwd=""

    while IFS= read -r line || [[ -n "$line" ]]; do
        while IFS= read -r stmt || [[ -n "$stmt" ]]; do
            [[ -n "${stmt//[[:space:]]/}" ]] || continue

            if [[ "$stmt" =~ ^[[:space:]]*(rtk[[:space:]]+)?cd[[:space:]]+([^[:space:]]+) ]]; then
                cwd="${BASH_REMATCH[2]}"
                continue
            fi

            # Only guard an actual `git commit` / `git push` (optionally rtk-prefixed): `git` must
            # be the first token of the statement, so a mere mention inside another argument does
            # not trip the guard. parse_git_statement also resolves the TARGET repo (issue #97).
            parsed="$(parse_git_statement "$stmt" "$cwd")" || continue
            verb="${parsed%% *}"
            target_dir="${parsed#* }"

            # symbolic-ref resolves the current branch name even on an unborn branch (before the
            # first commit); it fails on a detached HEAD OR an unresolvable/nonexistent target ->
            # fail open for THIS statement rather than falsely attributing the session's branch to
            # a target we could not actually inspect (issue #97 scope: never report the wrong repo).
            if [[ -n "$target_dir" ]]; then
                branch="$(git -C "$target_dir" symbolic-ref --short HEAD 2>/dev/null)" || continue
            else
                branch="$(git symbolic-ref --short HEAD 2>/dev/null)" || continue
            fi
            [[ -n "$branch" ]] || continue

            printf '%s' "$branch" | grep -Eq "$PROTECTED_BRANCHES" || continue   # feature -> allow

            # ponytail: refspec-aware exception (issue #54). Deleting a NON-protected ref never
            # writes the protected branch. Upgrade path: parse src:dst destinations too if pushing
            # OTHER branches from a protected branch ever needs allowing (today those stay blocked
            # — a rare, safe false-block).
            if [[ "$verb" == "push" ]] && push_is_safe_deletion "$stmt"; then
                continue
            fi

            {
                echo "BLOCKED: refusing to git ${verb} on protected branch '${branch}'."
                echo
                if [[ -n "$target_dir" ]]; then
                    echo "Target repo: ${target_dir}"
                fi
                echo "This repo protects '${branch}' — a direct ${verb} must go through a feature branch + PR."
                echo "Create one first, then re-run the SAME command:"
                echo
                echo "  git pull --ff-only && git checkout -b <type>/<short-desc>"
                echo
                echo "(A commit already staged/made on '${branch}' carries onto the new branch losslessly.)"
            } >&2
            exit 2
        done < <(split_statements "$line")
    done <<< "$command"

    exit 0
}

main "$@"
