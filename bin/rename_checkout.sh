#!/bin/bash
#
# One-time rename of this checkout directory (dotfiles-linux-dev#661), e.g.
#   dotfiles-dev -> dotfiles-linux-dev
#
# A plain `mv` silently loses Claude's per-project memory (it is keyed by the checkout
# path) and leaves live config pointing at a directory that no longer exists. This script
# does the whole move; it is meant to be run ONCE, from a terminal OUTSIDE the checkout,
# at the end of a session.
#
# Usage:
#   bin/rename_checkout.sh [--dry-run] <new-dir>    plan + precondition report (the DEFAULT)
#   bin/rename_checkout.sh --apply <new-dir>        do it, only if every precondition holds
#
# <new-dir> is a bare directory name (or a path in the same parent): this renames, it does
# not relocate.
#
# Inputs, all overridable so the tests never touch a real path:
#   DOTFILES_DIR         the checkout to rename (default: resolved from this script)
#   CLAUDE_CONFIG_DIR    the Claude config dir (default: ~/.claude)
#   PROC_DIR             where to look for running processes (default: /proc)
#   RENAME_EXTRA_REPOS   colon-separated repo dirs, beyond the siblings, to scan for references

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=../ai_clients/claude/hooks/lib/dotfiles_dir.sh
source "$SCRIPT_DIR/../ai_clients/claude/hooks/lib/dotfiles_dir.sh"

MODE="dry-run"
FAILURES=()
WORKTREES=()   # linked worktrees of the checkout, as paths under the OLD location

usage() {
    sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
}

die() {
    print_status "error" "$1"
    exit 2
}

fail() {
    FAILURES+=("$1")
}

# A path as Claude names its per-project directory: every / and . becomes -.
project_key() {
    local p="$1"
    printf '%s' "${p//[\/.]/-}"
}

parse_args() {
    local new_arg=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) MODE="dry-run" ;;
            --apply)   MODE="apply" ;;
            -h|--help) usage; exit 0 ;;
            -*)        die "unknown option: $1" ;;
            *)         [[ -z "$new_arg" ]] || die "exactly one <new-dir> expected"; new_arg="$1" ;;
        esac
        shift
    done
    [[ -n "$new_arg" ]] || { usage >&2; exit 2; }
    NEW_ARG="$new_arg"
}

resolve_paths() {
    local old
    old="$(resolve_dotfiles_dir "$SCRIPT_DIR")" || die "cannot resolve the checkout to rename"
    [[ -d "$old" ]] || die "checkout does not exist: $old"
    OLD="$(cd "$old" && pwd -P)"
    OLD_NAME="$(basename "$OLD")"
    PARENT="$(dirname "$OLD")"

    case "$NEW_ARG" in
        */*) NEW="$NEW_ARG" ;;
        *)   NEW="$PARENT/$NEW_ARG" ;;
    esac
    [[ "$(dirname "$NEW")" == "$PARENT" ]] || die "<new-dir> must be in the same parent as the checkout ($PARENT): this is a rename, not a move"
    NEW_NAME="$(basename "$NEW")"
    [[ "$NEW" != "$OLD" ]] || die "<new-dir> is the current name"

    CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    PROC_DIR="${PROC_DIR:-/proc}"
    KEY_OLD="$(project_key "$OLD")"
    KEY_NEW="$(project_key "$NEW")"
    # `<parent>/<name>` is the tail every spelling shares: /home/u/github/x, ~/github/x, $HOME/github/x.
    TAIL_OLD="$(basename "$PARENT")/$OLD_NAME"
    TAIL_NEW="$(basename "$PARENT")/$NEW_NAME"
}

# ── preconditions ────────────────────────────────────────────────────────────

check_outside_checkout() {
    local here
    here="$(pwd -P)"
    [[ "$here" != "$OLD" && "$here" != "$OLD"/* ]] || fail "run from outside the checkout (cwd is $here)"
}

# Pids from self up through every ancestor: the terminal that launched this script, and
# this script's own cmdline, legitimately mention the checkout.
own_pids() {
    local pid=$$ ppid
    while [[ -n "$pid" && "$pid" != 0 && "$pid" != 1 ]]; do
        printf '%s\n' "$pid"
        ppid="$(awk '/^PPid:/ {print $2}' "$PROC_DIR/$pid/status" 2>/dev/null)" || break
        pid="$ppid"
    done
}

check_no_process_uses_checkout() {
    local p pid cwd cmdline own
    own="$(own_pids)"
    for p in "$PROC_DIR"/[0-9]*; do
        pid="${p##*/}"
        [[ -d "$p" && "$pid" != "$$" ]] || continue
        cwd="$(readlink "$p/cwd" 2>/dev/null)" || cwd=""
        if [[ "$cwd" == "$OLD" || "$cwd" == "$OLD"/* ]]; then
            fail "process $pid ($(tr -d '\0' < "$p/comm" 2>/dev/null)) has its cwd inside the checkout: $cwd"
            continue
        fi
        grep -qxF "$pid" <<< "$own" && continue
        cmdline="$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null)" || cmdline=""
        if [[ "$cmdline" == *"$OLD"* ]]; then
            fail "process $pid depends on the old path: ${cmdline:0:120}"
        fi
    done
}

# Every worktree (the checkout itself included) must be clean: uncommitted work is exactly
# what a rename that goes wrong would lose.
check_worktrees_clean() {
    local line wt dirty
    local -a all=()
    while IFS= read -r line; do
        [[ "$line" == "worktree "* ]] && all+=("${line#worktree }")
    done < <(git -C "$OLD" worktree list --porcelain)

    for wt in "${all[@]}"; do
        [[ -d "$wt" ]] || continue
        [[ "$wt" == "$OLD" ]] || WORKTREES+=("$wt")
        dirty="$(git -C "$wt" status --porcelain | wc -l)"
        (( dirty == 0 )) || fail "$wt has $dirty uncommitted path(s)"
    done
}

check_targets() {
    local target_key="$CLAUDE_DIR/projects/$KEY_NEW"
    [[ ! -e "$NEW" && ! -L "$NEW" ]] || fail "target already exists: $NEW"
    [[ ! -e "$target_key" ]] || fail "Claude project dir for the new name already exists: $target_key (refusing to merge)"
    [[ "$(stat -c %d "$OLD")" == "$(stat -c %d "$PARENT")" ]] || fail "$OLD is a mount point: a rename would not be atomic"
}

check_tools() {
    local tool
    for tool in git perl awk; do
        command -v "$tool" > /dev/null 2>&1 || fail "required tool not found: $tool"
    done
}

run_preconditions() {
    print_status "section" "PRECONDITIONS"
    check_tools
    check_outside_checkout
    check_no_process_uses_checkout
    check_worktrees_clean
    check_targets

    if (( ${#FAILURES[@]} == 0 )); then
        print_status "success" "all preconditions hold"
        return 0
    fi
    local f
    for f in "${FAILURES[@]}"; do
        print_status "error" "$f"
    done
    return 1
}

# ── plan / apply ─────────────────────────────────────────────────────────────

# act <description> <command...>: run it under --apply, only announce it under --dry-run.
act() {
    local desc="$1"
    shift
    if [[ "$MODE" == "apply" ]]; then
        print_status "config" "$desc"
        "$@"
    else
        print_status "info" "[dry-run] would: $desc"
    fi
}

list_stale_worktree_keys() {
    local d header=1
    for d in "$CLAUDE_DIR/projects/${KEY_OLD}"--claude-worktrees-*; do
        [[ -e "$d" ]] || continue
        if (( header )); then
            print_status "info" "stale worktree project dirs (listed, NOT moved):"
            header=0
        fi
        echo "    $d"
    done
}

step_move_project_key() {
    print_status "section" "1/7 CLAUDE PROJECT MEMORY"
    local src="$CLAUDE_DIR/projects/$KEY_OLD" dst="$CLAUDE_DIR/projects/$KEY_NEW"
    if [[ ! -d "$src" ]]; then
        print_status "warning" "no Claude project dir at $src: nothing to move"
    else
        act "mv $src -> $dst" mv "$src" "$dst"
    fi
    list_stale_worktree_keys
}

step_move_checkout() {
    print_status "section" "2/7 CHECKOUT + WORKTREES"
    act "mv $OLD -> $NEW" mv_checkout
}

# Moves the directory, then repairs and verifies every linked worktree. A failed move puts
# the Claude project dir back so the machine is never left half-renamed.
mv_checkout() {
    local wt mapped
    local -a repair=()
    if ! mv "$OLD" "$NEW"; then
        [[ -d "$CLAUDE_DIR/projects/$KEY_NEW" ]] && mv "$CLAUDE_DIR/projects/$KEY_NEW" "$CLAUDE_DIR/projects/$KEY_OLD"
        die "mv failed; the Claude project dir was restored"
    fi
    for wt in "${WORKTREES[@]}"; do
        mapped="$wt"
        [[ "$wt" == "$OLD"/* ]] && mapped="$NEW${wt#"$OLD"}"
        repair+=("$mapped")
    done
    if (( ${#repair[@]} > 0 )); then
        git -C "$NEW" worktree repair "${repair[@]}"
    fi
    for mapped in "${repair[@]}"; do
        [[ "$(git -C "$mapped" rev-parse --path-format=absolute --git-common-dir)" == "$NEW/.git" ]] \
            || die "worktree did not resolve after repair: $mapped (checkout is now at $NEW)"
    done
    print_status "success" "checkout moved; ${#repair[@]} worktree(s) resolve"
}

# stdin -> stdout, rewriting PATHS only: `<parent>/<old>` (every spelling of the checkout)
# and the Claude project key. A bare name (dotfiles-dev#68, `Origin: dotfiles-dev`) never
# matches because the pattern needs the parent segment, and neither side may touch a longer
# name (dotfiles-dev-tools).
rewrite_paths() {
    PAIRS="$TAIL_OLD"$'\t'"$TAIL_NEW"$'\n'"$KEY_OLD"$'\t'"$KEY_NEW" perl -0pe '
        BEGIN {
            for (split /\n/, $ENV{PAIRS}) {
                my ($from, $to) = split /\t/;
                push @r, [qr/(?<![A-Za-z0-9_-])\Q$from\E(?![A-Za-z0-9_-])/, $to];
            }
        }
        for my $r (@r) { s/$r->[0]/$r->[1]/g }
    '
}

# scratch_for <file>: where to render a rewrite. Under --apply it sits beside the target (an
# atomic mv, and an interrupted rewrite never leaves a truncated file); a dry run must not
# write into the config tree at all.
scratch_for() {
    if [[ "$MODE" == "apply" ]]; then
        mktemp "$1.XXXXXX"
    else
        mktemp
    fi
}

# rewrite_file <file>: dry-run prints the diff, apply replaces the file.
rewrite_file() {
    local f="$1" tmp
    tmp="$(scratch_for "$f")"
    rewrite_paths < "$f" > "$tmp"
    if cmp -s "$f" "$tmp"; then
        rm -f "$tmp"
        return 0
    fi
    REWRITTEN=$(( REWRITTEN + 1 ))
    if [[ "$MODE" == "apply" ]]; then
        chmod --reference="$f" "$tmp"
        mv "$tmp" "$f"
    else
        diff -u --label "a/$f" --label "b/$f" "$f" "$tmp" || true
        rm -f "$tmp"
    fi
}

step_rewrite_memory() {
    print_status "section" "3/7 PATHS IN MEMORY + LESSON FILES"
    # In dry-run nothing has moved yet, so the project dir is still under the old key.
    local key="$KEY_OLD" f dir
    [[ "$MODE" != "apply" ]] || key="$KEY_NEW"
    local -a roots=("$CLAUDE_DIR/projects/$key/memory" "$CLAUDE_DIR/memory/lessons-claude-toolchain")
    REWRITTEN=0
    for dir in "${roots[@]}"; do
        [[ -d "$dir" ]] || continue
        while IFS= read -r -d '' f; do
            rewrite_file "$f"
        done < <(find "$dir" -type f -name '*.md' -print0)
    done
    print_status "info" "$REWRITTEN file(s) $([[ "$MODE" == "apply" ]] && echo rewritten || echo "would change")"
}

step_issue_trackers() {
    print_status "section" "4/7 issue-trackers.conf"
    local conf="$CLAUDE_DIR/issue-trackers.conf" tmp
    if [[ ! -f "$conf" ]] || ! grep -qE "^$OLD_NAME([[:space:]]|\$)" "$conf"; then
        print_status "info" "no entry for $OLD_NAME in $conf"
        return 0
    fi
    # Matches the checkout DIRECTORY name (never the remote), so it is the one NAME that must follow the rename.
    tmp="$(scratch_for "$conf")"
    OLD_NAME="$OLD_NAME" NEW_NAME="$NEW_NAME" perl -pe 's/^\Q$ENV{OLD_NAME}\E(?=\s|$)/$ENV{NEW_NAME}/' "$conf" > "$tmp"
    if [[ "$MODE" == "apply" ]]; then
        chmod --reference="$conf" "$tmp"
        mv "$tmp" "$conf"
        print_status "success" "updated $conf"
    else
        diff -u --label "a/$conf" --label "b/$conf" "$conf" "$tmp" || true
        rm -f "$tmp"
    fi
}

step_redeploy() {
    print_status "section" "5/7 REDEPLOY LIVE CONFIG"
    # Run from the NEW location so the rendered @DOTFILES_DIR@ is the new path.
    act "bash $NEW/ai_clients/claude/main.sh settings hooks skills claude_md" \
        env DOTFILES_DIR="$NEW" bash "$NEW/ai_clients/claude/main.sh" settings hooks skills claude_md
}

step_symlink() {
    print_status "section" "6/7 COMPATIBILITY SYMLINK + OTHER REPOS"
    act "ln -s $NEW $OLD  (temporary: remove once the other repos are updated)" ln -s "$NEW" "$OLD"

    local repo hits real seen=""
    local -a candidates=("$PARENT"/*/)
    IFS=: read -r -a extra <<< "${RENAME_EXTRA_REPOS:-}"
    candidates+=("${extra[@]}")
    print_status "info" "references to $TAIL_OLD in other repos (each is fixed by that repo's own PR):"
    for repo in "${candidates[@]}"; do
        repo="${repo%/}"
        [[ -n "$repo" && -e "$repo/.git" ]] || continue
        real="$(cd "$repo" && pwd -P)"
        [[ "$real" != "$OLD" && "$real" != "$NEW" ]] || continue
        [[ "$seen" != *"|$real|"* ]] || continue
        seen+="|$real|"
        hits="$(git -C "$repo" grep -l -I -F -e "$TAIL_OLD" 2>/dev/null || true)"
        [[ -n "$hits" ]] || continue
        echo "  $repo"
        sed 's/^/      /' <<< "$hits"
    done
}

step_final_grep() {
    print_status "section" "7/7 LEFTOVERS IN LIVE CONFIG + MEMORY"
    local key="$KEY_OLD" t
    [[ "$MODE" != "apply" ]] || key="$KEY_NEW"
    local -a targets=()
    for t in settings.json CLAUDE.md AGENTS.md hooks skills commands agents rules memory "projects/$key/memory"; do
        [[ -e "$CLAUDE_DIR/$t" ]] && targets+=("$CLAUDE_DIR/$t")
    done
    local hits=""
    # `grep -r` with no path would scan the cwd, so an empty target list is its own answer.
    if (( ${#targets[@]} > 0 )); then
        hits="$(grep -rIlP \
        '(?<![A-Za-z0-9_-])(\Q'"$TAIL_OLD"'\E|\Q'"$KEY_OLD"'\E)(?![A-Za-z0-9_-])' "${targets[@]}" 2>/dev/null || true)"
    fi
    if [[ -z "$hits" ]]; then
        print_status "success" "0 references to the old path"
        return 0
    fi
    print_status "warning" "$(wc -l <<< "$hits") file(s) still reference the old path$([[ "$MODE" == "apply" ]] || echo " (current exposure; --apply fixes memory and redeploys the rest)"):"
    sed 's/^/    /' <<< "$hits"
}

main() {
    parse_args "$@"
    resolve_paths

    print_status "info" "mode: $MODE"
    print_status "info" "checkout: $OLD -> $NEW"
    print_status "info" "claude dir: $CLAUDE_DIR"

    local ok=0
    run_preconditions || ok=1

    if [[ "$MODE" == "apply" && "$ok" -ne 0 ]]; then
        die "refusing to --apply: fix the failed preconditions above"
    fi

    step_move_project_key
    step_move_checkout
    step_rewrite_memory
    step_issue_trackers
    step_redeploy
    step_symlink
    step_final_grep

    if [[ "$MODE" == "dry-run" ]]; then
        print_status "info" "dry run only: nothing was changed. Re-run with --apply to do it."
    else
        print_status "success" "renamed. cd $NEW and restart Claude Code."
    fi
    return "$ok"
}

main "$@"
